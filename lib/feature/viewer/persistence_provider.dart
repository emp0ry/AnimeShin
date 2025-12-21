import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:animeshin/feature/activity/activities_filter_model.dart';
import 'package:animeshin/feature/calendar/calendar_models.dart';
import 'package:animeshin/feature/collection/collection_filter_model.dart';
import 'package:animeshin/feature/discover/discover_filter_model.dart';
import 'package:animeshin/feature/viewer/persistence_model.dart';
import 'package:animeshin/util/background_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:animeshin/core/secure_storage.dart';

final storage = buildSecureStorage();

final persistenceProvider = NotifierProvider<PersistenceNotifier, Persistence>(
  PersistenceNotifier.new,
);

final viewerIdProvider = persistenceProvider.select(
  (s) => s.accountGroup.account?.id,
);

class PersistenceNotifier extends Notifier<Persistence> {
  // This box stores multiple value shapes (maps for most settings + a macOS
  // fallback string token), so keep it untyped.
  late Box<dynamic> _box;

  static String _fallbackTokenKey(int accountId) =>
      'accessTokenFallback_${Account.accessTokenKeyById(accountId)}';

  Map<String, String> _readFallbackTokensFromBox() {
    final map = <String, String>{};
    for (final dynamic key in _box.keys) {
      if (key is! String) continue;
      if (!key.startsWith('accessTokenFallback_')) continue;
      final value = _box.get(key);
      if (value is String && value.isNotEmpty) {
        // Store by the same key shape AccountGroup expects: auth<ID>
        map[key.substring('accessTokenFallback_'.length)] = value;
      }
    }
    return map;
  }

  @override
  Persistence build() => Persistence.empty();

  Future<void> init() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Configure home directory, if not in the browser.
    if (!kIsWeb) {
      final dir = defaultTargetPlatform == TargetPlatform.macOS
          ? await getApplicationSupportDirectory()
          : await getApplicationDocumentsDirectory();
      Hive.init(dir.path);
    }

    _box = await Hive.openBox('persistence');
    final secureTokens = await storage.readAll();

    // On some CI-signed macOS builds, Keychain writes can fail due to signing/
    // entitlements mismatches. To avoid "login says success but no account",
    // we allow a macOS-only Hive fallback store.
    final fallbackTokens = (!kIsWeb && Platform.isMacOS)
        ? _readFallbackTokensFromBox()
        : const <String, String>{};

    state = Persistence.fromPersistenceMap(
      _box.toMap(),
      {
        ...fallbackTokens,
        ...secureTokens, // secure storage wins when available
      },
    );
  }

  void cacheSystemPrimaryColors(SystemColors systemColors) {
    state = state.copyWith(systemColors: systemColors);
  }

  void setOptions(Options options) {
    _box.put('options', options.toPersistenceMap());
    state = state.copyWith(options: options);
  }

  void setAppMeta(AppMeta appMeta) {
    _box.put('appMeta', appMeta.toPersistenceMap());
    state = state.copyWith(appMeta: appMeta);
  }

  void setAnimeCollectionMediaFilter(CollectionMediaFilter mediaFilter) {
    _box.put('animeCollectionMediaFilter', mediaFilter.toPersistenceMap());
    state = state.copyWith(animeCollectionMediaFilter: mediaFilter);
  }

  void setMangaCollectionMediaFilter(CollectionMediaFilter mediaFilter) {
    _box.put('mangaCollectionMediaFilter', mediaFilter.toPersistenceMap());
    state = state.copyWith(mangaCollectionMediaFilter: mediaFilter);
  }

  void setDiscoverMediaFilter(DiscoverMediaFilter discoverMediaFilter) {
    _box.put('discoverMediaFilter', discoverMediaFilter.toPersistenceMap());
    state = state.copyWith(discoverMediaFilter: discoverMediaFilter);
  }

  void setHomeActivitiesFilter(HomeActivitiesFilter homeActivitiesFilter) {
    _box.put('homeActivitiesFilter', homeActivitiesFilter.toPersistenceMap());
    state = state.copyWith(homeActivitiesFilter: homeActivitiesFilter);
  }

  void setCalendarFilter(CalendarFilter calendarFilter) {
    _box.put('calendarFilter', calendarFilter.toPersistenceMap());
    state = state.copyWith(calendarFilter: calendarFilter);
  }

  void refreshViewerDetails(String newName, String newAvatarUrl) {
    final accounts = state.accountGroup.accounts;
    final accountIndex = state.accountGroup.accountIndex;

    if (accountIndex == null) return;
    final account = accounts[accountIndex];

    if (account.name == newName && account.avatarUrl == newAvatarUrl) return;

    _setAccountGroup(
      AccountGroup(
        accounts: [
          ...accounts.sublist(0, accountIndex),
          Account(
            name: newName,
            avatarUrl: newAvatarUrl,
            id: account.id,
            expiration: account.expiration,
            accessToken: account.accessToken,
          ),
          ...accounts.sublist(accountIndex + 1)
        ],
        accountIndex: accountIndex,
      ),
    );
  }

  /// Switches active account.
  /// Don't switch to an account whose token has expired.
  void switchAccount(int? index) {
    final accountGroup = state.accountGroup;

    if (index == accountGroup.accountIndex) return;
    if (index != null && (index < 0 || index >= accountGroup.accounts.length)) {
      return;
    }

    if (index == null) BackgroundHandler.clearNotifications();

    _setAccountGroup(
      AccountGroup(
        accountIndex: index,
        accounts: accountGroup.accounts,
      ),
    );
  }

  Future<void> addAccount(Account account) async {
    final accounts = state.accountGroup.accounts;
    final accountIndex = state.accountGroup.accountIndex;

    final tokenKey = Account.accessTokenKeyById(account.id);
    try {
      await storage.write(
        key: tokenKey,
        value: account.accessToken,
      );
      if (!kIsWeb && Platform.isMacOS) {
        // Clean up any previous fallback token.
        await _box.delete(_fallbackTokenKey(account.id));
      }
    } catch (e) {
      // If Keychain fails on macOS (common with CI signing issues), don't abort
      // account setup. Store a best-effort fallback so the account is usable.
      if (!kIsWeb && Platform.isMacOS) {
        await _box.put(_fallbackTokenKey(account.id), account.accessToken);
      } else {
        rethrow;
      }
    }

    for (int i = 0; i < accounts.length; i++) {
      if (accounts[i].id == account.id) {
        _setAccountGroup(
          AccountGroup(
            accounts: [
              ...accounts.sublist(0, i),
              account,
              ...accounts.sublist(i + 1),
            ],
            accountIndex: accountIndex,
          ),
        );

        switchAccount(i);
        return;
      }
    }

    _setAccountGroup(
      AccountGroup(
        accounts: [...accounts, account],
        accountIndex: accountIndex,
      ),
    );

    switchAccount(state.accountGroup.accounts.length - 1);
  }

  Future<void> removeAccount(int index) async {
    final accountGroup = state.accountGroup;

    if (index == accountGroup.accountIndex) return;
    if (index < 0 || index >= accountGroup.accounts.length) return;

    final account = accountGroup.accounts[index];
    final tokenKey = Account.accessTokenKeyById(account.id);
    try {
      await storage.delete(key: tokenKey);
    } catch (e) {
      if (!kIsWeb && Platform.isMacOS) {
        // Ignore Keychain issues; we'll also delete fallback below.
      } else {
        rethrow;
      }
    }
    if (!kIsWeb && Platform.isMacOS) {
      await _box.delete(_fallbackTokenKey(account.id));
    }

    _setAccountGroup(
      AccountGroup(
        accounts: [
          ...accountGroup.accounts.sublist(0, index),
          ...accountGroup.accounts.sublist(index + 1),
        ],
        accountIndex: accountGroup.accountIndex,
      ),
    );
  }

  /// Persists the account changes, but doesn't affect secure storage.
  /// Token changes must be handled separately.
  void _setAccountGroup(AccountGroup accountGroup) {
    _box.put('accountGroup', accountGroup.toPersistenceMap());
    state = state.copyWith(accountGroup: accountGroup);
  }
}
