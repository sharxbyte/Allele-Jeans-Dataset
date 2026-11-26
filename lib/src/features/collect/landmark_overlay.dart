import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../core/models/frame_observation.dart';
import 'collect_models.dart';

/// A guide line for one landmark, in image pixels.
class GuideLine {
  final LandmarkDef def;
  final double y, x0, x1;
  const GuideLine(this.def, this.y, this.x0, this.x1);
}

/// Approximate landmark heights from 2D pose keypoints (ML Kit / BlazePose
/// indices). These are guides for where to look; the measurer finds the exact
/// spot with the landmark description.
List<GuideLine> guideLines(List<Keypoint2D> kps, {required bool sideView}) {
  Keypoint2D? g(int i) {
    Keypoint2D? best;
    for (final k in kps) {
      if (k.index == i && k.confidence >= 0.3 && (best == null || k.confidence > best.confidence)) best = k;
    }
    return best;
  }

  Keypoint2D? either(int a, int b) => g(a) ?? g(b);
  final lsh = either(11, 12), rsh = either(12, 11), lhip = either(23, 24), rhip = either(24, 23);
  final lkn = either(25, 26), rkn = either(26, 25), lan = either(27, 28), ran = either(28, 27);
  if (lsh == null || rsh == null || lhip == null || rhip == null || lkn == null || rkn == null || lan == null || ran == null) return const [];
  final nose = g(0);
  final s = (lsh.y + rsh.y) / 2, hj = (lhip.y + rhip.y) / 2;
  final top = nose?.y ?? s - 0.15 * (lan.y - s);
  final bodyH = math.max(1.0, (lan.y + ran.y) / 2 - top);
  final cx = (lsh.x + rsh.x + lhip.x + rhip.x) / 4;
  final shoulderW = (lsh.x - rsh.x).abs();
  final torsoHalf = sideView ? 0.15 * bodyH : math.max(0.75 * shoulderW, 0.14 * bodyH);
  final legHalf = 0.06 * bodyH;

  double lerp(double a, double b, double t) => a + (b - a) * t;
  final out = <GuideLine>[];
  for (final d in kLandmarks) {
    switch (d.span) {
      case LandmarkSpan.torso:
        final t = switch (d.id) {
          'allele_chest_circ' => 0.25,
          'allele_underbust_circ' => 0.42,
          'waist_natural_circ' => 0.60,
          'allele_navel_circ' => 0.72,
          'allele_abdomen_max_circ' => -1.0, // varies; no line
          'highhip_circ' => 0.86,
          _ => 1.06, // seat: just below the hip joints
        };
        if (t < 0) continue;
        final y = d.id == 'hip_circ' ? lerp(hj, (lkn.y + rkn.y) / 2, 0.08) : lerp(s, hj, t);
        out.add(GuideLine(d, y, cx - torsoHalf, cx + torsoHalf));
      case LandmarkSpan.leftLeg:
      case LandmarkSpan.rightLeg:
        // Side photo: the person turned left, so their right side faces the camera.
        if (sideView && d.span == LandmarkSpan.leftLeg) continue;
        final left = d.span == LandmarkSpan.leftLeg;
        final hip = left ? lhip : rhip, knee = left ? lkn : rkn, ankle = left ? lan : ran;
        final (double t, bool lower) = switch (d.id.replaceAll(RegExp(r'_(left|right)$'), '')) {
          'leg_thigh_upper_circ' => (0.22, false),
          'leg_thigh_mid_circ' => (0.5, false),
          'leg_knee_circ' => (1.0, false),
          _ => (0.3, true), // calf
        };
        final ax = lower ? knee.x : hip.x, ay = lower ? knee.y : hip.y, bx = lower ? ankle.x : knee.x, by = lower ? ankle.y : knee.y;
        final x = lerp(ax, bx, t), y = lerp(ay, by, t);
        out.add(GuideLine(d, y, x - legHalf, x + legHalf));
      case LandmarkSpan.leftArm:
      case LandmarkSpan.rightArm:
        final left = d.span == LandmarkSpan.leftArm;
        final sh = g(left ? 11 : 12), el = g(left ? 13 : 14);
        if (sh == null || el == null || (sideView && left)) continue;
        final x = (sh.x + el.x) / 2, y = (sh.y + el.y) / 2;
        out.add(GuideLine(d, y, x - 0.04 * bodyH, x + 0.04 * bodyH));
    }
  }
  return out;
}

/// Draws thin yellow dashed lines with numbered labels onto a copy of [jpeg].
Uint8List annotateJpeg(Uint8List jpeg, List<Keypoint2D> kps, {required bool sideView}) {
  final src = img.bakeOrientation(img.decodeJpg(jpeg)!);
  final lines = guideLines(kps, sideView: sideView);
  final out = src.clone();
  final yellow = img.ColorRgb8(255, 214, 0);
  final shadow = img.ColorRgba8(0, 0, 0, 170);
  final thick = math.max(2, (out.height / 900).round());
  final dash = (out.height / 90).round(), gap = (out.height / 160).round();
  final font = out.height >= 1600 ? img.arial24 : img.arial14;
  for (final l in lines) {
    final y = l.y.round().clamp(0, out.height - 1);
    for (double x = l.x0; x < l.x1; x += dash + gap) {
      final xe = math.min(l.x1, x + dash);
      img.drawLine(out, x1: x.round(), y1: y, x2: xe.round(), y2: y, color: yellow, thickness: thick);
    }
    final text = '${l.def.number} ${l.def.label}';
    final tx = (l.x1 + 8).round().clamp(0, out.width - 1);
    final tw = text.length * (font == img.arial24 ? 13 : 8), th = font == img.arial24 ? 26 : 16;
    final x0 = tx + tw > out.width ? math.max(0, (l.x0 - 8 - tw).round()) : tx;
    img.fillRect(out, x1: x0 - 3, y1: y - th ~/ 2 - 2, x2: x0 + tw + 3, y2: y + th ~/ 2 + 2, color: shadow);
    img.drawString(out, text, font: font, x: x0, y: y - th ~/ 2, color: yellow);
  }
  return Uint8List.fromList(img.encodeJpg(out, quality: 90));
}
