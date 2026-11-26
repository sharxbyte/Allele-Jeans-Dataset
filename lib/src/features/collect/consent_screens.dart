import 'dart:convert';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter/material.dart';

import 'collect_models.dart';
import 'legal_text_view.dart';
import 'signature_pad.dart';

/// Documents still containing drafting markers must never be signed.
bool isUnfinishedLegalText(String text) => text.contains('DECIDE BEFORE USE') || RegExp(r'\[[A-Z][A-Z ]+\]').hasMatch(text);

String documentVersion(String text) => RegExp(r'Version ([0-9.]+)').firstMatch(text)?.group(1) ?? 'unknown';

/// Shows a document; the participant must scroll to the end, tick agreement,
/// type their full name and sign before [onSigned] is called.
class SignDocumentScreen extends StatefulWidget {
  final String documentId;
  final String title;
  final String text;
  final String initialName;
  final void Function(SignedConsent) onSigned;
  final VoidCallback? onDecline;
  final String declineLabel;
  const SignDocumentScreen({
    super.key,
    required this.documentId,
    required this.title,
    required this.text,
    required this.onSigned,
    this.initialName = '',
    this.onDecline,
    this.declineLabel = 'I do not agree',
  });

  @override
  State<SignDocumentScreen> createState() => _SignDocumentScreenState();
}

class _SignDocumentScreenState extends State<SignDocumentScreen> {
  final _scroll = ScrollController();
  final _sig = SignatureController();
  late final _name = TextEditingController(text: widget.initialName);
  bool _readToEnd = false, _agree = false, _busy = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_readToEnd && _scroll.position.pixels >= _scroll.position.maxScrollExtent - 40) setState(() => _readToEnd = true);
    });
    _sig.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _scroll.dispose();
    _sig.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _sign() async {
    setState(() => _busy = true);
    final png = await _sig.toPng();
    widget.onSigned(SignedConsent(widget.documentId, documentVersion(widget.text), hash.sha256.convert(utf8.encode(widget.text)).toString(),
        _name.text.trim(), DateTime.now(), png));
  }

  @override
  Widget build(BuildContext context) {
    if (isUnfinishedLegalText(widget.text)) {
      return const Center(
          child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('This agreement is still a draft (it contains unfinished sections) and cannot be signed. '
                  'Please contact Allele for the final version.',
                  textAlign: TextAlign.center)));
    }
    final ok = _readToEnd && _agree && _name.text.trim().split(RegExp(r'\s+')).length >= 2 && !_sig.isEmpty && !_busy;
    return Column(children: [
      Expanded(
        child: Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _scroll,
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              LegalTextView(widget.text),
              const Divider(height: 32),
              CheckboxListTile(
                value: _agree,
                onChanged: _readToEnd ? (v) => setState(() => _agree = v ?? false) : null,
                title: Text('I have read and agree to the ${widget.title}, and I agree to sign it electronically.'),
                subtitle: _readToEnd ? null : const Text('Scroll to the end to continue.'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Full legal name'),
                textCapitalization: TextCapitalization.words,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              Row(children: [
                const Expanded(child: Text('Sign below with your finger')),
                TextButton(onPressed: _sig.clear, child: const Text('Clear')),
              ]),
              SignaturePad(controller: _sig),
              const SizedBox(height: 8),
              Text('Date: ${DateTime.now().toLocal().toString().substring(0, 10)}'),
              const SizedBox(height: 16),
              FilledButton(onPressed: ok ? _sign : null, child: const Text('Sign and continue')),
              if (widget.onDecline != null) TextButton(onPressed: widget.onDecline, child: Text(widget.declineLabel)),
              const SizedBox(height: 24),
            ]),
          ),
        ),
      ),
    ]);
  }
}

/// Contact details (needed for the discount and, for trust members, payments).
class ContactScreen extends StatefulWidget {
  final CollectRecord record;
  final VoidCallback onDone;
  const ContactScreen({super.key, required this.record, required this.onDone});

  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> {
  final _form = GlobalKey<FormState>();

  @override
  Widget build(BuildContext context) {
    final c = widget.record.contact;
    final trust = widget.record.datasetAgreement != null;
    return Form(
      key: _form,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Text(
            trust
                ? 'Allele uses these details to send your discount and any Dataset Trust payments. They are stored separately and never become part of the dataset.'
                : 'Allele uses these details to send your discount and to contact you about your data. They are stored separately and never become part of the dataset.',
            style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 12),
        TextFormField(
          initialValue: c.fullName,
          decoration: const InputDecoration(labelText: 'Full name *'),
          onSaved: (v) => c.fullName = v!.trim(),
          validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
        ),
        TextFormField(
          initialValue: c.email,
          decoration: const InputDecoration(labelText: 'Email *'),
          keyboardType: TextInputType.emailAddress,
          onSaved: (v) => c.email = v!.trim(),
          validator: (v) => (v == null || !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim())) ? 'Enter a valid email' : null,
        ),
        TextFormField(
          initialValue: c.phone,
          decoration: const InputDecoration(labelText: 'Phone (optional)'),
          keyboardType: TextInputType.phone,
          onSaved: (v) => c.phone = v!.trim(),
        ),
        TextFormField(
          initialValue: c.mailingAddress,
          decoration: InputDecoration(labelText: trust ? 'Mailing address (recommended for payments)' : 'Mailing address (optional)'),
          maxLines: 2,
          onSaved: (v) => c.mailingAddress = v!.trim(),
        ),
        if (trust) ...[
          const SizedBox(height: 16),
          Text('Beneficiary (optional)', style: Theme.of(context).textTheme.titleMedium),
          const Text('The person who receives your Dataset Trust share after your death. If you leave this blank, it goes to your estate.'),
          TextFormField(initialValue: c.beneficiaryName, decoration: const InputDecoration(labelText: 'Beneficiary full name'), onSaved: (v) => c.beneficiaryName = v!.trim()),
          TextFormField(
              initialValue: c.beneficiaryContact,
              decoration: const InputDecoration(labelText: 'Beneficiary email or phone'),
              onSaved: (v) => c.beneficiaryContact = v!.trim()),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () {
            if (_form.currentState!.validate()) {
              _form.currentState!.save();
              widget.onDone();
            }
          },
          child: const Text('Continue'),
        ),
      ]),
    );
  }
}
