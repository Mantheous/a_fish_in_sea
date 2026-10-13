import 'package:bloc/bloc.dart';

/// UI-facing demo-mode switch. Plain [Cubit] on purpose: entering demo must
/// never write to [HydratedBloc] storage (that would persist the fact that a
/// demo happened, and worse, interleave with the storage swap).
class DemoCubit extends Cubit<bool> {
  DemoCubit() : super(false);

  bool get isDemo => state;

  void entered() => emit(true);

  void exited() => emit(false);
}
