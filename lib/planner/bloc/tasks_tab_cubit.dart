import 'package:bloc/bloc.dart';

/// Remembers which Tasks tab (0 = To-Do, 1 = Homework) the user was last
/// on, so the calendar round-trip (Tasks → Calendar → Tasks) lands back on
/// the same tab instead of always resetting to To-Do.
///
/// In-memory only (not hydrated): UI chrome, no user data, so there is no
/// persistence schema to migrate and nothing for the data guardian to
/// audit. Provided above `MaterialApp` in main.dart so it survives page
/// switches (TasksPage itself is rebuilt on every navigation).
class TasksTabCubit extends Cubit<int> {
  TasksTabCubit() : super(0);

  void setTab(int index) {
    final clamped = index.clamp(0, 1);
    if (clamped != state) emit(clamped);
  }
}
