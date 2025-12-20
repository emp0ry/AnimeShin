import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/util/graphql.dart';
import 'package:animeshin/feature/tag/tag_model.dart';
import 'package:animeshin/feature/viewer/repository_provider.dart';

final tagsProvider = FutureProvider(
  (ref) async => TagCollection(
    await ref.read(repositoryProvider).request(GqlQuery.genresAndTags),
  ),
);
