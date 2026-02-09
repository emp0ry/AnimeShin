import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/util/paged.dart';
import 'package:animeshin/util/theming.dart';
import 'package:animeshin/extension/snack_bar_extension.dart';
import 'package:animeshin/widget/layout/constrained_view.dart';
import 'package:animeshin/widget/loaders.dart';

typedef Invalidate = void Function(dynamic provider, {bool asReload});

class PagedView<T> extends StatelessWidget {
  const PagedView({
    required this.provider,
    required this.scrollCtrl,
    required this.onRefresh,
    required this.onData,
    this.padded = true,
  });


  final dynamic provider;

  /// If [scrollCtrl] is [PagedController], pagination will automatically work.
  final ScrollController scrollCtrl;

  /// The [invalidate] parameter is the method of [PagedView]'s [ref].
  /// The parameter is useful, because the parent widget
  /// may not have a [WidgetRef] at its disposal.
  final void Function(Invalidate invalidate) onRefresh;

  /// [onData] should return a sliver widget, displaying the items.
  final Widget Function(Paged<T>) onData;

  /// If [padded] is true, the result of [onData] will be padded.
  final bool padded;

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        ref.listen<AsyncValue<Paged<T>>>(
          provider,
          (_, s) => s.whenOrNull(
            error: (error, _) => SnackBarExtension.show(
              context,
              error.toString(),
            ),
          ),
        );

        final value = ref.watch(provider) as AsyncValue<Paged<T>>;

        return value.unwrapPrevious().when(
              loading: () => const Center(child: Loader()),
              error: (_, __) => CustomScrollView(
                physics: Theming.bouncyPhysics,
                slivers: [
                  SliverRefreshControl(
                    onRefresh: () => onRefresh(
                      (provider, {asReload = false}) => ref.invalidate(
                        provider,
                        asReload: asReload,
                      ),
                    ),
                  ),
                  const SliverFillRemaining(
                    child: Center(child: Text('Failed to load')),
                  ),
                ],
              ),
              data: (data) {
                return ConstrainedView(
                  padded: padded,
                  child: CustomScrollView(
                    physics: Theming.bouncyPhysics,
                    controller: scrollCtrl,
                    slivers: [
                      SliverRefreshControl(
                        onRefresh: () => onRefresh(
                          (provider, {asReload = false}) => ref.invalidate(
                            provider,
                            asReload: asReload,
                          ),
                        ),
                      ),
                      data.items.isEmpty
                          ? const SliverFillRemaining(
                              child: Center(child: Text('No results')),
                            )
                          : onData(data),
                      SliverFooter(loading: data.hasNext),
                    ],
                  ),
                );
              },
            );
      },
    );
  }
}
