import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../app/app_controller.dart';
import '../../core/i18n/translator.dart';
import '../../core/theme/app_colors.dart';

/// Embedded WebView screen allowing users to sign in and export real HttpOnly cookies for yt-dlp.
class CookiesLoginScreen extends StatefulWidget {
  const CookiesLoginScreen({
    super.key,
    required this.translator,
    required this.controller,
    this.enableWebView = true,
  });

  final AppTranslator translator;
  final AppController controller;
  final bool enableWebView;

  @override
  State<CookiesLoginScreen> createState() => _CookiesLoginScreenState();
}

class _CookiesLoginScreenState extends State<CookiesLoginScreen> {
  static const Map<String, String> _quickSites = <String, String>{
    'YouTube': 'https://accounts.google.com/ServiceLogin?continue=https://www.youtube.com/',
    'Instagram': 'https://www.instagram.com/accounts/login/',
    'X': 'https://x.com/i/flow/login',
    'Facebook': 'https://m.facebook.com/login/',
    'TikTok': 'https://www.tiktok.com/login',
  };

  static const List<String> _exportDomainUrls = <String>[
    'https://www.youtube.com/',
    'https://m.youtube.com/',
    'https://accounts.google.com/',
    'https://www.google.com/',
    'https://www.instagram.com/',
    'https://x.com/',
    'https://twitter.com/',
    'https://www.facebook.com/',
    'https://m.facebook.com/',
    'https://www.tiktok.com/',
  ];

  WebViewController? _webController;
  String _currentUrl = _quickSites.values.first;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.enableWebView) {
      try {
        _webController = WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setNavigationDelegate(
            NavigationDelegate(
              onPageFinished: (url) => setState(() => _currentUrl = url),
            ),
          )
          ..loadRequest(Uri.parse(_currentUrl));
      } catch (_) {
        _webController = null;
      }
    }
  }

  Future<void> _saveCookies() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final tr = widget.translator.tr;
    try {
      final urls = <String>{..._exportDomainUrls, _currentUrl}.toList();
      final count = await widget.controller.saveWebViewCookies(urls);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            count > 0
                ? tr('msg_cookies_saved', params: <String, String>{'count': '$count'})
                : tr('msg_cookies_empty'),
          ),
        ),
      );
      if (count > 0) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.translator.tr;
    final webCtrl = _webController;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('cookies_login_title')),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: FilledButton.icon(
              key: const Key('save_cookies_button'),
              onPressed: _saving ? null : _saveCookies,
              icon: const Icon(Icons.cookie_outlined, size: 18),
              label: Text(tr('btn_save_cookies')),
            ),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: Text(
              tr('cookies_help_note'),
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _quickSites.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                final entry = _quickSites.entries.elementAt(index);
                return ActionChip(
                  label: Text(entry.key),
                  onPressed: () {
                    setState(() => _currentUrl = entry.value);
                    webCtrl?.loadRequest(Uri.parse(entry.value));
                  },
                );
              },
            ),
          ),
          const Divider(height: 8),
          Expanded(
            child: webCtrl != null
                ? WebViewWidget(controller: webCtrl)
                : Center(child: Text(_currentUrl)),
          ),
        ],
      ),
    );
  }
}
