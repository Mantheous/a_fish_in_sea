import 'package:bloc/bloc.dart';

enum PlannerPage { home, calendar, tasks, finances, settings }

class NavigationCubit extends Cubit<PlannerPage> {
  NavigationCubit() : super(PlannerPage.home);

  void setPage(PlannerPage page) => emit(page);
}
