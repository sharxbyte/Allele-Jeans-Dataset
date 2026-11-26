import 'dart:typed_data';

import 'json_helpers.dart';

/// One 2D keypoint in image pixels. [index] is the ML Kit PoseLandmarkType index (0–32).
class Keypoint2D {
  final int index;
  final double x;
  final double y;
  final double confidence;

  const Keypoint2D({required this.index, required this.x, required this.y, required this.confidence});

  Map<String, dynamic> toJson() => {'i': index, 'x': x, 'y': y, 'c': confidence};

  factory Keypoint2D.fromJson(Map<String, dynamic> j) => Keypoint2D(
        index: (j['i'] as num).toInt(),
        x: reqDouble(j['x'], 'x'),
        y: reqDouble(j['y'], 'y'),
        confidence: reqDouble(j['c'], 'c'),
      );
}

/// Binary mask stored as alternating run lengths, row-major, starting with
/// a run of background (0) pixels.
class RleMask {
  final int width;
  final int height;
  final Uint32List runs;

  const RleMask({required this.width, required this.height, required this.runs});

  factory RleMask.encode(Uint8List mask, int width, int height) {
    if (mask.length != width * height) {
      throw ArgumentError('mask length ${mask.length} != $width x $height');
    }
    final runs = <int>[];
    int current = 0;
    int count = 0;
    for (final px in mask) {
      final v = px == 0 ? 0 : 1;
      if (v == current) {
        count++;
      } else {
        runs.add(count);
        current = v;
        count = 1;
      }
    }
    runs.add(count);
    return RleMask(width: width, height: height, runs: Uint32List.fromList(runs));
  }

  Uint8List decode() {
    final out = Uint8List(width * height);
    int pos = 0;
    int value = 0;
    for (final r in runs) {
      if (value == 1) out.fillRange(pos, pos + r, 1);
      pos += r;
      value ^= 1;
    }
    return out;
  }

  int get foregroundArea {
    int area = 0;
    for (int i = 1; i < runs.length; i += 2) {
      area += runs[i];
    }
    return area;
  }

  Map<String, dynamic> toJson() => {'w': width, 'h': height, 'runs': runs.toList()};

  factory RleMask.fromJson(Map<String, dynamic> j) => RleMask(
        width: (j['w'] as num).toInt(),
        height: (j['h'] as num).toInt(),
        runs: Uint32List.fromList(asJsonList(j['runs']).map((e) => (e as num).toInt()).toList()),
      );
}

enum SegmentationMethod { mobileSam, grabCut }

/// Per-frame perception output: what the fitter consumes. No pixels.
class FrameObservation {
  /// Index into the session's keyframe list.
  final int frameIndex;
  final int timestampMs;
  final List<Keypoint2D> keypoints;
  final RleMask? mask;
  final SegmentationMethod? maskMethod;

  /// 0..1 mask quality score from the segmentation checks.
  final double maskQuality;

  /// Initial estimate of the person's rotation (deg, 0 = facing camera).
  final double? yawEstimateDeg;

  const FrameObservation({
    required this.frameIndex,
    required this.timestampMs,
    required this.keypoints,
    this.mask,
    this.maskMethod,
    this.maskQuality = 0,
    this.yawEstimateDeg,
  });

  Map<String, dynamic> toJson() => {
        'frame_index': frameIndex,
        'timestamp_ms': timestampMs,
        'keypoints': keypoints.map((k) => k.toJson()).toList(),
        'mask': mask?.toJson(),
        'mask_method': maskMethod?.name,
        'mask_quality': maskQuality,
        'yaw_estimate_deg': yawEstimateDeg,
      };

  factory FrameObservation.fromJson(Map<String, dynamic> j) => FrameObservation(
        frameIndex: (j['frame_index'] as num).toInt(),
        timestampMs: (j['timestamp_ms'] as num).toInt(),
        keypoints: asJsonList(j['keypoints']).map((k) => Keypoint2D.fromJson(asJsonMap(k, 'keypoint'))).toList(),
        mask: j['mask'] == null ? null : RleMask.fromJson(asJsonMap(j['mask'], 'mask')),
        maskMethod: enumByNameOrNull(SegmentationMethod.values, j['mask_method']),
        maskQuality: optDouble(j['mask_quality']) ?? 0,
        yawEstimateDeg: optDouble(j['yaw_estimate_deg']),
      );
}
