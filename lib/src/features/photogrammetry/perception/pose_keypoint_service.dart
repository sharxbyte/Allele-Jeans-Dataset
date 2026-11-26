import 'dart:math' as math;

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../../../core/failures/pipeline_failure.dart';
import '../../../core/models/frame_observation.dart';
import 'image_utils.dart';

/// ML Kit (BlazePose) landmark index → Anny keypoint name (anny_v1.bin).
/// ML Kit "left" is the subject's left, as is Anny's ".L".
const Map<int, String> mlkitToAnny = {
  0: 'nose',
  2: 'left_eye',
  5: 'right_eye',
  7: 'left_ear',
  8: 'right_ear',
  11: 'left_shoulder',
  12: 'right_shoulder',
  13: 'left_elbow',
  14: 'right_elbow',
  15: 'left_wrist',
  16: 'right_wrist',
  23: 'left_hip',
  24: 'right_hip',
  25: 'left_knee',
  26: 'right_knee',
  27: 'left_ankle',
  28: 'right_ankle',
  29: 'left_heel',
  30: 'right_heel',
  31: 'left_big_toe',
  32: 'right_big_toe',
};

/// ML Kit pose wrapper. Keypoints are in the pixel frame of the image passed in.
class PoseKeypointService {
  PoseDetector? _detector;
  final PoseDetectionMode mode;
  PoseKeypointService({this.mode = PoseDetectionMode.single});

  Future<void> initialize() async {
    try {
      _detector ??= PoseDetector(options: PoseDetectorOptions(model: PoseDetectionModel.accurate, mode: mode));
    } catch (e) {
      throw PoseDetectionFailure('mlkit_init', e.toString(), 'Body landmark detection could not start.', e);
    }
  }

  Future<List<Keypoint2D>> detectRgb(RgbImage image) async {
    final input = InputImage.fromBitmap(bitmap: image.toBgra(), width: image.width, height: image.height);
    return _run(input);
  }

  /// Live camera frames (NV21, as delivered by the camera plugin on Android).
  Future<List<Keypoint2D>> detectNv21(InputImage input) => _run(input);

  Future<List<Keypoint2D>> _run(InputImage input) async {
    final d = _detector;
    if (d == null) throw const PoseDetectionFailure('mlkit_not_ready', 'initialize() not called', 'Body landmark detection is not ready.');
    try {
      final poses = await d.processImage(input);
      if (poses.isEmpty) return const [];
      // Several people: keep the pose with the largest shoulder-to-ankle span.
      Pose best = poses.first;
      double bestSpan = -1;
      for (final p in poses) {
        final s = p.landmarks[PoseLandmarkType.leftShoulder], a = p.landmarks[PoseLandmarkType.leftAnkle];
        final span = (s != null && a != null) ? (a.y - s.y).abs() : 0.0;
        if (span > bestSpan) {
          bestSpan = span;
          best = p;
        }
      }
      return [
        for (final e in best.landmarks.entries)
          Keypoint2D(index: e.key.index, x: e.value.x, y: e.value.y, confidence: e.value.likelihood),
      ];
    } catch (e) {
      throw PoseDetectionFailure('mlkit_process', e.toString(), 'Body landmarks could not be detected in a photo.', e);
    }
  }

  Future<void> dispose() async {
    await _detector?.close();
    _detector = null;
  }
}

/// Helpers on ML Kit keypoint lists (indices are PoseLandmarkType.index).
extension KeypointList on List<Keypoint2D> {
  Keypoint2D? at(PoseLandmarkType t, {double minConfidence = 0.5}) {
    for (final k in this) {
      if (k.index == t.index && k.confidence >= minConfidence) return k;
    }
    return null;
  }

  /// Bounding box (left, top, right, bottom) of confident keypoints, or null.
  List<double>? bounds({double minConfidence = 0.5}) {
    final ks = where((k) => k.confidence >= minConfidence).toList();
    if (ks.length < 4) return null;
    return [
      ks.map((k) => k.x).reduce(math.min),
      ks.map((k) => k.y).reduce(math.min),
      ks.map((k) => k.x).reduce(math.max),
      ks.map((k) => k.y).reduce(math.max),
    ];
  }

  /// Rough facing estimate from shoulder geometry: 0 = facing the camera,
  /// ±π/2 = profile, π = back. Sign from the left/right shoulder order.
  /// Returns null when shoulders are not both visible.
  double? yawEstimate({double? shoulderWidthFrontPx}) {
    final l = at(PoseLandmarkType.leftShoulder, minConfidence: 0.3), r = at(PoseLandmarkType.rightShoulder, minConfidence: 0.3);
    if (l == null || r == null) return null;
    final dx = l.x - r.x; // facing camera: subject's left appears on image right (dx > 0)
    if (shoulderWidthFrontPx == null || shoulderWidthFrontPx <= 0) return dx >= 0 ? 0.0 : math.pi;
    final c = (dx / shoulderWidthFrontPx).clamp(-1.0, 1.0);
    return math.acos(c);
  }
}
