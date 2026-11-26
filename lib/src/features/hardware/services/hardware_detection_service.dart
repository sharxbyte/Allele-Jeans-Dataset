import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart' as camera;
import 'package:camera/camera.dart' show CameraDescription, CameraLensDirection;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/models/pipeline_tier.dart';

/// Why a profiling step degraded. The profile still completes; these explain
/// which values are defaults rather than measured.
enum HardwareProbeFailureKind { noCameras, cameraEnumerationFailed, nativeChannelUnavailable, nativeProbeFailed }

class HardwareProbeFailure {
  final HardwareProbeFailureKind kind;
  final String message;
  const HardwareProbeFailure(this.kind, this.message);

  @override
  String toString() => '${kind.name}: $message';
}

class CameraLensCapabilities {
  final CameraDescription description;
  final double focalLengthMm;
  final double sensorWidthMm;
  final double sensorHeightMm;
  final int? pixelArrayWidth;
  final int? pixelArrayHeight;
  final bool supportsDepth;
  final bool supportsBurstCapture;
  final bool isLogicalMultiCamera;

  /// [fx, fy, cx, cy, skew] in pixels (Android API 28+), when the OEM reports it.
  final List<double>? intrinsicCalibration;

  /// [k1, k2, k3, p1, p2] (Android API 28+), when reported.
  final List<double>? distortion;

  /// True when focal/sensor values came from the device, false when defaulted.
  final bool isMeasured;

  const CameraLensCapabilities({
    required this.description,
    required this.focalLengthMm,
    required this.sensorWidthMm,
    required this.sensorHeightMm,
    required this.supportsDepth,
    this.pixelArrayWidth,
    this.pixelArrayHeight,
    this.supportsBurstCapture = false,
    this.isLogicalMultiCamera = false,
    this.intrinsicCalibration,
    this.distortion,
    this.isMeasured = false,
  });

  /// Typical phone main-camera values, used only when the device reports nothing.
  static const double defaultFocalLengthMm = 4.25;
  static const double defaultSensorWidthMm = 6.17;
  static const double defaultSensorHeightMm = 4.55;

  /// Horizontal field of view across the sensor's long edge, in degrees.
  double get horizontalFovDeg => 2 * _atanDeg(sensorWidthMm / (2 * focalLengthMm));

  /// Field of view across the sensor's short edge (the horizontal FOV when
  /// the phone is held in portrait).
  double get verticalFovDeg => 2 * _atanDeg(sensorHeightMm / (2 * focalLengthMm));

  /// Focal length in pixels along the sensor's long edge, for an image of
  /// [imageLongEdgePx]. Prefers OEM calibration when available.
  double focalLengthPx(int imageLongEdgePx) {
    final calib = intrinsicCalibration;
    if (calib != null && calib.length >= 2 && calib[0] > 0 && pixelArrayWidth != null && pixelArrayWidth! > 0) {
      return calib[0] * imageLongEdgePx / pixelArrayWidth!;
    }
    return focalLengthMm * imageLongEdgePx / sensorWidthMm;
  }

  static double _atanDeg(double x) => math.atan(x) * 180.0 / math.pi;
}

class MemoryProfile {
  final int totalBytes;
  final int availableBytes;
  final bool isLowMemory;
  final bool isLowRamDevice;
  const MemoryProfile({
    required this.totalBytes,
    required this.availableBytes,
    this.isLowMemory = false,
    this.isLowRamDevice = false,
  });

  double get totalGb => totalBytes / (1024 * 1024 * 1024);
  double get availableGb => availableBytes / (1024 * 1024 * 1024);
}

/// Android thermal status: 0 none … 6 shutdown. Headroom: 1.0 == throttling.
class ThermalProfile {
  final bool supported;
  final int? status;
  final double? headroom;
  final bool powerSaveMode;
  const ThermalProfile({this.supported = false, this.status, this.headroom, this.powerSaveMode = false});

  bool get isThrottlingLikely => (status ?? 0) >= 2 || (headroom ?? 0) >= 0.95;
}

class BatteryProfile {
  final double? percent;
  final bool isCharging;
  const BatteryProfile({this.percent, this.isCharging = false});
}

/// Everything Step 0 learned about the device. Values that could not be
/// measured are defaulted and listed in [failures].
class DeviceCapabilityProfile {
  final String platform;
  final String manufacturer;
  final String model;
  final String osVersion;
  final int? sdkInt;
  final String? socModel;
  final int cpuCores;
  final List<int?> cpuMaxFrequenciesKhz;
  final bool vulkanCompute;
  final MemoryProfile? memory;
  final ThermalProfile thermal;
  final BatteryProfile battery;
  final bool hasHardwareDepth;
  final bool arCoreInstalled;
  final bool hasAccelerometer;
  final bool hasGyroscope;
  final List<CameraLensCapabilities> lenses;
  final List<HardwareProbeFailure> failures;

  const DeviceCapabilityProfile({
    required this.platform,
    required this.manufacturer,
    required this.model,
    required this.osVersion,
    required this.cpuCores,
    required this.lenses,
    this.sdkInt,
    this.socModel,
    this.cpuMaxFrequenciesKhz = const [],
    this.vulkanCompute = false,
    this.memory,
    this.thermal = const ThermalProfile(),
    this.battery = const BatteryProfile(),
    this.hasHardwareDepth = false,
    this.arCoreInstalled = false,
    this.hasAccelerometer = true,
    this.hasGyroscope = true,
    this.failures = const [],
  });

  CameraLensCapabilities? get primaryRearLens {
    final rear = lenses.where((l) => l.description.lensDirection == CameraLensDirection.back).toList();
    if (rear.isEmpty) return lenses.isEmpty ? null : lenses.first;
    // Camera2 lists the main/logical rear camera first on virtually all devices.
    return rear.first;
  }

  /// Android background compute runs in a foreground service; iOS cannot run
  /// long background jobs, so compute must stay in the foreground there.
  bool get supportsBackgroundCompute => platform == 'android';

  /// Routes the device to a tier. Thresholds favour the lowest chance of failure.
  PipelineTier get recommendedTier {
    final mem = memory;
    final lowRam = mem != null && (mem.isLowRamDevice || mem.totalGb < 3.5);
    if (!hasAccelerometer || lowRam || primaryRearLens == null) return PipelineTier.tier3TwoView;
    if (hasHardwareDepth) return PipelineTier.tier1DepthTurntable;
    return PipelineTier.tier2RgbTurntable;
  }

  static DeviceCapabilityProfile fromNativeMap(
    Map<dynamic, dynamic>? map,
    List<CameraDescription> cameras, {
    String platform = 'android',
    List<HardwareProbeFailure> failures = const [],
  }) {
    final allFailures = <HardwareProbeFailure>[...failures];
    final m = map ?? const {};
    final device = _asMap(m['device']);
    final cpu = _asMap(m['cpu']);
    final gpu = _asMap(m['gpu']);
    final sensors = _asMap(m['sensors']);
    final memMap = m['memory'] == null ? null : _asMap(m['memory']);
    final thermal = _asMap(m['thermal']);
    final battery = _asMap(m['battery']);

    for (final e in (m['probeErrors'] as List<dynamic>? ?? const [])) {
      allFailures.add(HardwareProbeFailure(HardwareProbeFailureKind.nativeProbeFailed, e.toString()));
    }

    final nativeLenses = (m['lenses'] as List<dynamic>? ?? const []).map(_asMap).toList();
    final lenses = <CameraLensCapabilities>[];
    for (int i = 0; i < cameras.length; i++) {
      final cam = cameras[i];
      // On Android, CameraDescription.name is the Camera2 camera id. Match by
      // id; fall back to list position only if ids are not reported.
      Map<dynamic, dynamic>? lens;
      for (final l in nativeLenses) {
        if (l['cameraId']?.toString() == cam.name) {
          lens = l;
          break;
        }
      }
      lens ??= (nativeLenses.length == cameras.length) ? nativeLenses[i] : null;
      lenses.add(_lensFrom(cam, lens));
    }

    return DeviceCapabilityProfile(
      platform: platform,
      manufacturer: device['manufacturer']?.toString() ?? 'unknown',
      model: device['model']?.toString() ?? 'unknown',
      osVersion: device['osVersion']?.toString() ?? Platform.operatingSystemVersion,
      sdkInt: (device['sdkInt'] as num?)?.toInt(),
      socModel: device['socModel']?.toString(),
      cpuCores: (cpu['cores'] as num?)?.toInt() ?? Platform.numberOfProcessors,
      cpuMaxFrequenciesKhz:
          (cpu['maxFrequenciesKhz'] as List<dynamic>? ?? const []).map((e) => (e as num?)?.toInt()).toList(),
      vulkanCompute: gpu['vulkanCompute'] as bool? ?? false,
      memory: memMap == null
          ? null
          : MemoryProfile(
              totalBytes: (memMap['totalBytes'] as num?)?.toInt() ?? 0,
              availableBytes: (memMap['availableBytes'] as num?)?.toInt() ?? 0,
              isLowMemory: memMap['isLowMemory'] as bool? ?? false,
              isLowRamDevice: memMap['isLowRamDevice'] as bool? ?? false,
            ),
      thermal: thermalFrom(thermal),
      battery: batteryFrom(battery),
      hasHardwareDepth: m['hasLidarToF'] as bool? ?? false,
      arCoreInstalled: _asMap(m['arCore'])['installed'] as bool? ?? false,
      hasAccelerometer: sensors['accelerometer'] as bool? ?? true,
      hasGyroscope: sensors['gyroscope'] as bool? ?? true,
      lenses: lenses,
      failures: allFailures,
    );
  }

  static ThermalProfile thermalFrom(Map<dynamic, dynamic> t) => ThermalProfile(
        supported: t['supported'] as bool? ?? false,
        status: (t['status'] as num?)?.toInt(),
        headroom: (t['headroom10s'] as num?)?.toDouble(),
        powerSaveMode: t['powerSaveMode'] as bool? ?? false,
      );

  static BatteryProfile batteryFrom(Map<dynamic, dynamic> b) => BatteryProfile(
        percent: (b['percent'] as num?)?.toDouble(),
        isCharging: b['isCharging'] as bool? ?? false,
      );

  static CameraLensCapabilities _lensFrom(CameraDescription cam, Map<dynamic, dynamic>? lens) {
    if (lens == null) {
      return CameraLensCapabilities(
        description: cam,
        focalLengthMm: CameraLensCapabilities.defaultFocalLengthMm,
        sensorWidthMm: CameraLensCapabilities.defaultSensorWidthMm,
        sensorHeightMm: CameraLensCapabilities.defaultSensorHeightMm,
        supportsDepth: false,
      );
    }
    final focal = (lens['focalLength'] as num?)?.toDouble();
    final sw = (lens['sensorWidth'] as num?)?.toDouble();
    final sh = (lens['sensorHeight'] as num?)?.toDouble();
    List<double>? doubles(dynamic v) => (v as List<dynamic>?)?.map((e) => (e as num).toDouble()).toList();
    return CameraLensCapabilities(
      description: cam,
      focalLengthMm: (focal != null && focal > 0) ? focal : CameraLensCapabilities.defaultFocalLengthMm,
      sensorWidthMm: (sw != null && sw > 0) ? sw : CameraLensCapabilities.defaultSensorWidthMm,
      sensorHeightMm: (sh != null && sh > 0) ? sh : CameraLensCapabilities.defaultSensorHeightMm,
      pixelArrayWidth: (lens['pixelArrayWidth'] as num?)?.toInt(),
      pixelArrayHeight: (lens['pixelArrayHeight'] as num?)?.toInt(),
      supportsDepth: (lens['supportsDepthOutput'] ?? lens['supportsDepth']) as bool? ?? false,
      supportsBurstCapture: lens['supportsBurstCapture'] as bool? ?? false,
      isLogicalMultiCamera: lens['isLogicalMultiCamera'] as bool? ?? false,
      intrinsicCalibration: doubles(lens['intrinsicCalibration']),
      distortion: doubles(lens['distortion']),
      isMeasured: focal != null && sw != null && sh != null,
    );
  }

  static Map<dynamic, dynamic> _asMap(dynamic v) => v is Map ? v : const {};
}

/// Live snapshot for the resource governor.
class RuntimeResourceStatus {
  final MemoryProfile? memory;
  final ThermalProfile thermal;
  final BatteryProfile battery;
  const RuntimeResourceStatus({this.memory, this.thermal = const ThermalProfile(), this.battery = const BatteryProfile()});
}

class HardwareDetectionService {
  static const MethodChannel _platformChannel = MethodChannel('com.allele.photogrammetry/hardware_intrinsics');

  List<CameraDescription> _availableCameras = [];
  DeviceCapabilityProfile? _profile;

  List<CameraDescription> get availableCameras => _availableCameras;
  DeviceCapabilityProfile? get profile => _profile;
  List<CameraLensCapabilities> get lensCapabilities => _profile?.lenses ?? const [];
  bool get hasLidarToF => _profile?.hasHardwareDepth ?? false;
  PipelineTier get recommendedTier => _profile?.recommendedTier ?? PipelineTier.tier3TwoView;

  /// Step 0. Never throws: every failure is recorded on the returned profile
  /// and the affected values fall back to safe defaults.
  Future<DeviceCapabilityProfile> initializeHardware() async {
    final failures = <HardwareProbeFailure>[];
    try {
      _availableCameras = await camera.availableCameras();
      if (_availableCameras.isEmpty) {
        failures.add(const HardwareProbeFailure(HardwareProbeFailureKind.noCameras, 'No cameras reported by the device.'));
      }
    } on camera.CameraException catch (e) {
      _availableCameras = [];
      failures.add(HardwareProbeFailure(HardwareProbeFailureKind.cameraEnumerationFailed, '${e.code}: ${e.description}'));
    }

    Map<dynamic, dynamic>? nativeInfo;
    final platform = Platform.isIOS ? 'ios' : (Platform.isAndroid ? 'android' : Platform.operatingSystem);
    try {
      nativeInfo = await _platformChannel.invokeMethod<Map<dynamic, dynamic>>('getHardwareCapabilities');
    } on PlatformException catch (e) {
      failures.add(HardwareProbeFailure(HardwareProbeFailureKind.nativeProbeFailed, '${e.code}: ${e.message}'));
    } on MissingPluginException {
      failures.add(HardwareProbeFailure(
        HardwareProbeFailureKind.nativeChannelUnavailable,
        'No native hardware profiler on $platform; using defaults.',
      ));
    }

    _profile = DeviceCapabilityProfile.fromNativeMap(nativeInfo, _availableCameras, platform: platform, failures: failures);
    for (final f in _profile!.failures) {
      debugPrint('[HardwareDetection] $f');
    }
    return _profile!;
  }

  /// Polled by the resource governor. Returns null if the native side is unavailable.
  Future<RuntimeResourceStatus?> readRuntimeStatus() async {
    try {
      final m = await _platformChannel.invokeMethod<Map<dynamic, dynamic>>('getRuntimeStatus');
      if (m == null) return null;
      final mem = m['memory'] is Map ? m['memory'] as Map : null;
      return RuntimeResourceStatus(
        memory: mem == null
            ? null
            : MemoryProfile(
                totalBytes: (mem['totalBytes'] as num?)?.toInt() ?? 0,
                availableBytes: (mem['availableBytes'] as num?)?.toInt() ?? 0,
                isLowMemory: mem['isLowMemory'] as bool? ?? false,
              ),
        thermal: DeviceCapabilityProfile.thermalFrom(m['thermal'] is Map ? m['thermal'] as Map : const {}),
        battery: DeviceCapabilityProfile.batteryFrom(m['battery'] is Map ? m['battery'] as Map : const {}),
      );
    } on PlatformException catch (e) {
      debugPrint('[HardwareDetection] runtime status failed: ${e.code}: ${e.message}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
