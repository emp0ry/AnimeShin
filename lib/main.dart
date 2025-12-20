import 'dart:async';
import 'dart:io' show Platform;

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
import 'package:animeshin/util/theming.dart';
import 'package:hive_flutter/hive_flutter.dart'; // For Hive.initFlutter()
import 'package:timezone/data/latest.dart' as tz;

final _notificationCtrl = StreamController<String>.broadcast();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

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

  // Initialize Hive (required for Hive.openBox)
  await Hive.initFlutter();

  await storage.write(key: 'probe', value: DateTime.now().toIso8601String());
  final ok = await storage.read(key: 'probe');
  debugPrint('secure storage probe: $ok');

  // === Desktop window size persistence ===
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();

    await Hive.openBox('window_settings');
    var box = Hive.box('window_settings');

    // Get saved window size or use default
    final width = box.get('window_width', defaultValue: 1200.0);
    final height = box.get('window_height', defaultValue: 800.0);

    await windowManager.setSize(Size(width, height));
  }

  final container = ProviderContainer();
  await container.read(persistenceProvider.notifier).init();
  BackgroundHandler.init(_notificationCtrl);

  runApp(UncontrolledProviderScope(container: container, child: const _App()));

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
