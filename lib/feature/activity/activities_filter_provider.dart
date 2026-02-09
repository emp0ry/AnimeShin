import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/feature/activity/activities_filter_model.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';

final activitiesFilterProvider = NotifierProvider.autoDispose
    .family<ActivitiesFilterNotifier, ActivitiesFilter, int?>(
  (arg) => ActivitiesFilterNotifier(arg),
);

class ActivitiesFilterNotifier extends Notifier<ActivitiesFilter> {
  ActivitiesFilterNotifier(this.arg);

  final int? arg;

  @override
  ActivitiesFilter build() {
    final userId = arg;

    return userId == null
        ? ref.watch(persistenceProvider.select((s) => s.homeActivitiesFilter))
        : UserActivitiesFilter(ActivityType.values, userId);
  }

  @override
  set state(ActivitiesFilter newState) {
    if (state == newState) return;

    switch (newState) {
      case HomeActivitiesFilter homeActivitiesFilter:
        ref
            .read(persistenceProvider.notifier)
            .setHomeActivitiesFilter(homeActivitiesFilter);
      case UserActivitiesFilter _:
        super.state = newState;
    }
  }
}
