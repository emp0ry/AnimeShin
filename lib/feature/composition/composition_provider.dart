import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/extension/string_extension.dart';
import 'package:animeshin/util/graphql.dart';
import 'package:animeshin/feature/composition/composition_model.dart';
import 'package:animeshin/feature/viewer/repository_provider.dart';

final compositionProvider = AsyncNotifierProvider.autoDispose
    .family<CompositionNotifier, Composition, CompositionTag>(
  (arg) => CompositionNotifier(arg),
);

class CompositionNotifier extends AsyncNotifier<Composition> {
  CompositionNotifier(this.arg);

  final CompositionTag arg;

  @override
  FutureOr<Composition> build() async {
    if (arg.id == null) {
      return switch (arg) {
        MessageActivityCompositionTag _ => PrivateComposition('', false),
        _ => Composition(''),
      };
    }

    switch (arg) {
      case StatusActivityCompositionTag(id: var id):
        final data = await ref
            .read(repositoryProvider)
            .request(GqlQuery.activityComposition, {'id': id});
        return Composition(data['Activity']['text']);
      case MessageActivityCompositionTag(id: var id):
        final data = await ref
            .read(repositoryProvider)
            .request(GqlQuery.activityComposition, {'id': id});
        return Composition(data['Activity']['message']);
      case ActivityReplyCompositionTag(id: var id):
        final data = await ref
            .read(repositoryProvider)
            .request(GqlQuery.activityReplyComposition, {'id': id});
        return Composition(data['ActivityReply']['text']);
      case CommentCompositionTag(id: var id):
        final data = await ref
            .read(repositoryProvider)
            .request(GqlQuery.commentComposition, {'id': id});
        return Composition(_findComment(data['ThreadComment'][0]));
    }
  }

  /// The API always returns the root comment,
  /// so we search for the target comment with DFS.
  String _findComment(Map<String, dynamic> map) {
    if (map['id'] == arg.id) {
      return map['comment'] ?? '';
    }

    for (final c in map['childComments'] ?? const []) {
      final comment = _findComment(c);
      if (comment != '') return comment;
    }

    return '';
  }

  Future<AsyncValue<Map<String, dynamic>>> save() async {
    final value = state.asData?.value;
    if (value == null) return const AsyncValue.loading();

    return AsyncValue.guard(() async {
      switch (arg) {
        case StatusActivityCompositionTag(id: var id):
          final data = await ref.read(repositoryProvider).request(
            GqlMutation.saveStatusActivity,
            {
              if (id != null) 'id': id,
              'text': value.text.withParsedEmojis,
            },
          );
          return data['SaveTextActivity'];
        case MessageActivityCompositionTag(id: var id, recipientId: var rcpId):
          final data = await ref.read(repositoryProvider).request(
            GqlMutation.saveMessageActivity,
            {
              if (id != null) 'id': id,
              'text': value.text.withParsedEmojis,
              'recipientId': rcpId,
              if (value is PrivateComposition) 'isPrivate': value.isPrivate,
            },
          );
          return data['SaveMessageActivity'];
        case ActivityReplyCompositionTag(id: var id, activityId: var actId):
          final data = await ref.read(repositoryProvider).request(
            GqlMutation.saveActivityReply,
            {
              if (id != null) 'id': id,
              'text': value.text.withParsedEmojis,
              'activityId': actId,
            },
          );
          return data['SaveActivityReply'];
        case CommentCompositionTag(
            id: var id,
            threadId: var threadId,
            parentCommentId: var parentCommentId,
          ):
          final data = await ref.read(repositoryProvider).request(
            GqlMutation.saveComment,
            {
              if (id != null) 'id': id,
              'text': value.text.withParsedEmojis,
              'threadId': threadId,
              if (parentCommentId != null) 'parentCommentId': parentCommentId,
            },
          );
          return data['SaveThreadComment'];
      }
    });
  }
}
