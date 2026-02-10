import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ionicons/ionicons.dart';
import 'package:animeshin/extension/scroll_controller_extension.dart';
import 'package:animeshin/extension/snack_bar_extension.dart';
import 'package:animeshin/feature/settings/settings_model.dart';
import 'package:animeshin/feature/settings/settings_provider.dart';
import 'package:animeshin/feature/settings/settings_app_view.dart';
import 'package:animeshin/feature/settings/settings_modules_view.dart';
import 'package:animeshin/feature/settings/settings_content_view.dart';
import 'package:animeshin/feature/settings/settings_notifications_view.dart';
import 'package:animeshin/feature/settings/settings_about_view.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/util/theming.dart';
import 'package:animeshin/widget/layout/adaptive_scaffold.dart';
import 'package:animeshin/widget/layout/hiding_floating_action_button.dart';
import 'package:animeshin/widget/layout/constrained_view.dart';
import 'package:animeshin/widget/layout/top_bar.dart';
import 'package:animeshin/widget/loaders.dart';

class SettingsView extends ConsumerStatefulWidget {
  const SettingsView();

  @override
  ConsumerState<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends ConsumerState<SettingsView>
    with SingleTickerProviderStateMixin {
  late final _tabCtrl = TabController(length: 5, vsync: this);
    final _scrollCtrlApp = ScrollController();
    final _scrollCtrlContent = ScrollController();
    final _scrollCtrlModules = ScrollController();
  final _scrollCtrlNotifications = ScrollController();
  final _scrollCtrlAbout = ScrollController();
  AsyncValue<Settings>? _settings;

  ScrollController get _activeScrollCtrl => switch (_tabCtrl.index) {
        0 => _scrollCtrlApp,
      1 => _scrollCtrlContent,
      2 => _scrollCtrlModules,
        3 => _scrollCtrlNotifications,
        _ => _scrollCtrlAbout,
      };

  @override
  void initState() {
    super.initState();
    _tabCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _scrollCtrlApp.dispose();
    _scrollCtrlContent.dispose();
    _scrollCtrlModules.dispose();
    _scrollCtrlNotifications.dispose();
    _scrollCtrlAbout.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewerId = ref.watch(viewerIdProvider);
    if (viewerId == null) {
      _settings = null;
    } else {
      _settings ??= ref.watch(settingsProvider).whenData((data) => data.copy());

      ref.listen(
        settingsProvider,
        (_, s) => s.whenOrNull(
          loading: () => _settings = const AsyncValue.loading(),
          data: (data) => _settings = AsyncValue.data(data.copy()),
          error: (error, _) => SnackBarExtension.show(
            context,
            error.toString(),
          ),
        ),
      );
    }

    final tabs = [
      ConstrainedView(padded: false, child: SettingsAppSubview(_scrollCtrlApp)),
      switch (_settings) {
        null => const Center(
            child: Padding(
              padding: Theming.paddingAll,
              child: Text('Log in to view content settings'),
            ),
          ),
        AsyncData(:final value) =>
          SettingsContentSubview(_scrollCtrlContent, value),
        AsyncError(:final error) => Center(
            child: Padding(
              padding: Theming.paddingAll,
              child: Text('Failed to load: ${error.toString()}'),
            ),
          ),
        _ => const Center(child: Loader()),
      },
      ConstrainedView(padded: false, child: SettingsModulesSubview(_scrollCtrlModules)),
      switch (_settings) {
        null => const Center(
            child: Padding(
              padding: Theming.paddingAll,
              child: Text('Log in to view notification settings'),
            ),
          ),
        AsyncData(:final value) => SettingsNotificationsSubview(
            _scrollCtrlNotifications,
            value,
          ),
        AsyncError(:final error) => Center(
            child: Padding(
              padding: Theming.paddingAll,
              child: Text('Failed to load: ${error.toString()}'),
            ),
          ),
        _ => const Center(child: Loader()),
      },
      ConstrainedView(padded: false, child: SettingsAboutSubview(_scrollCtrlAbout)),
    ];

    final floatingAction = switch (_settings) {
      AsyncData(:final value) => HidingFloatingActionButton(
          key: const Key('save'),
          scrollCtrl: _activeScrollCtrl,
          child: _SaveButton(
            () => ref.read(settingsProvider.notifier).updateSettings(value),
          ),
        ),
      _ => null,
    };

    return AdaptiveScaffold(
      topBar: PreferredSize(
        preferredSize: const Size.fromHeight(Theming.normalTapTarget),
        child: Row(
          children: [
            const SizedBox(width: 8),
            Expanded(
              child: TopBarAnimatedSwitcher(
                switch (_tabCtrl.index) {
                  0 => const TopBar(key: Key('0'), title: ' App'),
                  1 => const TopBar(key: Key('1'), title: ' Content'),
                  2 => const TopBar(key: Key('2'), title: ' Modules'),
                  3 => const TopBar(key: Key('3'), title: ' Notifications'),
                  _ => const TopBar(key: Key('4'), title: ' About'),
                },
              ),
            ),
          ],
        ),
      ),
      floatingAction: floatingAction,
      navigationConfig: NavigationConfig(
        selected: _tabCtrl.index,
        onSame: (_) => _activeScrollCtrl.scrollToTop(),
        onChanged: (i) => _tabCtrl.index = i,
        items: const {
          'App': Ionicons.color_palette_outline,
          'Content': Ionicons.tv_outline,
          'Modules': Ionicons.extension_puzzle_outline,
          'Notifications': Ionicons.notifications_outline,
          'About': Ionicons.information_outline,
        },
      ),
      child: TabBarView(
        controller: _tabCtrl,
        physics: const ClampingScrollPhysics(),
        children: tabs,
      ),
    );
  }
}

class _SaveButton extends StatefulWidget {
  const _SaveButton(this.onTap) : super(key: const Key('saveSettings'));

  final Future<void> Function() onTap;

  @override
  State<_SaveButton> createState() => __SaveButtonState();
}

class __SaveButtonState extends State<_SaveButton> {
  var _hidden = false;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      tooltip: 'Save Settings',
      onPressed: _hidden
          ? null
          : () async {
              setState(() => _hidden = true);
              await widget.onTap();
              setState(() => _hidden = false);
            },
      child: _hidden
          ? const Icon(Ionicons.time_outline)
          : const Icon(Ionicons.save_outline),
    );
  }
}
