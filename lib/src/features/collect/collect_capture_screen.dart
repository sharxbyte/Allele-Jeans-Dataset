import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../../core/failures/pipeline_failure.dart';
import '../../core/models/capture_session.dart';
import '../../core/models/frame_observation.dart';
import '../hardware/controllers/camera_capture_controller.dart';
import '../photogrammetry/perception/image_utils.dart';
import '../photogrammetry/perception/pose_keypoint_service.dart';
import 'collect_export.dart';
import 'landmark_overlay.dart';

enum _Stage { front, side, turn, processing }

/// Front photo, side photo, then a recorded 360° turn (video kept for export).
class CollectCaptureScreen extends StatefulWidget {
  final CameraCaptureController camera;
  final CollectCapture capture;
  final VoidCallback onDone;
  const CollectCaptureScreen({super.key, required this.camera, required this.capture, required this.onDone});

  @override
  State<CollectCaptureScreen> createState() => _CollectCaptureScreenState();
}

class _CollectCaptureScreenState extends State<CollectCaptureScreen> {
  final _live = PoseKeypointService(mode: PoseDetectionMode.stream);
  final _still = PoseKeypointService();
  final _tts = FlutterTts();
  _Stage _stage = _Stage.front;
  DateTime? _readySince;
  DateTime _stageStarted = DateTime.now();
  int? _countdown;
  bool _busy = false, _turning = false;
  int _turnSeconds = 0;
  String? _error;
  String _lastSaid = '';
  DateTime _lastSaidAt = DateTime.fromMillisecondsSinceEpoch(0);

  CameraCaptureController get _cam => widget.camera;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await _live.initialize();
      await _still.initialize();
      await _cam.initialize();
      if (_cam.captureState == CaptureState.error) {
        setState(() => _error = _cam.statusMessage);
        return;
      }
      widget.capture.lens = _cam.lensInfoJson();
      widget.capture.deviceModel = _cam.hardwareService.profile?.model ?? '';
      _cam.addListener(_onGuidance);
      await _cam.startGuidance(_live, GuidanceTarget.front);
      _say('Stand the phone on a tripod at about hip height, then step back until your whole body is in view. '
          'Face the phone with your arms out like the letter A, hands clear of your hips, feet hip-width apart.',
          force: true);
      if (mounted) setState(() => _stageStarted = DateTime.now());
    } on PipelineFailure catch (e) {
      setState(() => _error = e.userMessage);
    }
  }

  Future<void> _say(String text, {bool force = false}) async {
    final now = DateTime.now();
    if (!force && (text == _lastSaid || now.difference(_lastSaidAt).inMilliseconds < 3500)) return;
    _lastSaid = text;
    _lastSaidAt = now;
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {}
  }

  void _onGuidance() {
    if (!mounted || _busy || _stage == _Stage.turn || _stage == _Stage.processing) return;
    final g = _cam.guidance;
    if (g.prompts.isNotEmpty) _say(g.prompts.first);
    if (g.ready) {
      _readySince ??= DateTime.now();
      if (_countdown == null && DateTime.now().difference(_readySince!).inMilliseconds > 1500) _startCountdown();
    } else {
      _readySince = null;
    }
    setState(() {});
  }

  void _startCountdown() {
    _countdown = 3;
    _say('Hold still. 3, 2, 1.', force: true);
    Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _countdown = (_countdown ?? 1) - 1);
      if ((_countdown ?? 0) <= 0) {
        t.cancel();
        _countdown = null;
        _captureNow();
      }
    });
  }

  Future<void> _captureNow() async {
    if (_busy) return;
    _busy = true;
    final cap = widget.capture;
    try {
      HapticFeedback.mediumImpact();
      if (_stage == _Stage.front) {
        await _cam.lockForCapture();
        _cam.rememberFrontShoulderWidth();
        final f = await _cam.captureBurst(CapturedMediaKind.frontStill);
        cap.frontJpeg = await f.file.readAsBytes();
        cap.frontGravity = f.gravity;
        setState(() => _stage = _Stage.side);
        _say('Turn a quarter turn to your left, and keep your arms out like an A.', force: true);
        await _cam.startGuidance(_live, GuidanceTarget.side);
      } else if (_stage == _Stage.side) {
        final f = await _cam.captureBurst(CapturedMediaKind.sideStill);
        cap.sideJpeg = await f.file.readAsBytes();
        cap.sideGravity = f.gravity;
        setState(() => _stage = _Stage.turn);
        await _turn();
      }
      _readySince = null;
      _stageStarted = DateTime.now();
    } on PipelineFailure catch (e) {
      setState(() => _error = e.userMessage);
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _turn() async {
    _say('Good. Now turn back to face the phone.', force: true);
    await _cam.startGuidance(_live, GuidanceTarget.front);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    DateTime? facing;
    while (mounted && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final g = _cam.guidance;
      if (g.personVisible && !g.prompts.contains('Face the phone')) {
        facing ??= DateTime.now();
        if (DateTime.now().difference(facing).inMilliseconds >= 1000) break;
      } else {
        facing = null;
      }
    }
    await _cam.stopGuidance();
    _say('Now turn slowly to your left in one full circle until you face the phone again, about twenty seconds. '
        'Keep your arms out like an A the whole way round. I will tell you when to stop.',
        force: true);
    await Future<void>.delayed(const Duration(seconds: 6));
    setState(() => _turning = true);
    widget.capture.videoStartedAt = DateTime.now();
    const cues = {6: 'Keep turning slowly.', 11: 'About halfway. Keep going.', 16: 'Almost there.'};
    final spoken = <int>{};
    final (video, gLog) = await _cam.recordVideoKeep(onTick: (e) {
      if (!mounted) return;
      final s = e.inSeconds;
      setState(() => _turnSeconds = s);
      final cue = cues[s];
      if (cue != null && spoken.add(s)) _say(cue, force: true);
    });
    setState(() {
      _turning = false;
      _stage = _Stage.processing;
    });
    await _cam.unlockAfterCapture();
    widget.capture.videoPath = video.path;
    widget.capture.videoGravity = gLog;
    for (int i = 0; i < 2; i++) {
      HapticFeedback.heavyImpact();
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _say('Stop. All done! You can stop turning. Next, take the tape measurements.', force: true);
    await _annotate();
    widget.onDone();
  }

  /// Pose on the stills, then the yellow guide lines.
  Future<void> _annotate() async {
    final cap = widget.capture;
    for (final front in [true, false]) {
      final jpeg = front ? cap.frontJpeg : cap.sideJpeg;
      if (jpeg == null) continue;
      try {
        final rgb = await compute(decodeJpegUpright, jpeg);
        final kps = await _still.detectRgb(rgb);
        final list = [for (final k in kps) <num>[k.index, k.x, k.y, k.confidence]];
        final annotated = await compute(_annotateIsolate, (jpeg, kps, !front));
        if (front) {
          cap.frontKeypoints = list;
          cap.frontAnnotated = annotated;
        } else {
          cap.sideKeypoints = list;
          cap.sideAnnotated = annotated;
        }
      } catch (e) {
        debugPrint('[Collect] annotation failed: $e');
      }
    }
  }

  @override
  void dispose() {
    _cam.removeListener(_onGuidance);
    _cam.stopGuidance();
    _live.dispose();
    _still.dispose();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)));
    }
    if (_stage == _Stage.processing) {
      return const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(),
        SizedBox(height: 12),
        Text('Preparing the measurement guide…'),
      ]));
    }
    final c = _cam.activeCameraController;
    if (c == null || !c.value.isInitialized) return const Center(child: CircularProgressIndicator());
    final g = _cam.guidance;
    final waited = DateTime.now().difference(_stageStarted).inSeconds > 8;
    final title = switch (_stage) {
      _Stage.front => 'Step 1 of 3 — Front photo',
      _Stage.side => 'Step 2 of 3 — Side photo',
      _ => 'Step 3 of 3 — Turn slowly',
    };
    return Stack(children: [
      Center(
        child: AspectRatio(
          aspectRatio: 1 / c.value.aspectRatio,
          child: Stack(fit: StackFit.expand, children: [CameraPreview(c), CustomPaint(painter: _SkeletonPainter(g))]),
        ),
      ),
      Positioned(
        top: 12,
        left: 12,
        right: 12,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(12)),
          child: Column(children: [
            Text(title, style: const TextStyle(color: Color(0xFFFFD600), fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              _turning ? 'Recording — keep turning slowly to your left ($_turnSeconds s of 22 s)' : (g.prompts.isEmpty ? '' : g.prompts.first),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ]),
        ),
      ),
      if (_countdown != null) Center(child: Text('$_countdown', style: const TextStyle(color: Colors.white, fontSize: 96, fontWeight: FontWeight.bold))),
      Positioned(
        bottom: 24,
        left: 20,
        right: 20,
        child: Center(
          child: _turning
              ? ElevatedButton.icon(icon: const Icon(Icons.stop), label: const Text('Stop — I turned all the way round'), onPressed: _cam.requestStopTurntable)
              : (waited && !_busy && _stage != _Stage.turn)
                  ? ElevatedButton.icon(icon: const Icon(Icons.camera), label: const Text('Capture anyway'), onPressed: _captureNow)
                  : const SizedBox.shrink(),
        ),
      ),
    ]);
  }
}

Uint8List _annotateIsolate((Uint8List, List<Keypoint2D>, bool) a) => annotateJpeg(a.$1, a.$2, sideView: a.$3);

class _SkeletonPainter extends CustomPainter {
  final GuidanceState g;
  _SkeletonPainter(this.g);
  static const _bones = [
    [11, 12], [11, 13], [13, 15], [12, 14], [14, 16], [11, 23], [12, 24], [23, 24], [23, 25], [25, 27], [24, 26], [26, 28],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final colour = g.ready ? Colors.greenAccent : (g.personVisible ? Colors.white : Colors.redAccent);
    final guide = Paint()
      ..color = colour.withValues(alpha: 0.8)
      ..strokeWidth = 2;
    canvas.drawLine(Offset(size.width * 0.2, size.height * 0.05), Offset(size.width * 0.8, size.height * 0.05), guide);
    canvas.drawLine(Offset(size.width * 0.2, size.height * 0.95), Offset(size.width * 0.8, size.height * 0.95), guide);
    if (g.keypoints.isEmpty) return;
    final sx = size.width / g.previewSize.width, sy = size.height / g.previewSize.height;
    final pts = {for (final k in g.keypoints) if (k.confidence > 0.4) k.index: Offset(k.x * sx, k.y * sy)};
    final bone = Paint()
      ..color = colour
      ..strokeWidth = 4;
    for (final b in _bones) {
      final a = pts[b[0]], c = pts[b[1]];
      if (a != null && c != null) canvas.drawLine(a, c, bone);
    }
  }

  @override
  bool shouldRepaint(covariant _SkeletonPainter old) => true;
}
