import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NavigationCubit', () {
    test('initial state is home', () {
      final navigationCubit = NavigationCubit();
      expect(navigationCubit.state, equals(PlannerPage.home));
    });

    test('setPage emits the correct page', () {
      final navigationCubit = NavigationCubit();
      navigationCubit.setPage(PlannerPage.calendar);
      expect(navigationCubit.state, equals(PlannerPage.calendar));
    });
  });
}
