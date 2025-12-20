import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:animeshin/feature/export/export_button.dart';
import 'package:animeshin/feature/viewer/persistence_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:ionicons/ionicons.dart';
import 'package:animeshin/extension/date_time_extension.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/util/routes.dart';
import 'package:animeshin/feature/user/user_model.dart';
import 'package:animeshin/util/theming.dart';
import 'package:animeshin/widget/cached_image.dart';
import 'package:animeshin/widget/input/pill_selector.dart';
import 'package:animeshin/widget/layout/content_header.dart';
import 'package:animeshin/widget/dialogs.dart';
import 'package:animeshin/extension/snack_bar_extension.dart';
import 'package:animeshin/widget/text_rail.dart';
import 'package:webview_flutter/webview_flutter.dart'; // WebView for OAuth (no deep-link dependency)
import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode;

/// ------------------------
/// Desktop helper for implicit flow
/// ------------------------
class _TokenListener {
  _TokenListener(this._server, this._completer);

  final HttpServer _server;
  final Completer<String?> _completer;

  Future<String?> wait() {
    return _completer.future
        .timeout(const Duration(minutes: 5), onTimeout: () => null);
  }

  Future<void> cancel() async {
    if (!_completer.isCompleted) {
      _completer.complete(null);
    }
    try {
      await _server.close(force: true);
    } catch (_) {
      // Best-effort.
    }
  }
}

Future<_TokenListener> _startTokenListener({int port = 28371}) async {
  // Bind IPv6 loopback and allow IPv4, so both ::1 and 127.0.0.1 work.
  HttpServer server;
  try {
    server = await HttpServer.bind(
      InternetAddress.loopbackIPv6,
      port,
      v6Only: false,
    );
  } catch (e) {
    // Log bind errors (port in use, firewall denied, etc.)
    debugPrint('[OAuth] HttpServer.bind failed on $port: $e');
    rethrow;
  }

  final completer = Completer<String?>();

  server.listen((HttpRequest request) async {
    if (request.uri.path == '/') {
      // Serve a tiny page that reads the fragment & posts it back to /token.
      // NOTE: relative fetch keeps the same origin (works with ::1 or 127.0.0.1).
      final htmlContent = '''
<!DOCTYPE html>
<html><body>
<script>
  // Read access_token from location.hash (#...)
  const params = new URLSearchParams(window.location.hash.slice(1));
  const token = params.get('access_token');
  if (token) {
    fetch('/token?access_token=' + encodeURIComponent(token))
      .then(() => { document.body.innerHTML = "Success! You can close this window."; })
      .catch(() => { document.body.innerHTML = "Error sending token."; });
  } else {
    document.body.innerHTML = "Error: No token found.";
  }
</script>
</body></html>
      ''';
      request.response
        ..headers.contentType = ContentType.html
        ..write(htmlContent);
      await request.response.close();
      return;
    }

    if (request.uri.path == '/token') {
      final token = request.uri.queryParameters['access_token'];
      await request.response.close();
      if (!completer.isCompleted && token != null) {
        completer.complete(token);
        try {
          await server.close(force: true);
        } catch (_) {
          // Best-effort.
        }
      }
      return;
    }

    // Optional: 404 for anything else
    request.response.statusCode = 404;
    await request.response.close();
  });

  return _TokenListener(server, completer);
}

Future<String?> listenForToken({int port = 28371}) async {
  final listener = await _startTokenListener(port: port);
  try {
    return await listener.wait();
  } finally {
    // Ensure port is freed even if caller abandons the future.
    await listener.cancel();
  }
}

/// Fetch AniList Viewer profile with the received access token
Future<Map<String, dynamic>?> fetchAniListProfile(String accessToken) async {
  final response = await http.post(
    Uri.parse('https://graphql.anilist.co'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $accessToken',
    },
    body: jsonEncode({
      'query': '''
        query {
          Viewer {
            id
            name
            about
            avatar { large }
            bannerImage
            siteUrl
            isFollowing
            isFollower
            isBlocked
            donatorTier
            donatorBadge
            moderatorRoles
            statistics {
              anime { count meanScore }
              manga { count meanScore }
            }
          }
        }
      ''',
    }),
  );
  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    return data['data']['Viewer'];
  }
  return null;
}

/// ------------------------
/// Small OAuth result model
/// ------------------------
class OAuthResult {
  final String accessToken;
  final int expiresIn; // seconds
  OAuthResult({required this.accessToken, required this.expiresIn});
}

/// ------------------------
/// WebView-based OAuth page
/// ------------------------
/// We open AniList authorize URL, wait for redirect to the app scheme.
/// In LiveContainer (or any host), we intercept the custom scheme inside WebView
/// and never rely on OS deep link handlers.
class AuthWebViewPage extends StatefulWidget {
  const AuthWebViewPage({
    super.key,
    required this.authUrl,
    required this.redirectScheme,
    required this.redirectHost,
    required this.redirectPath,
  });

  final String authUrl;
  final String redirectScheme; // e.g. "app"
  final String redirectHost; // e.g. "animeshin"
  final String redirectPath; // e.g. "/auth"

  @override
  State<AuthWebViewPage> createState() => _AuthWebViewPageState();
}

class _AuthWebViewPageState extends State<AuthWebViewPage> {
  late final WebViewController _controller;
  bool _loading = true;
  bool _completed = false;

  void _maybeCompleteFromUri(Uri uri, {required String source}) {
    if (_completed) return;

    // Accept the expected callback scheme/path. On macOS the host component
    // may be empty or differ in how it's reported by the WebView.
    final isCallbackScheme = uri.scheme == widget.redirectScheme;
    final isCallbackPath = uri.path == widget.redirectPath ||
        uri.path.startsWith('${widget.redirectPath}/');
    final isCallback = isCallbackScheme && isCallbackPath;

    // Fallback: sometimes WebView reports the final URL differently, but still
    // includes the token in the fragment/query.
    final params = _parseImplicitParams(uri);
    final token = (params['access_token'] ?? '').trim();
    final expires = int.tryParse(params['expires_in'] ?? '') ?? 31536000;

    if (kDebugMode) {
      final hasToken = token.isNotEmpty;
      debugPrint(
        '[OAuth][$source] url=${uri.scheme}://${uri.host}${uri.path} '
        'isCallback=$isCallback hasToken=$hasToken',
      );
    }

    if (!isCallback && token.isEmpty) return;

    _completed = true;
    Navigator.of(context).pop(
      token.isNotEmpty ? OAuthResult(accessToken: token, expiresIn: expires) : null,
    );
  }

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'OAuth',
        onMessageReceived: (message) {
          if (_completed) return;
          // Expect a query-string-like payload e.g. "access_token=...&expires_in=..."
          final raw = message.message.trim();
          if (raw.isEmpty) return;
          Map<String, String> params;
          try {
            params = Uri.splitQueryString(raw);
          } catch (_) {
            params = {};
          }
          final token = (params['access_token'] ?? '').trim();
          final expires = int.tryParse(params['expires_in'] ?? '') ?? 31536000;
          if (kDebugMode) {
            debugPrint('[OAuth][js] hasToken=${token.isNotEmpty}');
          }
          if (token.isEmpty) return;
          _completed = true;
          Navigator.of(context).pop(
            OAuthResult(accessToken: token, expiresIn: expires),
          );
        },
      )
      // ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) async {
            if (mounted) setState(() => _loading = false);
            // JS fallback: if the current page has the token in location.hash,
            // post it back to Flutter.
            try {
              await _controller.runJavaScript('''
(function(){
  try {
    var raw = (window.location.hash || '').replace(/^#/, '');
    if (raw && raw.indexOf('access_token=') !== -1) {
      OAuth.postMessage(raw);
    }
  } catch (e) {}
})();
              ''');
            } catch (_) {
              // Ignore: some platforms/pages may not allow JS execution.
            }
          },
          onUrlChange: (change) {
            final url = change.url;
            if (url == null) return;
            _maybeCompleteFromUri(Uri.parse(url), source: 'urlChange');
          },
          onNavigationRequest: (request) {
            final uri = Uri.parse(request.url);
            _maybeCompleteFromUri(uri, source: 'navRequest');

            // If it's the callback scheme, prevent navigation so WebView doesn't
            // try (and fail) to open a custom scheme.
            final isCallbackScheme = uri.scheme == widget.redirectScheme;
            final isCallbackPath = uri.path == widget.redirectPath ||
                uri.path.startsWith('${widget.redirectPath}/');
            if (isCallbackScheme && isCallbackPath) {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );

    // Only on Android/iOS:
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      _controller.setBackgroundColor(Colors.transparent);
    }

    _controller.loadRequest(Uri.parse(widget.authUrl));
  }

  Map<String, String> _parseImplicitParams(Uri uri) {
    // Primary source: fragment; fallback: query (just in case)
    final raw = uri.fragment.isNotEmpty ? uri.fragment : uri.query;
    if (raw.isEmpty) return {};
    try {
      return Uri.splitQueryString(raw);
    } catch (_) {
      final map = <String, String>{};
      for (final part in raw.split('&')) {
        final i = part.indexOf('=');
        if (i > 0) {
          final k = part.substring(0, i);
          final v = Uri.decodeComponent(part.substring(i + 1));
          map[k] = v;
        }
      }
      return map;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AniList Login')),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
        ],
      ),
    );
  }
}

/// ------------------------
/// Header
/// ------------------------
class UserHeader extends StatelessWidget {
  const UserHeader({
    required this.id,
    required this.isViewer,
    required this.user,
    required this.imageUrl,
    required this.toggleFollow,
  });

  final int? id;
  final bool isViewer;
  final User? user;
  final String? imageUrl;
  final Future<Object?> Function() toggleFollow;

  @override
  Widget build(BuildContext context) {
    final textRailItems = <String, bool>{};
    if (user != null) {
      if (user!.modRoles.isNotEmpty) textRailItems[user!.modRoles[0]] = false;
      if (user!.donatorTier > 0) textRailItems[user!.donatorBadge] = true;
    }
    return ContentHeader(
      imageUrl: user?.imageUrl ?? imageUrl,
      imageHeightToWidthRatio: 1,
      imageHeroTag: id ?? '',
      imageFit: BoxFit.contain,
      bannerUrl: user?.bannerUrl,
      siteUrl: user?.siteUrl,
      title: user?.name,
      details: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (user?.modRoles.isNotEmpty ?? false) {
            showDialog(
              context: context,
              builder: (context) => TextDialog(
                title: 'Roles',
                text: user!.modRoles.join(', '),
              ),
            );
          }
        },
        child: TextRail(
          textRailItems,
          style: TextTheme.of(context).labelMedium,
        ),
      ),
      trailingTopButtons: [
        if (isViewer) ...[
          IconButton(
            tooltip: 'Switch Account',
            icon: const Icon(Icons.manage_accounts_outlined),
            onPressed: () => showDialog(
              context: context,
              builder: (context) => const _AccountPicker(),
            ),
          ),
          ExportButton(),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Ionicons.cog_outline),
            onPressed: () => context.push(Routes.settings),
          ),
        ] else if (user != null)
          _FollowButton(user!, toggleFollow),
      ],
    );
  }
}

/// ------------------------
/// Account picker + OAuth
/// ------------------------
class _AccountPicker extends StatefulWidget {
  const _AccountPicker();

  @override
  State<_AccountPicker> createState() => __AccountPickerState();
}

class __AccountPickerState extends State<_AccountPicker> {
  // NOTE: Keep the client IDs you already use
  static const _mobileClientId = '29017';
  static const _desktopClientId = '29106';

  // IMPORTANT:
  // Your registered mobile redirect URI with AniList is: app://animeshin/auth
  // We will supply it explicitly and intercept it inside the WebView.
  static const _redirectScheme = 'app';
  static const _redirectHost = 'animeshin';
  static const _redirectPath = '/auth';

  /// Builds the authorize URL for implicit flow.
  static String _buildAuthUrl({
    required String clientId,
  }) {
    final qp = <String, String>{
      'client_id': clientId,
      'response_type': 'token', // implicit flow
    };
    return Uri.parse('https://anilist.co/api/v2/oauth/authorize')
        .replace(queryParameters: qp)
        .toString();
  }

  /// For mobile we use WebView with explicit redirect to app://animeshin/auth.
  /// For desktop we keep the existing local server flow in browser.
  static String get _loginLinkMobile =>
      _buildAuthUrl(clientId: _mobileClientId);

  static String get _loginLinkDesktop =>
      _buildAuthUrl(clientId: _desktopClientId);

  static const _imageSize = 55.0;

  @override
  Widget build(BuildContext context) {
    const divider = SizedBox(
      height: 40,
      child: VerticalDivider(width: 10, thickness: 1),
    );
    const imagePadding = EdgeInsets.symmetric(horizontal: 5);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(
        vertical: 24,
        horizontal: Theming.offset,
      ),
      child: Consumer(
        builder: (context, ref, _) {
          final accountGroup = ref.watch(
            persistenceProvider.select((s) => s.accountGroup),
          );
          final accounts = accountGroup.accounts;
          final items = <Widget>[];
          for (int i = 0; i < accounts.length; i++) {
            items.add(SizedBox(
              height: 60,
              child: Row(
                children: [
                  Padding(
                    padding: imagePadding,
                    child: CachedImage(
                      accounts[i].avatarUrl,
                      width: _imageSize,
                      height: _imageSize,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${accounts[i].name} ${accounts[i].id}',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 2,
                        ),
                        Text(
                          DateTime.now().isBefore(accounts[i].expiration)
                              ? 'Expires in ${accounts[i].expiration.timeUntil}'
                              : 'Expired',
                          style: TextTheme.of(context).labelMedium,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 2,
                        )
                      ],
                    ),
                  ),
                  divider,
                  IconButton(
                    tooltip: 'Remove Account',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => ConfirmationDialog.show(
                      context,
                      title: 'Remove Account?',
                      primaryAction: 'Yes',
                      secondaryAction: 'No',
                      onConfirm: () {
                        if (i == accountGroup.accountIndex) {
                          ref
                              .read(persistenceProvider.notifier)
                              .switchAccount(null);
                        }
                        ref
                            .read(persistenceProvider.notifier)
                            .removeAccount(i)
                            .then((_) => setState(() {}));
                      },
                    ),
                  ),
                ],
              ),
            ));
          }
          items.add(SizedBox(
            height: 60,
            child: Row(
              children: [
                const Padding(
                  padding: imagePadding,
                  child: Icon(Icons.person_rounded, size: _imageSize),
                ),
                const Expanded(child: Text('Guest')),
                divider,
                IconButton(
                  tooltip: 'Add Account',
                  icon: const Icon(Icons.add_rounded),
                  onPressed: () => _addAccount(ref, accounts.isEmpty),
                ),
              ],
            ),
          ));
          return PillSelector(
            maxWidth: 380,
            shrinkWrap: true,
            selected: accountGroup.accountIndex ?? accounts.length,
            items: items,
            onTap: (i) async {
              if (i == accounts.length) {
                ref.read(persistenceProvider.notifier).switchAccount(null);
                Navigator.pop(context);
                return;
              }
              if (DateTime.now().isBefore(accounts[i].expiration)) {
                ref.read(persistenceProvider.notifier).switchAccount(i);
                Navigator.pop(context);
                return;
              }
              var ok = false;
              await ConfirmationDialog.show(
                context,
                title: 'Session expired',
                content: 'Do you want to log in again?',
                primaryAction: 'Yes',
                secondaryAction: 'No',
                onConfirm: () => ok = true,
              );
              if (ok) _addAccount(ref, accounts.isEmpty);
            },
          );
        },
      ),
    );
  }

  Future<void> _addAccount(WidgetRef ref, bool isAccountListEmpty) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final nav = Navigator.of(context);

    // --- Mobile path: use embedded WebView and intercept callback ---
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      final result = await nav.push<OAuthResult?>(
        MaterialPageRoute(
          builder: (_) => AuthWebViewPage(
            authUrl: _loginLinkMobile,
            redirectScheme: _redirectScheme, // "app"
            redirectHost: _redirectHost, // "animeshin"
            redirectPath: _redirectPath, // "/auth"
          ),
        ),
      );

      if (result == null) {
        SnackBarExtension.showOnMessenger(
            messenger, 'Login canceled or failed');
        return;
      }

      final accessToken = result.accessToken;
      final expiration =
          DateTime.now().add(Duration(seconds: result.expiresIn));

      final profile = await fetchAniListProfile(accessToken);
      if (profile == null) {
        SnackBarExtension.showOnMessenger(messenger, 'Failed to load profile');
        return;
      }

      final account = Account(
        id: profile['id'],
        name: profile['name'],
        avatarUrl: profile['avatar']['large'],
        expiration: expiration,
        accessToken: accessToken,
      );
      await ref.read(persistenceProvider.notifier).addAccount(account);
      if (!mounted) return;
      if (nav.canPop()) nav.pop();
      return;
    }

    // --- Desktop path: keep existing external browser flow with localhost listener ---
    if (isAccountListEmpty) {
      final futureToken = listenForToken(port: 28371);

      await SnackBarExtension.launchLink(
        _loginLinkDesktop,
        messenger: messenger,
      );
      final accessToken = await futureToken;
      if (accessToken != null) {
        final profile = await fetchAniListProfile(accessToken);
        if (profile != null) {
          final now = DateTime.now();
          final expiration = now.add(const Duration(days: 365));
          final account = Account(
            id: profile['id'],
            name: profile['name'],
            avatarUrl: profile['avatar']['large'],
            expiration: expiration,
            accessToken: accessToken,
          );
          await ref.read(persistenceProvider.notifier).addAccount(account);
          if (!mounted) return;
          if (nav.canPop()) nav.pop();
        }
      }
      return;
    } else {
      final futureToken = listenForToken(port: 28371); // start listener FIRST

      ConfirmationDialog.show(
        context,
        title: 'Add an Account',
        content:
            'To add more accounts, make sure you are logged out of the previous ones in the browser.',
        primaryAction: 'Continue',
        secondaryAction: 'Cancel',
        onConfirm: () async {
          final confirmMessenger = ScaffoldMessenger.maybeOf(context);
          final confirmNav = Navigator.of(context);

          await SnackBarExtension.launchLink(
            _loginLinkDesktop,
            messenger: confirmMessenger,
          );
          final accessToken = await futureToken;
          if (accessToken == null) {
            SnackBarExtension.showOnMessenger(
              confirmMessenger,
              'Login canceled or failed',
            );
            return;
          }
          final profile = await fetchAniListProfile(accessToken);
          if (profile == null) {
            SnackBarExtension.showOnMessenger(
                confirmMessenger, 'Failed to load profile');
            return;
          }
          final now = DateTime.now();
          final expiration = now.add(const Duration(days: 365));
          final account = Account(
            id: profile['id'],
            name: profile['name'],
            avatarUrl: profile['avatar']['large'],
            expiration: expiration,
            accessToken: accessToken,
          );
          await ref.read(persistenceProvider.notifier).addAccount(account);
          if (!mounted) return;
          if (confirmNav.canPop()) confirmNav.pop();
        },
      );
    }
  }
}

/// ------------------------
/// Follow button
/// ------------------------
class _FollowButton extends StatefulWidget {
  const _FollowButton(this.user, this.toggleFollow);

  final User user;
  final Future<Object?> Function() toggleFollow;

  @override
  State<_FollowButton> createState() => __FollowButtonState();
}

class __FollowButtonState extends State<_FollowButton> {
  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    return Padding(
      padding: const EdgeInsets.all(Theming.offset),
      child: ElevatedButton.icon(
        icon: Icon(
          user.isFollowed
              ? Ionicons.person_remove_outline
              : Ionicons.person_add_outline,
          size: Theming.iconSmall,
        ),
        label: Text(
          user.isFollowed
              ? user.isFollower
                  ? 'Mutual'
                  : 'Following'
              : user.isFollower
                  ? 'Follower'
                  : 'Follow',
        ),
        onPressed: () {
          final isFollowed = user.isFollowed;
          setState(() => user.isFollowed = !isFollowed);
          widget.toggleFollow().then((err) {
            if (err == null) return;
            setState(() => user.isFollowed = isFollowed);
            if (context.mounted) {
              SnackBarExtension.show(context, err.toString());
            }
          });
        },
      ),
    );
  }
}
