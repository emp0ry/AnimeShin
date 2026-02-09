import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/extension/future_extension.dart';
import 'package:animeshin/feature/review/review_models.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/feature/viewer/repository_provider.dart';
import 'package:animeshin/util/graphql.dart';

final reviewProvider =
    AsyncNotifierProvider.autoDispose.family<ReviewNotifier, Review, int>(
  (arg) => ReviewNotifier(arg),
);

class ReviewNotifier extends AsyncNotifier<Review> {
  ReviewNotifier(this.arg);

  final int arg;

  @override
  FutureOr<Review> build() async {
    final data = await ref
        .read(repositoryProvider)
        .request(GqlQuery.review, {'id': arg});

    final options = ref.watch(persistenceProvider.select((s) => s.options));

    return Review(data['Review'], options.imageQuality, options.analogClock);
  }

  Future<Object?> rate(bool? rating) {
    return ref.read(repositoryProvider).request(
      GqlMutation.rateReview,
      {
        'id': arg,
        'rating': rating == null
            ? 'NO_VOTE'
            : rating
                ? 'UP_VOTE'
                : 'DOWN_VOTE',
      },
    ).getErrorOrNull();
  }
}
