import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/feature/character/character_filter_model.dart';

final characterFilterProvider = NotifierProvider.autoDispose
    .family<CharacterFilterNotifier, CharacterFilter, int>(
  (arg) => CharacterFilterNotifier(arg),
);

class CharacterFilterNotifier extends Notifier<CharacterFilter> {
  CharacterFilterNotifier(this.arg);

  final int arg;

  @override
  CharacterFilter build() => CharacterFilter();

  @override
  set state(CharacterFilter newState) => super.state = newState;
}
