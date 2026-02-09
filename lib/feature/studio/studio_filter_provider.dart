import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/feature/studio/studio_filter_model.dart';

final studioFilterProvider = NotifierProvider.autoDispose
    .family<StudioFilterNotifier, StudioFilter, int>(
  (arg) => StudioFilterNotifier(arg),
);

class StudioFilterNotifier extends Notifier<StudioFilter> {
  StudioFilterNotifier(this.arg);

  final int arg;

  @override
  StudioFilter build() => StudioFilter();

  @override
  set state(StudioFilter newState) => super.state = newState;
}
