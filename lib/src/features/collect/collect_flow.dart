import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../hardware/controllers/camera_capture_controller.dart';
import '../hardware/services/hardware_detection_service.dart';
import '../hardware/services/vio_motion_engine.dart';
import 'collect_capture_screen.dart';
import 'collect_export.dart';
import 'collect_models.dart';
import 'consent_screens.dart';
import 'measurement_entry_screen.dart';

const String kCollectAppVersion = 'collect-0.1.0';

enum _Step { welcome, eligibility, training, datasetChoice, dataset, contact, capture, measure, exporting, done }

/// Dataset-collection build: consent → contact → capture → tape table → export.
/// No vault, PIN or profiles: data is written unencrypted for sharing with Allele.
class CollectFlow extends StatefulWidget {
  const CollectFlow({super.key});

  @override
  State<CollectFlow> createState() => _CollectFlowState();
}

class _CollectFlowState extends State<CollectFlow> {
  _Step _step = _Step.welcome;
  late CollectRecord _record;
  late CollectCapture _capture;
  CameraCaptureController? _camera;
  String? _trainingText, _datasetText;
  File? _zip;
  String? _error;
  bool _adult = false, _isSelf = false;

  @override
  void initState() {
    super.initState();
    _reset();
    _loadTexts();
  }

  Future<void> _loadTexts() async {
    final a = await rootBundle.loadString('assets/legal/training_consent.md');
    final b = await rootBundle.loadString('assets/legal/dataset_trust_agreement.md');
    setState(() {
      _trainingText = a;
      _datasetText = b;
    });
  }

  void _reset() {
    _record = CollectRecord(CollectRecord.newParticipantId(), DateTime.now());
    _capture = CollectCapture();
    _zip = null;
    _error = null;
    _adult = false;
    _isSelf = false;
  }

  /// A fresh camera controller per capture attempt (created once, not per build).
  void _goCapture() {
    _camera?.dispose();
    _camera = CameraCaptureController(hardwareService: HardwareDetectionService(), vioEngine: VioMotionEngine());
    _step = _Step.capture;
  }

  Future<void> _export() async {
    setState(() => _step = _Step.exporting);
    try {
      _zip = await CollectExporter.export(_record, _capture,
          consentTexts: {'training_consent': _trainingText ?? '', 'dataset_trust_agreement': _datasetText ?? ''}, appVersion: kCollectAppVersion);
      setState(() => _step = _Step.done);
    } catch (e) {
      setState(() {
        _error = 'Export failed: $e';
        _step = _Step.measure;
      });
    }
  }

  String get _title => switch (_step) {
        _Step.welcome => 'Allele Collect',
        _Step.eligibility => 'Before you start',
        _Step.training => 'Training Data Consent',
        _Step.datasetChoice => 'Dataset Trust (optional)',
        _Step.dataset => 'Dataset Licence & Trust',
        _Step.contact => 'Your contact details',
        _Step.capture => 'Scan',
        _Step.measure => 'Tape measurements',
        _Step.exporting => 'Exporting',
        _Step.done => 'Done',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_title), automaticallyImplyLeading: false),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    final t = Theme.of(context).textTheme;
    switch (_step) {
      case _Step.welcome:
        return ListView(padding: const EdgeInsets.all(20), children: [
          Text('Help train Allele\'s body-measuring app', style: t.headlineSmall),
          const SizedBox(height: 12),
          const Text('You will:\n'
              '1. Read and sign the Training Data Consent (and optionally the Dataset Trust agreement).\n'
              '2. Take a front photo, a side photo and a 20-second turning video, with the phone on a tripod.\n'
              '3. Take tape measurements at the marked spots, and enter them.\n'
              '4. Export the folder and send it to Allele.\n\n'
              'Wear fitted underwear, tights or swimwear. You will need a tape measure, a helper if possible, and about 20 minutes.'),
          const SizedBox(height: 8),
          Text('Participant ID: ${_record.participantId}', style: t.bodySmall),
          const SizedBox(height: 20),
          FilledButton(onPressed: _trainingText == null ? null : () => setState(() => _step = _Step.eligibility), child: const Text('Start')),
        ]);
      case _Step.eligibility:
        return ListView(padding: const EdgeInsets.all(20), children: [
          CheckboxListTile(value: _adult, onChanged: (v) => setState(() => _adult = v ?? false), title: const Text('I am 18 or older.')),
          CheckboxListTile(
              value: _isSelf,
              onChanged: (v) => setState(() => _isSelf = v ?? false),
              title: const Text('I am the person who will be photographed and measured.')),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _adult && _isSelf
                ? () => setState(() {
                      _record.adultConfirmed = true;
                      _step = _Step.training;
                    })
                : null,
            child: const Text('Continue'),
          ),
          const SizedBox(height: 8),
          const Text('If you are under 18 you cannot take part. Thank you for your interest.'),
        ]);
      case _Step.training:
        return SignDocumentScreen(
          documentId: 'training_consent',
          title: 'Training Data Consent',
          text: _trainingText!,
          onSigned: (s) => setState(() {
            _record.trainingConsent = s;
            _record.contact.fullName = s.typedName;
            _step = _Step.datasetChoice;
          }),
          onDecline: () => setState(() {
            _reset();
            _step = _Step.welcome;
          }),
          declineLabel: 'I do not agree (exit)',
        );
      case _Step.datasetChoice:
        return ListView(padding: const EdgeInsets.all(20), children: [
          const Text('Would you also like to join the Allele Body Dataset Trust?\n\n'
              'If you join, your anonymised data can be licensed to others, and you get an equal share of the money the dataset earns, '
              'held in a trust that Allele manages for contributors. If you do not join, your data stays inside Allele.\n\n'
              'Either way you get the 10% discount.'),
          const SizedBox(height: 20),
          FilledButton(onPressed: () => setState(() => _step = _Step.dataset), child: const Text('Read the Dataset Trust agreement')),
          OutlinedButton(onPressed: () => setState(() => _step = _Step.contact), child: const Text('No thanks, continue')),
        ]);
      case _Step.dataset:
        return SignDocumentScreen(
          documentId: 'dataset_trust_agreement',
          title: 'Dataset Licence and Trust Agreement',
          text: _datasetText!,
          initialName: _record.contact.fullName,
          onSigned: (s) => setState(() {
            _record.datasetAgreement = s;
            _step = _Step.contact;
          }),
          onDecline: () => setState(() => _step = _Step.contact),
          declineLabel: 'Skip — do not join the Trust',
        );
      case _Step.contact:
        return ContactScreen(record: _record, onDone: () => setState(_goCapture));
      case _Step.capture:
        return CollectCaptureScreen(
          key: ValueKey(_capture),
          camera: _camera!,
          capture: _capture,
          onDone: () => setState(() => _step = _Step.measure),
        );
      case _Step.measure:
        return Column(children: [
          if (_error != null) MaterialBanner(content: Text(_error!), actions: [TextButton(onPressed: () => setState(() => _error = null), child: const Text('OK'))]),
          Expanded(
            child: MeasurementEntryScreen(
              record: _record,
              frontAnnotated: _capture.frontAnnotated,
              sideAnnotated: _capture.sideAnnotated,
              onExport: _export,
              onRetake: () => setState(() {
                _capture = CollectCapture();
                _goCapture();
              }),
            ),
          ),
        ]);
      case _Step.exporting:
        return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Saving…')]));
      case _Step.done:
        return ListView(padding: const EdgeInsets.all(20), children: [
          const Icon(Icons.check_circle, color: Colors.green, size: 64),
          const SizedBox(height: 12),
          Text('Thank you! Participant ${_record.participantId} is saved.', style: t.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          SelectableText('Saved to:\n${_zip?.path ?? ''}', textAlign: TextAlign.center),
          const SizedBox(height: 20),
          FilledButton.icon(
            icon: const Icon(Icons.share),
            label: const Text('Send to Allele (share the .zip)'),
            onPressed: _zip == null ? null : () => CollectExporter.share(_zip!, _record.participantId),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
              onPressed: () => setState(() {
                    _reset();
                    _step = _Step.welcome;
                  }),
              child: const Text('Start the next participant')),
        ]);
    }
  }

  @override
  void dispose() {
    _camera?.dispose();
    super.dispose();
  }
}
