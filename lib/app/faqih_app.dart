import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/i18n/app_locale.dart';
import '../core/i18n/translator.dart';
import '../core/theme/app_theme.dart';
import '../features/home/home_shell_screen.dart';

/// Root application widget wiring dark theme and reactive AR/EN localization.
class FaqihDownloaderApp extends StatelessWidget {
  const FaqihDownloaderApp({
    super.key,
    required this.translator,
  });

  final AppTranslator translator;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: translator,
      builder: (context, _) {
        return MaterialApp(
          title: translator.tr('app_title'),
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark,
          themeMode: ThemeMode.dark,
          locale: translator.locale,
          supportedLocales: AppLocale.supportedLocales,
          localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) {
            return Directionality(
              textDirection: translator.textDirection,
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: HomeShellScreen(translator: translator),
        );
      },
    );
  }
}
