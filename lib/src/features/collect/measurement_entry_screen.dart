import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'collect_models.dart';

/// Guide photos with numbered yellow lines, then the tape table to fill in.
class MeasurementEntryScreen extends StatefulWidget {
  final CollectRecord record;
  final Uint8List? frontAnnotated, sideAnnotated;
  final VoidCallback onExport;
  final VoidCallback onRetake;
  const MeasurementEntryScreen(
      {super.key, required this.record, required this.frontAnnotated, required this.sideAnnotated, required this.onExport, required this.onRetake});

  @override
  State<MeasurementEntryScreen> createState() => _MeasurementEntryScreenState();
}

class _MeasurementEntryScreenState extends State<MeasurementEntryScreen> {
  bool _inches = true;
  final _form = GlobalKey<FormState>();
  int _formVersion = 0; // rebuilds fields when units change

  double get _toCm => _inches ? 2.54 : 1.0;
  String get _u => _inches ? 'in' : 'cm';

  String _show(double? cm) => cm == null ? '' : (cm / _toCm).toStringAsFixed(_inches ? 2 : 1);
  double? _parse(String? s) {
    final v = double.tryParse((s ?? '').trim().replaceAll(',', '.'));
    return v == null ? null : v * _toCm;
  }

  void _openImage(Uint8List bytes, String title) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
              appBar: AppBar(title: Text(title)),
              backgroundColor: Colors.black,
              body: InteractiveViewer(maxScale: 6, child: Center(child: Image.memory(bytes))),
            )));
  }

  Widget _thumb(Uint8List? b, String title) => Expanded(
        child: b == null
            ? const SizedBox(height: 120, child: Center(child: Text('No guide (pose not found)')))
            : GestureDetector(
                onTap: () => _openImage(b, title),
                child: Column(children: [ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(b, height: 260, fit: BoxFit.contain)), Text('$title — tap to zoom')]),
              ),
      );

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    _form.currentState!.save();
    final r = widget.record;
    final missing = [
      for (final row in r.rows)
        if (row.def.jeansCritical && row.def.id != 'allele_abdomen_max_circ' && (row.relaxedCm == null || row.snugCm == null || row.tapeHeightCm == null))
          '${row.def.number} ${row.def.label}',
    ];
    if (missing.isNotEmpty) {
      final go = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Some measurements are missing'),
          content: Text('These jeans measurements are incomplete:\n\n${missing.join('\n')}\n\nExport anyway?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Go back')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Export anyway')),
          ],
        ),
      );
      if (go != true) return;
    }
    widget.onExport();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.record;
    final t = Theme.of(context).textTheme;
    InputDecoration dec(String label) => InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder());
    String? num(String? v, {bool required = false}) {
      if ((v ?? '').trim().isEmpty) return required ? 'Required' : null;
      return double.tryParse(v!.trim().replaceAll(',', '.')) == null ? 'Number' : null;
    }

    return Form(
      key: _form,
      child: ListView(key: ValueKey(_formVersion), padding: const EdgeInsets.all(12), children: [
        Row(children: [_thumb(widget.frontAnnotated, 'Front'), const SizedBox(width: 8), _thumb(widget.sideAnnotated, 'Side')]),
        TextButton.icon(onPressed: widget.onRetake, icon: const Icon(Icons.replay), label: const Text('Retake photos and video')),
        const Card(
          child: ExpansionTile(
            title: Text('How to measure (read first)'),
            childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('• Yellow lines are approximate. Use each landmark description to find the exact spot.'),
              Text('• Stand as in the scan: relaxed, feet hip-width apart, arms hanging, breathing out normally.'),
              Text('• Keep the tape horizontal (level all the way round).'),
              Text('• RELAXED: the tape just touches the skin without pressing in. SNUG: pulled firm, as you would usually measure.'),
              Text('• TAPE HEIGHT: from the floor straight up to the tape, measured with a rigid ruler or a tape held vertical against a wall, barefoot.'),
              Text('• BODY HEIGHT: barefoot, back against a wall, a book flat on the head; mark the wall and measure floor to mark.'),
              Text('• Optional: put small coloured stickers on the right side at each landmark before scanning (tick "stickers used" below).'),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Text('Units', style: t.titleMedium),
          const SizedBox(width: 12),
          SegmentedButton<bool>(
            segments: const [ButtonSegment(value: true, label: Text('inches')), ButtonSegment(value: false, label: Text('cm'))],
            selected: {_inches},
            onSelectionChanged: (s) {
              _form.currentState!.save();
              setState(() {
                _inches = s.first;
                _formVersion++;
              });
            },
          ),
        ]),
        const SizedBox(height: 12),
        Text('Participant', style: t.titleMedium),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
              child: TextFormField(
                  initialValue: _show(r.heightCm),
                  decoration: dec('Body height ($_u) *'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) => num(v, required: true),
                  onSaved: (v) => r.heightCm = _parse(v))),
          const SizedBox(width: 8),
          Expanded(
              child: TextFormField(
                  initialValue: r.weightKg == null ? '' : (_inches ? (r.weightKg! / 0.45359237).toStringAsFixed(1) : r.weightKg!.toStringAsFixed(1)),
                  decoration: dec(_inches ? 'Weight (lb, optional)' : 'Weight (kg, optional)'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  validator: num,
                  onSaved: (v) {
                    final w = double.tryParse((v ?? '').trim());
                    r.weightKg = w == null ? null : (_inches ? w * 0.45359237 : w);
                  })),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextFormField(initialValue: r.sex, decoration: dec('Sex (optional)'), onSaved: (v) => r.sex = v!.trim())),
          const SizedBox(width: 8),
          Expanded(child: TextFormField(initialValue: r.measuredBy, decoration: dec('Measured by'), onSaved: (v) => r.measuredBy = v!.trim())),
        ]),
        StatefulBuilder(
          builder: (c, set) => CheckboxListTile(
            value: r.stickersUsed,
            onChanged: (v) => set(() => r.stickersUsed = v ?? false),
            title: const Text('Stickers used at the landmarks'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const SizedBox(height: 12),
        Text('Tape measurements ($_u)', style: t.titleMedium),
        const SizedBox(height: 6),
        for (final row in r.rows)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${row.def.number}. ${row.def.label}${row.def.jeansCritical ? '  ★' : ''}', style: t.titleSmall),
                Text(row.def.howTo, style: t.bodySmall),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                      child: TextFormField(
                          initialValue: _show(row.tapeHeightCm),
                          decoration: dec('Tape height'),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          validator: num,
                          onSaved: (v) => row.tapeHeightCm = _parse(v))),
                  const SizedBox(width: 6),
                  Expanded(
                      child: TextFormField(
                          initialValue: _show(row.relaxedCm),
                          decoration: dec('Relaxed'),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          validator: num,
                          onSaved: (v) => row.relaxedCm = _parse(v))),
                  const SizedBox(width: 6),
                  Expanded(
                      child: TextFormField(
                          initialValue: _show(row.snugCm),
                          decoration: dec('Snug'),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          validator: num,
                          onSaved: (v) => row.snugCm = _parse(v))),
                ]),
                const SizedBox(height: 6),
                TextFormField(initialValue: row.note, decoration: dec('Note (e.g. "over belly")'), onSaved: (v) => row.note = v!.trim()),
              ]),
            ),
          ),
        const SizedBox(height: 8),
        TextFormField(initialValue: r.tapeNotes, decoration: dec('General notes'), maxLines: 2, onSaved: (v) => r.tapeNotes = v!.trim()),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: _submit, icon: const Icon(Icons.save_alt), label: const Text('Export')),
        const SizedBox(height: 32),
      ]),
    );
  }
}
