import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/feature/review/review_models.dart';

final reviewsFilterProvider = NotifierProvider.autoDispose
    .family<ReviewsFilterNotifier, ReviewsFilter, int>(
  (arg) => ReviewsFilterNotifier(arg),
);

class ReviewsFilterNotifier extends Notifier<ReviewsFilter> {
  ReviewsFilterNotifier(this.arg);

  final int arg;

  @override
  ReviewsFilter build() => const ReviewsFilter();

  @override
  set state(ReviewsFilter newState) => super.state = newState;
}
