import 'package:hydrated_bloc/hydrated_bloc.dart';
import '../model/expense.dart';

class ExpensesCubit extends HydratedCubit<List<Expense>> {
  ExpensesCubit() : super([]);

  void addExpense(Expense expense) => emit(state + [expense]);

  void clean() => emit([]);

  @override
  List<Expense>? fromJson(Map<String, dynamic> json) {
    final list = json['expenses'] as List<dynamic>?;
    return list?.map((e) => Expense.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Map<String, dynamic> toJson(List<Expense> state) {
    return {'expenses': state.map((e) => e.toJson()).toList()};
  }
}