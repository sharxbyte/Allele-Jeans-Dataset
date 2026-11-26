import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'collect_models.dart';

/// Raw capture held until export.
class CollectCapture {
  Uint8List? frontJpeg, sideJpeg;
  Uint8List? frontAnnotated, sideAnnotated;
  List<List<num>>? frontKeypoints, sideKeypoints; // [index, x, y, confidence] in photo pixels
  List<double>? frontGravity, sideGravity;
  String? videoPath;
  List<(int, List<double>)> videoGravity = const [];
  DateTime? videoStartedAt;
  Map<String, dynamic>? lens;
  String deviceModel = '';
  String platform = Platform.operatingSystem;
}

/// Writes one participant folder (unencrypted by design: this build is for
/// consenting dataset contributors) and zips it for sharing.
///
/// Layout (read by tools/refine):
///   PARTICIPANT_ID/meta.json, measurements.csv, capture.json, front.jpg, side.jpg,
///   front_annotated.jpg, side_annotated.jpg, turn.mp4,
///   consent/*.json|png|md, contact/contact.json (kept apart from the dataset)
class CollectExporter {
  static Future<Directory> baseDir() async {
    final root = Platform.isAndroid ? (await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory()) : await getApplicationDocumentsDirectory();
    final d = Directory('${root.path}/AlleleCollect');
    await d.create(recursive: true);
    return d;
  }

  static Future<File> export(CollectRecord r, CollectCapture c, {required Map<String, String> consentTexts, required String appVersion}) async {
    final base = await baseDir();
    final dir = Directory('${base.path}/${r.participantId}');
    if (await dir.exists()) await dir.delete(recursive: true);
    await Directory('${dir.path}/consent').create(recursive: true);
    await Directory('${dir.path}/contact').create(recursive: true);
    const enc = JsonEncoder.withIndent('  ');

    Future<void> bytes(String name, List<int>? b) async {
      if (b != null) await File('${dir.path}/$name').writeAsBytes(b, flush: true);
    }

    Future<void> text(String name, String s) => File('${dir.path}/$name').writeAsString(s, flush: true);

    await bytes('front.jpg', c.frontJpeg);
    await bytes('side.jpg', c.sideJpeg);
    await bytes('front_annotated.jpg', c.frontAnnotated);
    await bytes('side_annotated.jpg', c.sideAnnotated);
    if (c.videoPath != null && await File(c.videoPath!).exists()) {
      await File(c.videoPath!).copy('${dir.path}/turn.mp4');
    }
    await text('measurements.csv', r.measurementsCsv());
    await text(
        'meta.json',
        enc.convert({
          'schema': 'allele_collect_v1',
          'participant_id': r.participantId,
          'started_at': r.startedAt.toIso8601String(),
          'exported_at': DateTime.now().toIso8601String(),
          'app_version': appVersion,
          'height_cm': r.heightCm,
          'weight_kg': r.weightKg,
          'sex': r.sex,
          'measured_by': r.measuredBy,
          'tape_notes': r.tapeNotes,
          'stickers_used': r.stickersUsed,
          'adult_confirmed': r.adultConfirmed,
          'dataset_trust_member': r.datasetAgreement != null,
          'units': {'lengths': 'cm', 'weight': 'kg'},
          'rows': [for (final row in r.rows) row.toJson()],
        }));
    await text(
        'capture.json',
        enc.convert({
          'device_model': c.deviceModel,
          'platform': c.platform,
          'lens': c.lens,
          'front': {'gravity': c.frontGravity, 'keypoints': c.frontKeypoints},
          'side': {'gravity': c.sideGravity, 'keypoints': c.sideKeypoints},
          'turn': {
            'video': c.videoPath == null ? null : 'turn.mp4',
            'started_at': c.videoStartedAt?.toIso8601String(),
            'gravity_log': [for (final g in c.videoGravity) {'ms': g.$1, 'g': g.$2}],
          },
        }));
    for (final s in [r.trainingConsent, r.datasetAgreement]) {
      if (s == null) continue;
      await text('consent/${s.documentId}.json', enc.convert(s.toJson()));
      await bytes('consent/signature_${s.documentId}.png', s.signaturePng);
      await text('consent/${s.documentId}.md', consentTexts[s.documentId] ?? '');
    }
    await text('contact/contact.json', enc.convert(r.contact.toJson()));

    final zipPath = '${base.path}/${r.participantId}.zip';
    final zf = File(zipPath);
    if (await zf.exists()) await zf.delete();
    final encoder = ZipFileEncoder();
    encoder.create(zipPath, level: ZipFileEncoder.STORE); // video/JPEG don't compress
    await encoder.addDirectory(dir, includeDirName: true);
    await encoder.close();
    return zf;
  }

  static Future<void> share(File zip, String participantId) async {
    await SharePlus.instance.share(ShareParams(
      files: [XFile(zip.path, mimeType: 'application/zip')],
      subject: 'Allele dataset contribution $participantId',
      text: 'Allele dataset contribution $participantId',
    ));
  }
}
