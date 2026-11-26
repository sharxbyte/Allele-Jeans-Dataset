import 'package:flutter/material.dart';

/// Minimal Markdown renderer for the consent documents: #/## headings,
/// "- " bullets and **bold** spans. Keeps the app free of extra packages.
class LegalTextView extends StatelessWidget {
  final String markdown;
  const LegalTextView(this.markdown, {super.key});

  static List<TextSpan> _spans(String line, TextStyle base) {
    final parts = line.split('**');
    return [
      for (int i = 0; i < parts.length; i++)
        TextSpan(text: parts[i], style: i.isOdd ? base.copyWith(fontWeight: FontWeight.bold) : base),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final body = t.bodyMedium!;
    final children = <Widget>[];
    for (final raw in markdown.split('\n')) {
      final line = raw.trimRight();
      if (line.isEmpty) {
        children.add(const SizedBox(height: 8));
      } else if (line.startsWith('# ')) {
        children.add(Text(line.substring(2), style: t.titleLarge));
      } else if (line.startsWith('## ')) {
        children.add(Padding(padding: const EdgeInsets.only(top: 8), child: Text(line.substring(3), style: t.titleMedium)));
      } else if (line.startsWith('- ')) {
        children.add(Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('•  '),
            Expanded(child: Text.rich(TextSpan(children: _spans(line.substring(2), body)))),
          ]),
        ));
      } else {
        children.add(Text.rich(TextSpan(children: _spans(line, body))));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}
