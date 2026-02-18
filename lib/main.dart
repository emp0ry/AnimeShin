import 'dart:async';
import 'dart:io' show Directory, File, FileLock, FileMode, Platform, RandomAccessFile, exit;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'package:animeshin/feature/viewer/persistence_model.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/util/routes.dart';
import 'package:animeshin/util/background_handler.dart';
import 'package:animeshin/util/module_loader/remote_modules_store.dart';
import 'package:animeshin/util/theming.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:package_info_plus/package_info_plus.dart';

final _notificationCtrl = StreamController<String>.broadcast();
// ignore: unused_element
RandomAccessFile? _singleInstanceLockFile;

bool _isFileLockError(Object error) {
  final msg = error.toString().toLowerCase();
  return msg.contains('lock failed') ||
      msg.contains('cannot access the file') ||
      msg.contains('being used by another process') ||
      msg.contains('errno = 33');
}

bool _isWindowSettingsLockError(Object error) {
  final msg = error.toString().toLowerCase();
  return msg.contains('window_settings.lock') && _isFileLockError(error);
}

Future<bool> _acquireSingleInstanceLock(Directory dir) async {
  try {
    final lockPath =
        '${dir.path}${Platform.pathSeparator}animeshin.instance.lock';
    final file = File(lockPath);
    final handle = await file.open(mode: FileMode.writeOnlyAppend);
    await handle.lock(FileLock.exclusive);
    _singleInstanceLockFile = handle;
    return true;
  } catch (e) {
    if (_isFileLockError(e)) return false;
    rethrow;
  }
}

Future<void> _updateRemoteModulesOnStartup() async {
  try {
    await RemoteModulesStore().downloadAllEnabledRemote(
      perModuleTimeout: const Duration(seconds: 8),
      skipLoopbackHosts: true,
    );
  } catch (e) {
    if (kDebugMode) {
      debugPrint('module auto-update failed: $e');
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (kDebugMode) {
    final prev = FlutterError.onError;
    FlutterError.onError = (details) {
      final msg = details.exceptionAsString();
      if (msg.contains('HardwareKeyboard') &&
          msg.contains("!_pressedKeys.containsKey")) {
        // Known framework-level issue on some Windows setups.
        // Keep debug console usable; do not affect release builds.
        return;
      }
      if (prev != null) {
        prev(details);
      } else {
        FlutterError.presentError(details);
      }
    };
  }

  tz.initializeTimeZones();

  final info = await PackageInfo.fromPlatform();
  appVersion = info.version;

  // Initialize Hive (required for Hive.openBox).
  // On desktop, prefer Application Support to avoid protected folder access
  // and avoid saving app data to user-facing Documents folders.
  if (!kIsWeb) {
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final Directory dir = isDesktop
        ? await getApplicationSupportDirectory()
        : await getApplicationDocumentsDirectory();

    if (isDesktop) {
      final acquired = await _acquireSingleInstanceLock(dir);
      if (!acquired) {
        if (kDebugMode) {
          debugPrint('another AnimeShin instance is already running');
        }
        exit(0);
      }
    }

    Hive.init(dir.path);
  }

  MediaKit.ensureInitialized();

  // === Desktop window size persistence ===
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    try {
      await windowManager.ensureInitialized();

      await Hive.openBox('window_settings');
      final box = Hive.box('window_settings');

      // Get saved window size or use default
      final width = box.get('window_width', defaultValue: 510.0);
      final height = box.get('window_height', defaultValue: 860.0);

      await windowManager.setSize(Size(width, height));
    } catch (e) {
      // Second app instance can fail on locked window settings file.
      if (_isWindowSettingsLockError(e)) {
        if (kDebugMode) {
          debugPrint('window_settings is locked; another AnimeShin instance is running');
        }
        exit(0);
      }
      rethrow;
    }
  }

  final container = ProviderContainer();
  await container.read(persistenceProvider.notifier).init();
  BackgroundHandler.init(_notificationCtrl);
  unawaited(_updateRemoteModulesOnStartup());

  runApp(UncontrolledProviderScope(container: container, child: const _App()));

  // Debug-only sanity check for secure storage. Do not block app startup.
  if (kDebugMode) {
    unawaited(() async {
      try {
        await storage
            .write(key: 'probe', value: DateTime.now().toIso8601String())
            .timeout(const Duration(seconds: 2));
        final ok = await storage.read(key: 'probe').timeout(const Duration(seconds: 2));
        debugPrint('secure storage probe: $ok');
      } catch (e) {
        debugPrint('secure storage probe failed: $e');
      }
    }());
  }

  // Listen for resize events on desktop only
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    windowManager.addListener(_WindowResizeListener());
  }
}

class _WindowResizeListener extends WindowListener {
  @override
  void onWindowResize() async {
    // Only execute if box is open (for safety)
    if (Hive.isBoxOpen('window_settings')) {
      final box = Hive.box('window_settings');
      final size = await windowManager.getSize();
      box.put('window_width', size.width);
      box.put('window_height', size.height);
    }
  }
}

class _App extends ConsumerStatefulWidget {
  const _App();

  @override
  AppState createState() => AppState();
}

class AppState extends ConsumerState<_App> {
  late final GoRouter _router;
  late final StreamSubscription<String> _notificationSubscription;
  Color? _systemLightPrimaryColor;
  Color? _systemDarkPrimaryColor;

  @override
  void initState() {
    super.initState();

    final mustConfirmExit =
        () => ref.read(persistenceProvider).options.confirmExit;

    _router = Routes.buildRouter(mustConfirmExit);

    _notificationSubscription = _notificationCtrl.stream.listen(_router.push);

    var appMeta = ref.read(persistenceProvider).appMeta;
    if (appMeta.lastAppVersion != appVersion) {
      appMeta = AppMeta(
        lastAppVersion: appVersion,
        lastNotificationId: appMeta.lastNotificationId,
        lastBackgroundJob: appMeta.lastBackgroundJob,
      );

      WidgetsBinding.instance.addPostFrameCallback(
        (_) => ref.read(persistenceProvider.notifier).setAppMeta(appMeta),
      );

      BackgroundHandler.requestPermissionForNotifications();
    }
  }

  @override
  void dispose() {
    _notificationSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(viewerIdProvider);
    final options = ref.watch(persistenceProvider.select((s) => s.options));
    final platformBrightness = MediaQuery.platformBrightnessOf(context);
    final viewSize = MediaQuery.sizeOf(context);

    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        Color lightSeed = (options.themeBase ?? ThemeBase.default_).seed;
        Color darkSeed = lightSeed;
        if (lightDynamic != null && darkDynamic != null) {
          _systemLightPrimaryColor = lightDynamic.primary;
          _systemDarkPrimaryColor = darkDynamic.primary;

          // The system primary colors must be cached,
          // so they can later be used in the settings.
          final notifier = ref.watch(persistenceProvider.notifier);

          // A provider can't be modified during build,
          // so it's done asynchronously as a workaround.
          Future(
            () => notifier.cacheSystemPrimaryColors((
              lightPrimaryColor: _systemLightPrimaryColor,
              darkPrimaryColor: _systemDarkPrimaryColor,
            )),
          );

          if (options.themeBase == null &&
              _systemLightPrimaryColor != null &&
              _systemDarkPrimaryColor != null) {
            lightSeed = _systemLightPrimaryColor!;
            darkSeed = _systemDarkPrimaryColor!;
          }
        }

        Color? lightBackground;
        Color? darkBackground;
        if (options.highContrast) {
          lightBackground = Colors.white;
          darkBackground = Colors.black;
        }

        final lightScheme = ColorScheme.fromSeed(
          seedColor: lightSeed,
          brightness: Brightness.light,
        ).copyWith(surface: lightBackground);
        final darkScheme = ColorScheme.fromSeed(
          seedColor: darkSeed,
          brightness: Brightness.dark,
        ).copyWith(surface: darkBackground);

        final isDark = options.themeMode == ThemeMode.system
            ? platformBrightness == Brightness.dark
            : options.themeMode == ThemeMode.dark;

        final ColorScheme scheme;
        final Brightness overlayBrightness;
        if (isDark) {
          scheme = darkScheme;
          overlayBrightness = Brightness.light;
        } else {
          scheme = lightScheme;
          overlayBrightness = Brightness.dark;
        }

        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarBrightness: scheme.brightness,
          statusBarIconBrightness: overlayBrightness,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarContrastEnforced: false,
          systemNavigationBarIconBrightness: overlayBrightness,
        ));

        return MaterialApp.router(
          debugShowCheckedModeBanner: false,
          title: 'AnimeShin',
          theme: Theming.generateThemeData(lightScheme),
          darkTheme: Theming.generateThemeData(darkScheme),
          themeMode: options.themeMode,
          routerConfig: _router,
          builder: (context, child) {
            final directionality = Directionality.of(context);

            final theming = Theming(
              formFactor: viewSize.width < Theming.windowWidthMedium
                  ? FormFactor.phone
                  : FormFactor.tablet,
              rightButtonOrientation:
                  options.buttonOrientation == ButtonOrientation.auto
                      ? directionality == TextDirection.ltr
                      : options.buttonOrientation == ButtonOrientation.right,
            );

            // Override the [textScaleFactor], because some devices apply
            // too high of a factor and it breaks the app visually.
            final mediaQuery = MediaQuery.of(context);
            final scale = mediaQuery.textScaler.clamp(
              minScaleFactor: 0.8,
              maxScaleFactor: 1,
            );

            return Theme(
              data: Theme.of(context).copyWith(extensions: [theming]),
              child: MediaQuery(
                data: mediaQuery.copyWith(textScaler: scale),
                child: child!,
              ),
            );
          },
        );
      },
    );
  }
}
