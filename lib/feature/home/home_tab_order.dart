import 'package:animeshin/feature/home/home_model.dart';

const List<HomeTab> homeTabUiOrder = <HomeTab>[
  HomeTab.discover,
  HomeTab.anime,
  HomeTab.manga,
  HomeTab.feed,
  HomeTab.profile,
];

HomeTab homeTabByUiIndex(int uiIndex) {
  if (uiIndex < 0 || uiIndex >= homeTabUiOrder.length) {
    return HomeTab.discover;
  }
  return homeTabUiOrder[uiIndex];
}

int homeUiIndexByTab(HomeTab tab) {
  final idx = homeTabUiOrder.indexOf(tab);
  return idx < 0 ? 0 : idx;
}
