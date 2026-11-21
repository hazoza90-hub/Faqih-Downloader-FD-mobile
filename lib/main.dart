import 'package:flutter/material.dart';

import 'app/faqih_app.dart';
import 'core/config/settings_repository.dart';
import 'core/i18n/translator.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settingsRepository = await SettingsRepository.create();
  final settings = settingsRepository.load();
  final translator = AppTranslator(
    initialLanguage: settings.language,
    repository: settingsRepository,
  );
  runApp(FaqihDownloaderApp(translator: translator));
}
