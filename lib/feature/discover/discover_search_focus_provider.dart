import 'package:flutter_riverpod/flutter_riverpod.dart';

/// When set to `true`, `HomeView` will focus the Discover search field
/// on the next frame (and then reset this flag back to `false`).
final requestDiscoverSearchFocusProvider = StateProvider<bool>((ref) => false);
