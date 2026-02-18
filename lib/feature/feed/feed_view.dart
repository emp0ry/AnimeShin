import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/feature/activity/activities_provider.dart';
import 'package:animeshin/feature/activity/activities_view.dart';
import 'package:animeshin/feature/feed/feed_floating_action.dart';
import 'package:animeshin/feature/feed/feed_top_bar.dart';
import 'package:animeshin/util/paged_controller.dart';
import 'package:animeshin/widget/layout/adaptive_scaffold.dart';
import 'package:animeshin/widget/layout/hiding_floating_action_button.dart';
import 'package:animeshin/widget/layout/top_bar.dart';

class FeedView extends ConsumerStatefulWidget {
  const FeedView({super.key});

  @override
  ConsumerState<FeedView> createState() => _FeedViewState();
}

class _FeedViewState extends ConsumerState<FeedView> {
  late final _scrollCtrl = PagedController(
    loadMore: () => ref.read(activitiesProvider(null).notifier).fetch(),
  );

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final floatingAction = HidingFloatingActionButton(
      key: const Key('feed'),
      scrollCtrl: _scrollCtrl,
      child: FeedFloatingAction(ref),
    );

    return AdaptiveScaffold(
      topBar: const TopBar(
        title: 'Feed',
        trailing: [
          FeedTopBarTrailingContent(),
        ],
      ),
      floatingAction: floatingAction,
      child: ActivitiesSubView(null, _scrollCtrl),
    );
  }
}
