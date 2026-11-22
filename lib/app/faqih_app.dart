import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/i18n/app_locale.dart';
import '../core/i18n/translator.dart';
import '../core/theme/app_theme.dart';
import '../features/home/home_shell_screen.dart';
import 'app_controller.dart';

/// Root application widget wiring dynamic AR/EN localization, dark/light themes, and navigation.
class FaqihDownloaderApp extends StatelessWidget {
  const FaqihDownloaderApp({
    super.key,
    required this.translator,
    this.controller,
  });

  final AppTranslator translator;
  final AppController? controller;

  @override
  Widget build(BuildContext context) {
    final Listenable listenable = controller == null
        ? translator
        : Listenable.merge(<Listenable>[translator, controller!]);

    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) {
        final mode = controller?.themeMode ?? ThemeMode.dark;
        return MaterialApp(
          title: translator.tr('app_title'),
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: mode,
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
          home: HomeShellScreen(
            translator: translator,
            controller: controller,
          ),
        );
      },
    );
  }
}
