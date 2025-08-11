import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

extension SnackBarExtension on SnackBar {
  /// Shows a snackbar with optional "Copy" action.
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> show(
    BuildContext context,
    String text, {
    bool canCopyText = false,
  }) {
    return ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 2000),
        action: canCopyText
            ? SnackBarAction(
                label: 'Copy',
                onPressed: () => Clipboard.setData(ClipboardData(text: text)),
              )
            : null,
      ),
    );
  }

  /// Copy [text] to clipboard and notify with a snackbar.
  static Future<void> copy(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) show(context, 'Copied');
  }

  /// Simple launcher for non‑OAuth links (kept for desktop flows and misc links).
  static Future<bool> launch(BuildContext context, String link) async {
    try {
      final launchMode =
          (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
              ? LaunchMode.externalApplication
              : link.startsWith("https://anilist.co")
                  ? LaunchMode.inAppBrowserView
                  : LaunchMode.externalApplication;

      final ok = await launchUrl(Uri.parse(link), mode: launchMode);
      if (ok) return true;
    } catch (_) {}

    if (context.mounted) show(context, 'Could not open link');
    return false;
  }
}