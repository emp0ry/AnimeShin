import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:animeshin/feature/viewer/persistence_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
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

/// ------------------------
/// Desktop helper (unchanged)
/// ------------------------
Future<String?> listenForToken({int port = 28371}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  final completer = Completer<String?>();

  server.listen((HttpRequest request) async {
    if (request.uri.path == '/') {
      final htmlContent = '''
        <!DOCTYPE html>
        <html>
        <body>
        <script>
          const params = new URLSearchParams(window.location.hash.slice(1));
          const token = params.get('access_token');
          if (token) {
            fetch('http://localhost:28371/token?access_token=' + encodeURIComponent(token))
              .then(() => {
                document.body.innerHTML = "Success! You can close this window.";
              })
              .catch(() => {
                document.body.innerHTML = "Error sending token.";
              });
          } else {
            document.body.innerHTML = "Error: No token found.";
          }
        </script>
        </body>
        </html>
      ''';
      request.response
        ..headers.contentType = ContentType.html
        ..write(htmlContent);
      await request.response.close();
      return;
    }

    final token = request.uri.queryParameters['access_token'];
    await request.response.close();
    if (!completer.isCompleted && token != null) {
      completer.complete(token);
      await server.close();
    }
  });

  return completer.future;
}

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
  static const _mobileClientId = '29017';
  static const _desktopClientId = '29106';

  // Зарегистрируй такой redirect в AniList Dashboard для обоих клиентов
  static const _redirectUri = 'animeshin://oauth/callback';

  static String _buildAuthUrl({required bool mobile}) {
    final clientId = mobile ? _mobileClientId : _desktopClientId;
    return Uri.parse('https://anilist.co/api/v2/oauth/authorize').replace(
      queryParameters: {
        'client_id': clientId,
        'response_type': 'token',     // implicit
        // 'redirect_uri': _redirectUri, // КРИТИЧНО
      },
    ).toString();
  }

  static String get _loginLink => (Platform.isAndroid || Platform.isIOS)
      ? _buildAuthUrl(mobile: true)
      : _buildAuthUrl(mobile: false);

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
    // ---------
    // Mobile
    // ---------
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final callbackUrl = await FlutterWebAuth2.authenticate(
          url: _loginLink,
          // должен совпадать со схемой в манифестах и в redirect_uri
          callbackUrlScheme: 'animeshin',
        );

        // Пример: animeshin://oauth/callback#access_token=...&token_type=Bearer&expires_in=31536000
        final returned = Uri.parse(callbackUrl);

        // У некоторых реализаций (на всякий) параметры могут прийти как query — проверим оба
        final rawParams = returned.fragment.isNotEmpty
            ? returned.fragment
            : (returned.query.isNotEmpty ? returned.query : '');

        if (rawParams.isEmpty) {
          SnackBarExtension.show(context, 'Login failed: empty callback');
          return;
        }

        Map<String, String> params;
        try {
          params = Uri.splitQueryString(rawParams);
        } catch (_) {
          params = {
            for (final kv in rawParams.split('&'))
              if (kv.contains('='))
                kv.split('=')[0]: Uri.decodeComponent(kv.split('=')[1]),
          };
        }

        final accessToken = params['access_token'];
        final expiresInStr = params['expires_in'];
        if (accessToken == null || accessToken.isEmpty) {
          SnackBarExtension.show(context, 'Login failed: no access token');
          return;
        }

        final expiresIn = int.tryParse(expiresInStr ?? '') ?? 31536000;
        final expiration = DateTime.now().add(Duration(seconds: expiresIn));

        final profile = await fetchAniListProfile(accessToken);
        if (profile == null) {
          SnackBarExtension.show(context, 'Failed to load profile');
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
        Navigator.pop(context);
      } catch (e) {
        SnackBarExtension.show(context, 'Auth error: $e');
      }
      return;
    }

    // ---------
    // Desktop
    // ---------
    if (isAccountListEmpty) {
      final futureToken = listenForToken(port: 28371);
      await SnackBarExtension.launch(context, _loginLink);
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
          Navigator.pop(context);
        }
      }
      return;
    } else {
      ConfirmationDialog.show(
        context,
        title: 'Add an Account',
        content:
            'To add more accounts, make sure you\'re logged out of the previous ones in the browser.',
        primaryAction: 'Continue',
        secondaryAction: 'Cancel',
        onConfirm: () {
          if (mounted) {
            SnackBarExtension.launch(context, _loginLink);
          }
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