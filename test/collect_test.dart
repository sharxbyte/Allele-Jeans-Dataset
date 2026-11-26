import 'dart:io';
import 'dart:typed_data';

import 'package:allele_collect/src/core/models/frame_observation.dart';
import 'package:allele_collect/src/features/collect/collect_models.dart';
import 'package:allele_collect/src/features/collect/consent_screens.dart';
import 'package:allele_collect/src/features/collect/landmark_overlay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Front-facing A-pose keypoints in a 1080×1920 portrait photo.
List<Keypoint2D> _frontPose() {
  Keypoint2D k(int i, double x, double y) => Keypoint2D(index: i, x: x, y: y, confidence: 0.95);
  return [
    k(0, 540, 330), // nose
    k(11, 650, 520), k(12, 430, 520), // shoulders (person's left on image right)
    k(13, 720, 760), k(14, 360, 760), // elbows
    k(15, 760, 980), k(16, 320, 980), // wrists
    k(23, 610, 1000), k(24, 470, 1000), // hips
    k(25, 620, 1380), k(26, 460, 1380), // knees
    k(27, 625, 1740), k(28, 455, 1740), // ankles
  ];
}

void main() {
  test('guide lines are ordered head to foot and within the image', () {
    final lines = guideLines(_frontPose(), sideView: false);
    double y(String id) => lines.firstWhere((l) => l.def.id == id).y;
    expect(y('allele_chest_circ'), lessThan(y('waist_natural_circ')));
    expect(y('waist_natural_circ'), lessThan(y('allele_navel_circ')));
    expect(y('allele_navel_circ'), lessThan(y('highhip_circ')));
    expect(y('highhip_circ'), lessThan(y('hip_circ')));
    expect(y('hip_circ'), lessThan(y('leg_thigh_upper_circ_left')));
    expect(y('leg_thigh_upper_circ_left'), lessThan(y('leg_knee_circ_left')));
    expect(y('leg_knee_circ_left'), lessThan(y('leg_calf_circ_left')));
    for (final l in lines) {
      expect(l.y, inInclusiveRange(0, 1920));
      expect(l.x1, greaterThan(l.x0));
    }
    // The left leg line sits over the person's left leg (image right).
    final thighL = lines.firstWhere((l) => l.def.id == 'leg_thigh_upper_circ_left');
    expect((thighL.x0 + thighL.x1) / 2, greaterThan(540));
  });

  test('side view (right side to camera) skips the hidden left limbs', () {
    final ids = guideLines(_frontPose(), sideView: true).map((l) => l.def.id).toSet();
    expect(ids, contains('hip_circ'));
    expect(ids, contains('leg_thigh_upper_circ_right'));
    expect(ids.any((i) => i.endsWith('_left')), isFalse);
  });

  test('annotated photo keeps its size and draws yellow', () {
    final src = img.Image(width: 1080, height: 1920)..clear(img.ColorRgb8(40, 40, 40));
    final out = img.decodeJpg(annotateJpeg(Uint8List.fromList(img.encodeJpg(src)), _frontPose(), sideView: false))!;
    expect(out.width, 1080);
    expect(out.height, 1920);
    int yellow = 0;
    for (final p in out) {
      if (p.r > 200 && p.g > 170 && p.b < 90) yellow++;
    }
    expect(yellow, greaterThan(500));
  });

  test('measurements CSV has every landmark and quotes text', () {
    final r = CollectRecord('PTEST01', DateTime(2026, 11, 26));
    r.rows.first
      ..tapeHeightCm = 125.0
      ..relaxedCm = 110.2
      ..snugCm = 108.6
      ..note = 'over "belly"';
    final lines = r.measurementsCsv().trim().split('\n');
    expect(lines.length, kLandmarks.length + 1);
    expect(lines[1], startsWith('1,allele_chest_circ,"Bust / chest",125.0,110.2,108.6,"over ""belly"""'));
  });

  test('participant ids are random and well formed', () {
    final ids = {for (int i = 0; i < 50; i++) CollectRecord.newParticipantId()};
    expect(ids.length, 50);
    expect(ids.every((s) => RegExp(r'^P[0-9A-F]{6}$').hasMatch(s)), isTrue);
  });

  test('consent documents: placeholders filled; drafts cannot be signed', () {
    final training = File('assets/legal/training_consent.md').readAsStringSync();
    expect(isUnfinishedLegalText(training), isFalse, reason: 'training consent must be final');
    expect(documentVersion(training), '0.1');
    final dataset = File('assets/legal/dataset_trust_agreement.md').readAsStringSync();
    // Stays true until the cost-deduction choice in section 5 is made.
    expect(isUnfinishedLegalText(dataset), dataset.contains('DECIDE BEFORE USE'));
    expect(isUnfinishedLegalText('Hello [CONTACT EMAIL]'), isTrue);
  });
}
