import 'package:animeshin/feature/home/home_model.dart';
import 'package:animeshin/feature/home/home_tab_order.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ui order places Discover before Feed', () {
    expect(
      homeTabUiOrder,
      <HomeTab>[
        HomeTab.discover,
        HomeTab.anime,
        HomeTab.manga,
        HomeTab.feed,
        HomeTab.profile,
      ],
    );
  });

  test('ui index mapping round-trips for every tab', () {
    for (var i = 0; i < homeTabUiOrder.length; i++) {
      final tab = homeTabByUiIndex(i);
      expect(homeUiIndexByTab(tab), i);
    }
  });

  test('out-of-range ui index falls back to Discover', () {
    expect(homeTabByUiIndex(-1), HomeTab.discover);
    expect(homeTabByUiIndex(999), HomeTab.discover);
  });
}
