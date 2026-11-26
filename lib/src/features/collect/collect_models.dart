import 'dart:math' as math;

/// Where a landmark line is drawn on the guide photos.
enum LandmarkSpan { torso, leftLeg, rightLeg, leftArm, rightArm }

/// A tape-measure site for the training dataset. Ids match the app's
/// measurement table where one exists, so scan and tape can be compared.
class LandmarkDef {
  final int number;
  final String id;
  final String label;
  final String howTo;
  final bool jeansCritical;
  final LandmarkSpan span;
  const LandmarkDef(this.number, this.id, this.label, this.howTo, {required this.span, this.jeansCritical = false});
}

const List<LandmarkDef> kLandmarks = [
  LandmarkDef(1, 'allele_chest_circ', 'Bust / chest',
      'Horizontal across the nipples, arms down.', span: LandmarkSpan.torso),
  LandmarkDef(2, 'allele_underbust_circ', 'Underbust',
      'Directly under the chest, at the fold under the breast or pectoral.', span: LandmarkSpan.torso),
  LandmarkDef(3, 'waist_natural_circ', 'Natural waist',
      'Bend sideways: the crease that forms at the side of the torso. If none forms, midway between the lowest rib and the top of the hip bone, at the side.',
      span: LandmarkSpan.torso, jeansCritical: true),
  LandmarkDef(4, 'allele_navel_circ', 'Belly at navel', 'Horizontal through the navel (belly button).',
      span: LandmarkSpan.torso, jeansCritical: true),
  LandmarkDef(5, 'allele_abdomen_max_circ', 'Belly, fullest',
      'Fullest part of the belly, if different from the navel. Leave blank if the same.', span: LandmarkSpan.torso, jeansCritical: true),
  LandmarkDef(6, 'highhip_circ', 'High hip',
      'Press in at the side to find the top edge of the hip bone; tape horizontal there (over the belly if it overhangs — note it).',
      span: LandmarkSpan.torso, jeansCritical: true),
  LandmarkDef(7, 'hip_circ', 'Seat / hip', 'Fullest part of the buttocks, seen from the side.',
      span: LandmarkSpan.torso, jeansCritical: true),
  LandmarkDef(8, 'leg_thigh_upper_circ_left', 'Upper thigh (L)',
      'Just below where the buttock meets the back of the thigh (gluteal fold). Left leg.', span: LandmarkSpan.leftLeg, jeansCritical: true),
  LandmarkDef(9, 'leg_thigh_upper_circ_right', 'Upper thigh (R)', 'Same as above, right leg.', span: LandmarkSpan.rightLeg, jeansCritical: true),
  LandmarkDef(10, 'leg_thigh_mid_circ_left', 'Mid-thigh (L)', 'Halfway between crotch and knee. Left leg.',
      span: LandmarkSpan.leftLeg, jeansCritical: true),
  LandmarkDef(11, 'leg_thigh_mid_circ_right', 'Mid-thigh (R)', 'Halfway between crotch and knee. Right leg.',
      span: LandmarkSpan.rightLeg, jeansCritical: true),
  LandmarkDef(12, 'leg_knee_circ_left', 'Knee (L)', 'Centre of the kneecap, leg straight.', span: LandmarkSpan.leftLeg, jeansCritical: true),
  LandmarkDef(13, 'leg_knee_circ_right', 'Knee (R)', 'Centre of the kneecap, leg straight.', span: LandmarkSpan.rightLeg, jeansCritical: true),
  LandmarkDef(14, 'leg_calf_circ_left', 'Calf (L)', 'Fullest part of the calf.', span: LandmarkSpan.leftLeg),
  LandmarkDef(15, 'leg_calf_circ_right', 'Calf (R)', 'Fullest part of the calf.', span: LandmarkSpan.rightLeg),
  LandmarkDef(16, 'allele_bicep_circ_left', 'Bicep (L)', 'Midway from shoulder tip to elbow, arm relaxed and hanging.',
      span: LandmarkSpan.leftArm),
  LandmarkDef(17, 'allele_bicep_circ_right', 'Bicep (R)', 'Midway from shoulder tip to elbow, arm relaxed and hanging.',
      span: LandmarkSpan.rightArm),
];

/// One tape-measure row. All lengths stored in centimetres.
class TapeRow {
  final LandmarkDef def;
  double? tapeHeightCm; // floor to tape, standing in the scan position
  double? relaxedCm; // tape just touching the skin
  double? snugCm; // tape pulled snug, as usually measured
  String note = '';
  TapeRow(this.def);

  Map<String, dynamic> toJson() => {
        'number': def.number,
        'id': def.id,
        'label': def.label,
        'tape_height_cm': tapeHeightCm,
        'relaxed_cm': relaxedCm,
        'snug_cm': snugCm,
        'note': note,
      };
}

class ContactInfo {
  String fullName = '';
  String email = '';
  String phone = '';
  String mailingAddress = '';
  String beneficiaryName = '';
  String beneficiaryContact = '';

  Map<String, dynamic> toJson() => {
        'full_name': fullName,
        'email': email,
        'phone': phone,
        'mailing_address': mailingAddress,
        'beneficiary_name': beneficiaryName,
        'beneficiary_contact': beneficiaryContact,
      };
}

class SignedConsent {
  final String documentId; // e.g. 'training_consent'
  final String version;
  final String textSha256;
  final String typedName;
  final DateTime signedAt;
  final List<int> signaturePng;
  const SignedConsent(this.documentId, this.version, this.textSha256, this.typedName, this.signedAt, this.signaturePng);

  Map<String, dynamic> toJson() => {
        'document': documentId,
        'version': version,
        'text_sha256': textSha256,
        'typed_name': typedName,
        'signed_at': signedAt.toIso8601String(),
        'signed_at_utc': signedAt.toUtc().toIso8601String(),
        'electronic_signature': true,
        'signature_image': 'signature_$documentId.png',
      };
}

/// Everything collected from one participant.
class CollectRecord {
  final String participantId;
  final DateTime startedAt;
  bool adultConfirmed = false;
  SignedConsent? trainingConsent;
  SignedConsent? datasetAgreement; // optional
  final ContactInfo contact = ContactInfo();

  double? heightCm;
  double? weightKg;
  String sex = ''; // optional, free text
  String measuredBy = '';
  String tapeNotes = '';
  bool stickersUsed = false;
  final List<TapeRow> rows = [for (final d in kLandmarks) TapeRow(d)];

  CollectRecord(this.participantId, this.startedAt);

  static String newParticipantId() {
    final r = math.Random.secure();
    return 'P${List.generate(6, (_) => r.nextInt(16).toRadixString(16)).join().toUpperCase()}';
  }

  /// CSV in the dataset layout (tools/refine reads it).
  String measurementsCsv() {
    final b = StringBuffer('number,id,label,tape_height_cm,relaxed_cm,snug_cm,note\n');
    String f(double? v) => v == null ? '' : v.toStringAsFixed(1);
    String q(String s) => '"${s.replaceAll('"', '""')}"';
    for (final r in rows) {
      b.writeln('${r.def.number},${r.def.id},${q(r.def.label)},${f(r.tapeHeightCm)},${f(r.relaxedCm)},${f(r.snugCm)},${q(r.note)}');
    }
    return b.toString();
  }
}
