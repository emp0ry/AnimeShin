import 'package:flutter/widgets.dart';
import 'package:animeshin/feature/forum/thread_item_list.dart';
import 'package:animeshin/feature/media/media_provider.dart';
import 'package:animeshin/widget/paged_view.dart';

class MediaThreadsSubview extends StatelessWidget {
  const MediaThreadsSubview({
    required this.id,
    required this.scrollCtrl,
    required this.analogClock,
  });

  final int id;
  final ScrollController scrollCtrl;
  final bool analogClock;

  @override
  Widget build(BuildContext context) {
    return PagedView(
      scrollCtrl: scrollCtrl,
      onRefresh: (invalidate) => invalidate(mediaThreadsProvider(id)),
      provider: mediaThreadsProvider(id),
      onData: (data) => ThreadItemList(data.items, analogClock),
    );
  }
}
