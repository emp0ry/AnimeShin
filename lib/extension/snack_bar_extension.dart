import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

extension SnackBarExtension on SnackBar {
  static SnackBar _buildSnackBar(
    String text, {
    bool canCopyText = false,
  }) {
    return SnackBar(
      content: Text(text),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(milliseconds: 2000),
      action: canCopyText
          ? SnackBarAction(
              label: 'Copy',
              onPressed: () => Clipboard.setData(ClipboardData(text: text)),
            )
          : null,
    );
  }

  /// Shows a snackbar on an already-resolved [ScaffoldMessengerState].
  /// Useful when you want to avoid holding a [BuildContext] across async gaps.
  static void showOnMessenger(
    ScaffoldMessengerState? messenger,
    String text, {
    bool canCopyText = false,
  }) {
    messenger?.showSnackBar(_buildSnackBar(text, canCopyText: canCopyText));
  }

  /// Shows a snackbar with optional "Copy" action.
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> show(
    BuildContext context,
    String text, {
    bool canCopyText = false,
  }) {
    return ScaffoldMessenger.of(context).showSnackBar(
      _buildSnackBar(text, canCopyText: canCopyText),
    );
  }

  /// Copy [text] to clipboard and notify with a snackbar.
  static Future<void> copy(BuildContext context, String text) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: text));
    showOnMessenger(messenger, 'Copied');
  }

  /// Simple launcher for non‑OAuth links (kept for desktop flows and misc links).
  static Future<bool> launchLink(
    String link, {
    ScaffoldMessengerState? messenger,
  }) async {
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

    showOnMessenger(messenger, 'Could not open link');
    return false;
  }

  static Future<bool> launch(BuildContext context, String link) async {
    return launchLink(link, messenger: ScaffoldMessenger.maybeOf(context));
  }
}
