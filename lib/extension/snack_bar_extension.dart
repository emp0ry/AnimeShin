import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

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

  /// Unified launcher that keeps backward compatibility:
  /// - Desktop (Windows/Linux/macOS): uses url_launcher as before.
  /// - Mobile (Android/iOS):
  ///     * If [link] is AniList OAuth authorize URL, use flutter_web_auth_2
  ///       to capture the "animeshin://" callback and pass it to [onAuthResult].
  ///     * Otherwise, fall back to url_launcher.
  ///
  /// NOTE: [onAuthResult] is optional and **does not break** existing calls.
  static Future<bool> launch(
    BuildContext context,
    String link, {
    Future<void> Function(String callbackUrl)? onAuthResult,
  }) async {
    try {
      // Detect AniList OAuth authorize endpoint.
      final isAniListAuth =
          link.startsWith('https://anilist.co/api/v2/oauth/authorize');

      // Desktop platforms: behave exactly like before.
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final mode = isAniListAuth
            ? LaunchMode.externalApplication
            : (link.startsWith('https://anilist.co')
                ? LaunchMode.inAppBrowserView
                : LaunchMode.externalApplication);

        final ok = await launchUrl(Uri.parse(link), mode: mode);
        if (!ok && context.mounted) show(context, 'Could not open link');
        return ok;
      }

      // Mobile platforms (Android/iOS).
      if (isAniListAuth) {
        // IMPORTANT: callbackUrlScheme must be just the scheme ("animeshin"),
        // not the full URL like "animeshin://oauth/callback".
        // AndroidManifest should use pathPrefix="/callback".
        final callbackUrl = await FlutterWebAuth2.authenticate(
          url: link,
          callbackUrlScheme: 'animeshin',
        );

        // Example callback:
        //   animeshin://oauth/callback/#access_token=...&expires_in=...
        if (onAuthResult != null) {
          await onAuthResult(callbackUrl);
        }
        return true;
      } else {
        // Non-OAuth links on mobile: fall back to url_launcher.
        final mode = link.startsWith('https://anilist.co')
            ? LaunchMode.inAppBrowserView
            : LaunchMode.externalApplication;

        final ok = await launchUrl(Uri.parse(link), mode: mode);
        if (!ok && context.mounted) show(context, 'Could not open link');
        return ok;
      }
    } catch (_) {
      if (context.mounted) show(context, 'Could not open link');
      return false;
    }
  }
}
