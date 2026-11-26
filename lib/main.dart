import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/features/collect/collect_flow.dart';

/// Entry point of the dataset-collection build ("Allele Collect").
///   Android: flutter build apk --flavor collect -t lib/main_collect.dart
///   iOS (on a Mac / cloud Mac): flutter build ipa -t lib/main_collect.dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(MaterialApp(
    title: 'Allele Collect',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: const Color(0xFF1D2A52), useMaterial3: true),
    home: const CollectFlow(),
  ));
}
