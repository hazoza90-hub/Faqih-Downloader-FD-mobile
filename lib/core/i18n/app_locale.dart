import 'package:flutter/widgets.dart';

/// Supported application locales and RTL/LTR directionality helpers.
abstract final class AppLocale {
  static const String arabicCode = 'ar';
  static const String englishCode = 'en';

  static const Locale ar = Locale(arabicCode);
  static const Locale en = Locale(englishCode);

  static const List<Locale> supportedLocales = <Locale>[ar, en];

  static String normalizeCode(String? code) {
    final lower = (code ?? arabicCode).trim().toLowerCase();
    return lower == englishCode ? englishCode : arabicCode;
  }

  static bool isRtl(String? code) {
    return normalizeCode(code) == arabicCode;
  }

  static TextDirection textDirectionOf(String? code) {
    return isRtl(code) ? TextDirection.rtl : TextDirection.ltr;
  }

  static Locale toLocale(String? code) {
    return normalizeCode(code) == englishCode ? en : ar;
  }
}
