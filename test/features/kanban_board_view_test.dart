import 'dart:io';

import 'package:faqih_downloader_mobile/app/faqih_app.dart';
import 'package:faqih_downloader_mobile/core/config/app_settings.dart';
import 'package:faqih_downloader_mobile/core/i18n/strings_ar.dart';
import 'package:faqih_downloader_mobile/core/i18n/strings_en.dart';
import 'package:faqih_downloader_mobile/core/i18n/translator.dart';
import 'package:faqih_downloader_mobile/features/home/kanban_board_view.dart';
import 'package:faqih_downloader_mobile/features/settings/settings_sniffer_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('wide viewport shows 3-column Kanban board simultaneously and toggles to Tabs mode', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final translator = AppTranslator(initialLanguage: 'en');
    await tester.pumpWidget(FaqihDownloaderApp(translator: translator));
    await tester.pumpAndSettle();

    expect(find.byType(KanbanBoardView), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byKey(const Key('tab_staged')), findsOneWidget);
    expect(find.byKey(const Key('tab_active')), findsOneWidget);
    expect(find.byKey(const Key('tab_vault')), findsOneWidget);

    // Brand icon uses AssetImage rather than text 'FD':
    expect(find.byKey(const Key('app_brand_icon')), findsOneWidget);
    expect(find.text('FD'), findsNothing);

    // Toggle layout mode Kanban <-> Classic Tabs:
    await tester.tap(find.byKey(const Key('layout_mode_toggle_button')));
    await tester.pumpAndSettle();
    expect(find.byType(KanbanBoardView), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.tap(find.byKey(const Key('layout_mode_toggle_button')));
    await tester.pumpAndSettle();
    expect(find.byType(KanbanBoardView), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('portrait viewport renders peeking PageView with viewportFraction 0.88 and counter jump bar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final translator = AppTranslator(initialLanguage: 'en');
    await tester.pumpWidget(FaqihDownloaderApp(translator: translator));
    await tester.pumpAndSettle();

    final pageViewFinder = find.byKey(const Key('kanban_portrait_pageview'));
    expect(pageViewFinder, findsOneWidget);
    final pv = tester.widget<PageView>(pageViewFinder);
    expect(pv.controller?.viewportFraction, closeTo(0.88, 0.001));

    await tester.tap(find.byKey(const Key('tab_vault')));
    await tester.pumpAndSettle();
    expect(pv.controller?.page?.round(), 2);
  });

  test('original app_icon.png, Android mipmaps, i18n parity, and AppSettings round-trip', () {
    final assetIcon = File('assets/images/app_icon.png');
    expect(assetIcon.existsSync(), isTrue);
    expect(assetIcon.lengthSync(), greaterThan(50000));

    for (final density in const <String>['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
      for (final name in const <String>['ic_launcher.png', 'ic_launcher_round.png']) {
        final f = File('android/app/src/main/res/mipmap-$density/$name');
        expect(f.existsSync(), isTrue, reason: '${f.path} must exist');
        final bytes = f.readAsBytesSync();
        expect(bytes.take(4).toList(), <int>[0x89, 0x50, 0x4E, 0x47]);
      }
    }

    expect(stringsAr.keys.toSet(), equals(stringsEn.keys.toSet()));

    const s = AppSettings(floatingCaptureEnabled: true, boardLayoutMode: 'tabs');
    final decoded = AppSettings.fromJson(s.toJson());
    expect(decoded.floatingCaptureEnabled, isTrue);
    expect(decoded.boardLayoutMode, 'tabs');
  });

  testWidgets('SettingsSnifferSection renders floating capture switch', (tester) async {
    final translator = AppTranslator(initialLanguage: 'en');
    bool? toggled;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsSnifferSection(
            translator: translator,
            settings: const AppSettings(),
            onChanged: (_) {},
            onToggleFloatingCapture: (v) => toggled = v,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('settings_floating_capture_switch')));
    expect(toggled, isTrue);
  });
}
