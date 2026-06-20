import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NavigationCubit', () {
    test('initial state is 0', () {
      final navigationCubit = NavigationCubit();
      expect(navigationCubit.state, equals(0));
    });

    test('setPage emits the correct page index', () {
      final navigationCubit = NavigationCubit();
      navigationCubit.setPage(2);
      expect(navigationCubit.state, equals(2));
    });
  });
}
