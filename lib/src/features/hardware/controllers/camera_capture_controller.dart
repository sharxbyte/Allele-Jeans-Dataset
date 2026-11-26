import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:image/image.dart' as img;

import '../../../core/failures/pipeline_failure.dart';
import '../../../core/models/capture_session.dart';
import '../../../core/models/frame_observation.dart';
import '../../photogrammetry/perception/pose_keypoint_service.dart';
import '../services/hardware_detection_service.dart';
import '../services/vio_motion_engine.dart';

enum CaptureState { uninitialized, ready, guiding, capturing, error }

/// Which pose the live guidance is checking for.
enum GuidanceTarget { front, side, turntable }

/// Live framing/pose assessment from the preview stream.
class GuidanceState {
  final bool personVisible;
  final bool level;
  final bool framed; // whole body in view with margin, good size
  final bool posed; // arms out, feet apart, facing as required
  final List<String> prompts; // most important first
  final List<Keypoint2D> keypoints; // upright preview pixel coords
  final Size previewSize; // upright
  const GuidanceState({
    required this.personVisible,
    required this.level,
    required this.framed,
    required this.posed,
    required this.prompts,
    required this.keypoints,
    required this.previewSize,
  });

  bool get ready => personVisible && level && framed && posed;

  static const empty = GuidanceState(
      personVisible: false, level: false, framed: false, posed: false, prompts: ['Step into view'], keypoints: [], previewSize: Size(1, 1));
}

/// A captured photo (JPEG in the app cache until exported).
class CapturedFrame {
  final XFile file;
  final CapturedMediaKind kind;
  final int timestampMs;
  final List<double> gravity;
  final double? yawHintRad;
  const CapturedFrame({required this.file, required this.kind, required this.timestampMs, required this.gravity, this.yawHintRad});
}

/// Camera for the tripod capture: preview + guidance stream, burst stills and
/// a turntable sequence of stills (the person turning in place).
class CameraCaptureController extends ChangeNotifier {
  final HardwareDetectionService hardwareService;
  final VioMotionEngine vioEngine;

  CameraCaptureController({required this.hardwareService, required this.vioEngine});

  CameraController? _camera;
  CameraLensCapabilities? _lens;
  CaptureState _state = CaptureState.uninitialized;
  String _statusMessage = 'Starting camera…';
  GuidanceState _guidance = GuidanceState.empty;
  PoseKeypointService? _livePose;
  GuidanceTarget _target = GuidanceTarget.front;
  bool _processingFrame = false;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
  double? _frontShoulderWidthFrac;
  bool _stopTurntable = false;
  bool _handheld = false;
  DateTime? _movingSince;

  /// Switches on automatically when the phone keeps moving (someone holding it).
  bool get handheld => _handheld;

  CameraController? get activeCameraController => _camera;
  CaptureState get captureState => _state;
  String get statusMessage => _statusMessage;
  GuidanceState get guidance => _guidance;
  bool get isInitialized => _camera?.value.isInitialized ?? false;
  CameraLensCapabilities? get lens => _lens;

  Future<void> initialize() async {
    if (isInitialized) return;
    try {
      final profile = await hardwareService.initializeHardware();
      final lens = profile.primaryRearLens;
      if (lens == null) {
        _fail('No rear camera was found on this device.');
        return;
      }
      _lens = lens;
      final c = CameraController(lens.description, ResolutionPreset.veryHigh,
          enableAudio: false, imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888);
      await c.initialize();
      await c.lockCaptureOrientation(DeviceOrientation.portraitUp);
      await c.setFlashMode(FlashMode.off);
      _camera = c;
      vioEngine.startTracking();
      _state = CaptureState.ready;
      _statusMessage = 'Camera ready.';
      notifyListeners();
    } on CameraException catch (e) {
      _fail(e.code == 'CameraAccessDenied' ? 'Camera permission is needed to measure you.' : 'The camera could not start (${e.code}).');
    } catch (e) {
      _fail('The camera could not start: $e');
    }
  }

  void _fail(String message) {
    _state = CaptureState.error;
    _statusMessage = message;
    notifyListeners();
  }

  // ---- live guidance ----------------------------------------------------------

  Future<void> startGuidance(PoseKeypointService pose, GuidanceTarget target) async {
    final c = _camera;
    if (c == null) return;
    _livePose = pose;
    _target = target;
    _state = CaptureState.guiding;
    if (!c.value.isStreamingImages) {
      try {
        await c.startImageStream(_onPreviewFrame);
      } on CameraException catch (e) {
        _statusMessage = 'Live guidance unavailable (${e.code}); you can still capture.';
      }
    }
    notifyListeners();
  }

  void setGuidanceTarget(GuidanceTarget t) {
    _target = t;
  }

  Future<void> stopGuidance() async {
    final c = _camera;
    if (c != null && c.value.isStreamingImages) {
      try {
        await c.stopImageStream();
      } on CameraException {
        // already stopped
      }
    }
    if (_state == CaptureState.guiding) _state = CaptureState.ready;
  }

  Future<void> _onPreviewFrame(CameraImage image) async {
    final now = DateTime.now();
    if (_processingFrame || now.difference(_lastFrame).inMilliseconds < 250 || _livePose == null) return;
    _processingFrame = true;
    _lastFrame = now;
    try {
      final input = _toInputImage(image);
      if (input == null) return;
      final kps = await _livePose!.detectNv21(input);
      final rot = _camera!.description.sensorOrientation;
      final upright = (rot == 90 || rot == 270) ? Size(image.height.toDouble(), image.width.toDouble()) : Size(image.width.toDouble(), image.height.toDouble());
      // Detect a hand-held phone: moving for more than 4 s in total.
      if (!_handheld) {
        if (!vioEngine.isStationary) {
          _movingSince ??= now;
          if (now.difference(_movingSince!).inSeconds >= 4) _handheld = true;
        } else {
          _movingSince = null;
        }
      }
      _guidance = assessGuidance(kps, upright, vioEngine, _target, frontShoulderWidthFrac: _frontShoulderWidthFrac, handheld: _handheld);
      notifyListeners();
    } catch (_) {
      // A dropped guidance frame is harmless.
    } finally {
      _processingFrame = false;
    }
  }

  InputImage? _toInputImage(CameraImage image) {
    if (image.planes.isEmpty) return null;
    final rotation = InputImageRotationValue.fromRawValue(_camera!.description.sensorOrientation) ?? InputImageRotation.rotation0deg;
    final format = InputImageFormatValue.fromRawValue(image.format.raw as int) ??
        (Platform.isAndroid ? InputImageFormat.nv21 : InputImageFormat.bgra8888);
    return InputImage.fromBytes(
      bytes: image.planes.first.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  /// Pure assessment used by the HUD (exposed for tests).
  static GuidanceState assessGuidance(List<Keypoint2D> kps, Size preview, VioMotionEngine vio, GuidanceTarget target,
      {double? frontShoulderWidthFrac, bool handheld = false}) {
    final prompts = <String>[];
    // Tripod: level within 3° and still. Handheld: within 10° and steady enough
    // to avoid blur; each frame's tilt is recorded and corrected in the fit.
    final level = handheld ? vio.isSteadyEnoughHandheld() : vio.isLevelForCapture();
    if (handheld && !level) {
      prompts.add(vio.tilt.isPortrait ? 'Hold the phone upright and as steady as you can' : 'Hold the phone upright (portrait)');
    } else if (!handheld && (!vio.hasReading || !vio.isStationary)) {
      prompts.add('Place the phone on a stable surface or tripod');
    } else if (!level) {
      if (!vio.tilt.isPortrait) {
        prompts.add('Stand the phone upright (portrait)');
      } else if (vio.pitchAngleDeg.abs() > vio.rollAngleDeg.abs()) {
        prompts.add(vio.pitchAngleDeg > 0 ? 'Tilt the top of the phone back' : 'Tilt the top of the phone forward');
      } else {
        prompts.add('Straighten the phone (it is leaning sideways)');
      }
    }
    final b = kps.bounds(minConfidence: 0.5);
    if (b == null) {
      return GuidanceState(personVisible: false, level: level, framed: false, posed: false, prompts: [...prompts, 'Step into view'], keypoints: kps, previewSize: preview);
    }
    final w = preview.width, h = preview.height;
    // Head top ≈ nose minus ~0.55 × nose-to-shoulder; feet = lowest heel/toe.
    final nose = kps.at(PoseLandmarkType.nose, minConfidence: 0.3);
    final shoulderY = [kps.at(PoseLandmarkType.leftShoulder), kps.at(PoseLandmarkType.rightShoulder)].whereType<Keypoint2D>().map((k) => k.y);
    final headTop = nose != null && shoulderY.isNotEmpty ? nose.y - 0.9 * (shoulderY.reduce(math.min) - nose.y).abs() : b[1];
    final feet = [PoseLandmarkType.leftHeel, PoseLandmarkType.rightHeel, PoseLandmarkType.leftFootIndex, PoseLandmarkType.rightFootIndex]
        .map((t) => kps.at(t, minConfidence: 0.3))
        .whereType<Keypoint2D>()
        .map((k) => k.y);
    final feetBottom = feet.isEmpty ? double.nan : feet.reduce(math.max);
    final heightFrac = feetBottom.isNaN ? 0.0 : (feetBottom - headTop) / h;
    final centreX = (b[0] + b[2]) / 2 / w;
    bool framed = true;
    if (feetBottom.isNaN || feetBottom > 0.97 * h || headTop < 0.03 * h) {
      prompts.add('Step back so your whole body fits, head to feet');
      framed = false;
    } else if (heightFrac < 0.6) {
      prompts.add('Step closer to the phone');
      framed = false;
    } else if (heightFrac > 0.88) {
      prompts.add('Step back a little');
      framed = false;
    }
    if ((centreX - 0.5).abs() > 0.15) {
      prompts.add(centreX < 0.5 ? 'Move to your left' : 'Move to your right');
      framed = false;
    }
    bool posed = true;
    if (target != GuidanceTarget.turntable) {
      final lw = kps.at(PoseLandmarkType.leftWrist), rw = kps.at(PoseLandmarkType.rightWrist);
      final lh = kps.at(PoseLandmarkType.leftHip), rh = kps.at(PoseLandmarkType.rightHip);
      final la = kps.at(PoseLandmarkType.leftAnkle), ra = kps.at(PoseLandmarkType.rightAnkle);
      final ls = kps.at(PoseLandmarkType.leftShoulder), rs = kps.at(PoseLandmarkType.rightShoulder);
      if (target == GuidanceTarget.front) {
        if (ls == null || rs == null || ls.x < rs.x) {
          prompts.add('Face the phone');
          posed = false;
        } else {
          final shoulderW = (ls.x - rs.x);
          // Arms must be clearly away from the body: where they rest against the
          // torso the silhouette cannot separate arm from torso, and the fit
          // trades one for the other (real scan at ~8° abduction: waist ±5 cm
          // between solver runs). Require ~20° shoulder→wrist abduction and the
          // wrist well outside the hip.
          double abduction(Keypoint2D s, Keypoint2D wr) =>
              math.atan2((wr.x - s.x).abs(), math.max(1e-6, wr.y - s.y)) * 180 / math.pi;
          if (lw != null && lh != null && rw != null && rh != null &&
              (abduction(ls, lw) < 20 || abduction(rs, rw) < 20 ||
                  (lw.x - lh.x) < 0.45 * shoulderW || (rh.x - rw.x) < 0.45 * shoulderW)) {
            prompts.add('Lift your arms out from your sides, like the letter A');
            posed = false;
          }
          if (la != null && ra != null && (la.x - ra.x) < 0.35 * shoulderW) {
            prompts.add('Stand with your feet hip-width apart');
            posed = false;
          }
        }
      } else if (target == GuidanceTarget.side) {
        if (ls != null && rs != null && frontShoulderWidthFrac != null && (ls.x - rs.x).abs() / w > 0.5 * frontShoulderWidthFrac) {
          prompts.add('Turn a quarter turn to your left so your side faces the phone');
          posed = false;
        }
      }
    }
    if (prompts.isEmpty) prompts.add('Perfect — hold still');
    return GuidanceState(
        personVisible: true, level: level, framed: framed, posed: posed, prompts: prompts, keypoints: kps, previewSize: preview);
  }

  /// Remember the front-facing shoulder width so the side/turntable checks can compare.
  void rememberFrontShoulderWidth() {
    final ls = _guidance.keypoints.at(PoseLandmarkType.leftShoulder), rs = _guidance.keypoints.at(PoseLandmarkType.rightShoulder);
    if (ls != null && rs != null) _frontShoulderWidthFrac = (ls.x - rs.x).abs() / _guidance.previewSize.width;
  }

  // ---- capture ------------------------------------------------------------------

  /// Locks exposure, focus and white balance for the rest of the sequence
  /// (best effort: some devices do not support all locks).
  Future<void> lockForCapture() async {
    final c = _camera;
    if (c == null) return;
    for (final f in <Future<void> Function()>[
      () => c.setFocusMode(FocusMode.locked),
      () => c.setExposureMode(ExposureMode.locked),
    ]) {
      try {
        await f();
      } on CameraException {
        // unsupported lock: continue
      }
    }
  }

  Future<void> unlockAfterCapture() async {
    final c = _camera;
    if (c == null) return;
    try {
      await c.setFocusMode(FocusMode.auto);
      await c.setExposureMode(ExposureMode.auto);
    } on CameraException {
      // ignore
    }
  }

  List<double> get _gravity {
    final g = vioEngine.gravityVector;
    return [g.x, g.y, g.z];
  }

  /// Takes [count] stills and keeps the sharpest (Laplacian variance).
  Future<CapturedFrame> captureBurst(CapturedMediaKind kind, {int count = 3}) async {
    final c = _camera;
    if (c == null) throw const CaptureFailure('camera_not_ready', 'no camera', 'The camera is not ready.');
    await stopGuidance();
    _state = CaptureState.capturing;
    notifyListeners();
    try {
      final shots = <(XFile, int)>[];
      for (int i = 0; i < count; i++) {
        final f = await c.takePicture();
        shots.add((f, DateTime.now().millisecondsSinceEpoch));
      }
      double best = -1;
      (XFile, int)? bestShot;
      for (final s in shots) {
        final score = await compute(_sharpness, await s.$1.readAsBytes());
        if (score > best) {
          best = score;
          bestShot = s;
        }
      }
      for (final s in shots) {
        if (!identical(s, bestShot)) await _deletePlain(s.$1);
      }
      return CapturedFrame(file: bestShot!.$1, kind: kind, timestampMs: bestShot.$2, gravity: _gravity, yawHintRad: kind == CapturedMediaKind.sideStill ? math.pi / 2 : 0);
    } on CameraException catch (e) {
      throw CaptureFailure('take_picture', '${e.code}: ${e.description}', 'A photo could not be taken.', e);
    } finally {
      _state = CaptureState.ready;
      notifyListeners();
    }
  }

  void requestStopTurntable() => _stopTurntable = true;

  /// Records the turn and returns the video file itself (kept, not decoded) with a gravity log [(ms since start, [x,y,z])] every 100 ms.
  /// Frames are extracted offline (tools/refine), so no platform code is needed.
  Future<(XFile, List<(int, List<double>)>)> recordVideoKeep({
    Duration duration = const Duration(seconds: 22),
    void Function(Duration elapsed)? onTick,
  }) async {
    final c = _camera;
    if (c == null) throw const CaptureFailure('camera_not_ready', 'no camera', 'The camera is not ready.');
    await stopGuidance();
    _state = CaptureState.capturing;
    _stopTurntable = false;
    notifyListeners();
    try {
      await c.startVideoRecording();
      final start = DateTime.now();
      final gLog = <(int, List<double>)>[(0, _gravity)];
      final sampler = Timer.periodic(const Duration(milliseconds: 100), (_) {
        gLog.add((DateTime.now().difference(start).inMilliseconds, _gravity));
      });
      try {
        while (!_stopTurntable) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          final elapsed = DateTime.now().difference(start);
          onTick?.call(elapsed);
          if (elapsed >= duration) break;
        }
      } finally {
        sampler.cancel();
      }
      return (await c.stopVideoRecording(), gLog);
    } on CameraException catch (e) {
      throw CaptureFailure('video', '${e.code}: ${e.description}', 'The turning video could not be recorded.', e);
    } finally {
      _state = CaptureState.ready;
      notifyListeners();
    }
  }

  /// Lens description for export metadata (null before [initialize]).
  Map<String, dynamic>? lensInfoJson() {
    final l = _lens;
    if (l == null) return null;
    return {
      'focal_length_mm': l.focalLengthMm,
      'sensor_width_mm': l.sensorWidthMm,
      'sensor_height_mm': l.sensorHeightMm,
      'pixel_array': [l.pixelArrayWidth, l.pixelArrayHeight],
      'intrinsic_calibration': l.intrinsicCalibration,
      'distortion': l.distortion,
      'is_measured': l.isMeasured,
      'fx_for_1920_long_edge': l.focalLengthPx(1920),
    };
  }

  static Future<void> _deletePlain(XFile f) async {
    try {
      await File(f.path).delete();
    } catch (_) {}
  }

  /// Focal length in pixels for an upright image whose long edge is [longEdgePx].
  double focalPxForLongEdge(int longEdgePx) {
    final l = _lens;
    if (l == null) return longEdgePx * 0.8; // ~65° FOV fallback
    return l.focalLengthPx(longEdgePx);
  }

  @override
  void dispose() {
    vioEngine.stopTracking();
    _camera?.dispose();
    super.dispose();
  }
}

/// Variance of a 4-neighbour Laplacian on a downsized grey image (higher = sharper).
double _sharpness(Uint8List jpeg) {
  final d = img.decodeJpg(jpeg);
  if (d == null) return 0;
  final s = img.copyResize(img.grayscale(d), width: 360);
  double sum = 0, sum2 = 0;
  int n = 0;
  for (int y = 1; y < s.height - 1; y++) {
    for (int x = 1; x < s.width - 1; x++) {
      final l = 4 * s.getPixel(x, y).r - s.getPixel(x - 1, y).r - s.getPixel(x + 1, y).r - s.getPixel(x, y - 1).r - s.getPixel(x, y + 1).r;
      sum += l;
      sum2 += l * l;
      n++;
    }
  }
  final mean = sum / n;
  return sum2 / n - mean * mean;
}
