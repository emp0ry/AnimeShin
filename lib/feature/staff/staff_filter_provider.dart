import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/feature/staff/staff_filter_model.dart';

final staffFilterProvider =
    NotifierProvider.autoDispose.family<StaffFilterNotifier, StaffFilter, int>(
  (arg) => StaffFilterNotifier(arg),
);

class StaffFilterNotifier extends Notifier<StaffFilter> {
  StaffFilterNotifier(this.arg);

  final int arg;

  @override
  StaffFilter build() => StaffFilter();

  @override
  set state(StaffFilter newState) => super.state = newState;
}
