import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/extension/future_extension.dart';
import 'package:animeshin/feature/user/user_model.dart';
import 'package:animeshin/feature/viewer/repository_provider.dart';
import 'package:animeshin/util/graphql.dart';

typedef UserTag = ({int? id, String? name});

UserTag idUserTag(int id) => (id: id, name: null);

UserTag nameUserTag(String name) => (id: null, name: name);

final userProvider =
    AsyncNotifierProvider.autoDispose.family<UserNotifier, User, UserTag>(
  (arg) => UserNotifier(arg),
);

class UserNotifier extends AsyncNotifier<User> {
  UserNotifier(this.arg);

  final UserTag arg;

  @override
  FutureOr<User> build() async {
    final data = await ref.read(repositoryProvider).request(
          GqlQuery.user,
          arg.id != null ? {'id': arg.id} : {'name': arg.name},
        );
    return User(data['User']);
  }

  Future<Object?> toggleFollow(int userId) {
    return ref.read(repositoryProvider).request(
      GqlMutation.toggleFollow,
      {'userId': userId},
    ).getErrorOrNull();
  }
}
