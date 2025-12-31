import 'package:bloc/bloc.dart';

/// Simple Cubit that holds the current page index for navigation.
class NavigationCubit extends Cubit<int> {
  NavigationCubit([super.initialIndex = 0]);
  // var history = [Page.home];
  /// Set the current page index.
  void setPage(int page) => emit(page);
  // TODO implement page history navigation
}
