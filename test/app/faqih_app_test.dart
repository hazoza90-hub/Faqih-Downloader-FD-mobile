import 'package:faqih_downloader_mobile/app/faqih_app.dart';
import 'package:faqih_downloader_mobile/core/i18n/translator.dart';
import 'package:faqih_downloader_mobile/core/theme/app_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('boots in dark theme, renders 3 Kanban tabs, and switches AR <-> EN', (
    tester,
  ) async {
    final translator = AppTranslator(initialLanguage: 'ar');

    await tester.pumpWidget(FaqihDownloaderApp(translator: translator));
    await tester.pumpAndSettle();

    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.themeMode, ThemeMode.dark);
    expect(materialApp.theme?.brightness, Brightness.light);
    expect(materialApp.darkTheme?.brightness, Brightness.dark);
    final activeTheme = Theme.of(tester.element(find.byKey(const Key('tab_staged'))));
    expect(activeTheme.brightness, Brightness.dark);
    expect(activeTheme.scaffoldBackgroundColor, AppColors.bgPrimary);

    expect(find.byKey(const Key('tab_staged')), findsOneWidget);
    expect(find.byKey(const Key('tab_active')), findsOneWidget);
    expect(find.byKey(const Key('tab_vault')), findsOneWidget);

    expect(find.text('التحضير'), findsOneWidget);
    expect(find.text('قيد التحميل'), findsOneWidget);
    expect(find.text('المكتمل'), findsOneWidget);
    expect(Directionality.of(tester.element(find.byKey(const Key('tab_staged')))), TextDirection.rtl);

    await tester.tap(find.byKey(const Key('lang_toggle_button')));
    await tester.pumpAndSettle();

    expect(find.text('Staged'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Vault'), findsOneWidget);
    expect(Directionality.of(tester.element(find.byKey(const Key('tab_staged')))), TextDirection.ltr);

    await tester.tap(find.byKey(const Key('lang_toggle_button')));
    await tester.pumpAndSettle();

    expect(find.text('التحضير'), findsOneWidget);
    expect(Directionality.of(tester.element(find.byKey(const Key('tab_staged')))), TextDirection.rtl);
  });
}
