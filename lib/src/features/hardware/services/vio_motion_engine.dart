import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

class SpatialVector3D {
  final double x;
  final double y;
  final double z;

  const SpatialVector3D({required this.x, required this.y, required this.z});

  static const SpatialVector3D zero = SpatialVector3D(x: 0, y: 0, z: 0);

  double get magnitude => sqrt(x * x + y * y + z * z);

  SpatialVector3D operator -(SpatialVector3D other) =>
      SpatialVector3D(x: x - other.x, y: y - other.y, z: z - other.z);

  Map<String, double> toJson() => {'x': x, 'y': y, 'z': z};
}

/// Camera tilt derived from the gravity vector, for a phone held in portrait
/// with the rear camera facing the subject.
///
/// Device axes (Android convention, which sensors_plus also uses on iOS):
/// +x right edge, +y top edge, +z out of the screen. At rest the accelerometer
/// reads the reaction to gravity, i.e. it points "up": an upright portrait
/// phone reads about (0, +9.81, 0).
class TiltReading {
  /// Forward/back tilt. Positive = rear camera aimed down toward the floor
  /// (screen tipped toward the sky); negative = aimed up.
  final double pitchDeg;

  /// In-plane rotation. Positive = phone rotated clockwise as seen from the
  /// screen side (top edge leaning right).
  final double rollDeg;

  /// False when the phone is closer to landscape or flat than portrait.
  final bool isPortrait;

  const TiltReading({required this.pitchDeg, required this.rollDeg, required this.isPortrait});

  static const TiltReading level = TiltReading(pitchDeg: 0, rollDeg: 0, isPortrait: true);

  factory TiltReading.fromGravity(double x, double y, double z) {
    final double pitch = atan2(z, sqrt(x * x + y * y)) * 180.0 / pi;
    final double roll = atan2(-x, y) * 180.0 / pi;
    final bool portrait = y > 0 && y.abs() >= x.abs() && y.abs() >= z.abs();
    return TiltReading(pitchDeg: pitch, rollDeg: roll, isPortrait: portrait);
  }

  bool isLevelWithin(double toleranceDeg) =>
      isPortrait && pitchDeg.abs() <= toleranceDeg && rollDeg.abs() <= toleranceDeg;
}

/// Phone-orientation tracker for the tripod capture.
///
/// The phone is meant to be still, so this does not try to track position
/// (double-integrating accelerometers drifts by metres within seconds). It
/// low-pass filters the accelerometer to recover gravity, which gives pitch
/// and roll to well under 1°, and uses the gyroscope only to decide whether
/// the phone is stationary.
///
/// The name is kept for host compatibility; ARCore/ARKit visual-inertial
/// tracking is not used for the tripod workflow.
class VioMotionEngine extends ChangeNotifier {
  VioMotionEngine({
    this.levelToleranceDeg = 3.0,
    this.filterTimeConstantSec = 0.25,
    this.stationaryGyroRadPerSec = 0.05,
    this.stationaryAccelDeviation = 0.35,
    this.stationaryHoldSec = 0.75,
  });

  /// Maximum pitch/roll for capture (spec: < 3°).
  final double levelToleranceDeg;
  final double filterTimeConstantSec;
  final double stationaryGyroRadPerSec;
  final double stationaryAccelDeviation;
  final double stationaryHoldSec;

  static const double standardGravity = 9.80665;

  StreamSubscription<AccelerometerEvent>? _accelSubscription;
  StreamSubscription<GyroscopeEvent>? _gyroSubscription;

  SpatialVector3D? _gravity;
  TiltReading _tilt = TiltReading.level;
  double _gyroMagnitude = 0.0;
  double _accelDeviation = 0.0;
  DateTime? _lastAccel;
  DateTime? _stillSince;
  bool _isTracking = false;
  String? _lastError;

  bool get isTracking => _isTracking;

  /// Low-pass filtered gravity in device coordinates (m/s²), or zero before
  /// the first sample.
  SpatialVector3D get gravityVector => _gravity ?? SpatialVector3D.zero;
  bool get hasReading => _gravity != null;
  TiltReading get tilt => _tilt;
  double get pitchAngleDeg => _tilt.pitchDeg;
  double get rollAngleDeg => _tilt.rollDeg;
  String? get lastError => _lastError;

  /// True once the phone has been still for [stationaryHoldSec].
  bool get isStationary =>
      _stillSince != null &&
      DateTime.now().difference(_stillSince!).inMicroseconds / 1e6 >= stationaryHoldSec;

  /// Current rotation rate (rad/s) — handheld capture uses it as "steady enough".
  double get gyroMagnitude => _gyroMagnitude;

  /// Handheld: tilt within [toleranceDeg] and rotating slower than [maxGyro]
  /// (enough to avoid motion blur); each frame's tilt is corrected later.
  bool isSteadyEnoughHandheld({double toleranceDeg = 10, double maxGyro = 0.35}) =>
      hasReading && _tilt.isLevelWithin(toleranceDeg) && _gyroMagnitude < maxGyro;

  /// Level (within tolerance), in portrait, and not moving.
  bool isLevelForCapture() => hasReading && isStationary && _tilt.isLevelWithin(levelToleranceDeg);

  /// Kept for existing callers.
  bool isOrientationUprightForCapture() => isLevelForCapture();

  void startTracking() {
    if (_isTracking) return;
    resetBaseline();
    _isTracking = true;

    _accelSubscription = accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen(
      (e) => addAccelerometerSample(e.x, e.y, e.z, DateTime.now()),
      onError: (Object error) => _lastError = 'Accelerometer unavailable: $error',
      cancelOnError: false,
    );
    _gyroSubscription = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval).listen(
      (e) => addGyroscopeSample(e.x, e.y, e.z, DateTime.now()),
      onError: (Object error) => _lastError = 'Gyroscope unavailable: $error',
      cancelOnError: false,
    );
  }

  void stopTracking() {
    _isTracking = false;
    _accelSubscription?.cancel();
    _gyroSubscription?.cancel();
    _accelSubscription = null;
    _gyroSubscription = null;
  }

  void resetBaseline() {
    _gravity = null;
    _tilt = TiltReading.level;
    _gyroMagnitude = 0.0;
    _accelDeviation = 0.0;
    _lastAccel = null;
    _stillSince = null;
  }

  /// Public so tests (and a future native sensor source) can feed samples.
  void addAccelerometerSample(double x, double y, double z, DateTime at) {
    final prev = _gravity;
    if (prev == null) {
      _gravity = SpatialVector3D(x: x, y: y, z: z);
    } else {
      final double dt = _lastAccel == null ? 0.02 : at.difference(_lastAccel!).inMicroseconds / 1e6;
      final double alpha = (dt <= 0 || dt > 0.5) ? 1.0 : dt / (filterTimeConstantSec + dt);
      _gravity = SpatialVector3D(
        x: prev.x + alpha * (x - prev.x),
        y: prev.y + alpha * (y - prev.y),
        z: prev.z + alpha * (z - prev.z),
      );
    }
    _lastAccel = at;
    _accelDeviation = (sqrt(x * x + y * y + z * z) - standardGravity).abs();
    final g = _gravity!;
    _tilt = TiltReading.fromGravity(g.x, g.y, g.z);
    _updateStillness(at);
  }

  void addGyroscopeSample(double x, double y, double z, DateTime at) {
    _gyroMagnitude = sqrt(x * x + y * y + z * z);
    _updateStillness(at);
  }

  void _updateStillness(DateTime at) {
    final bool still = _gyroMagnitude < stationaryGyroRadPerSec && _accelDeviation < stationaryAccelDeviation;
    if (!still) {
      _stillSince = null;
    } else {
      _stillSince ??= at;
    }
    _maybeNotify(at);
  }

  // UI refresh at most ~10 Hz, plus immediately when the level state flips.
  DateTime? _lastNotify;
  bool? _lastNotifiedLevel;

  void _maybeNotify(DateTime at) {
    final bool levelNow = isLevelForCapture();
    final bool due = _lastNotify == null || at.difference(_lastNotify!).inMilliseconds >= 100;
    if (due || levelNow != _lastNotifiedLevel) {
      _lastNotify = at;
      _lastNotifiedLevel = levelNow;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    stopTracking();
    super.dispose();
  }
}
