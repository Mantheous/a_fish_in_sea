import 'package:equatable/equatable.dart';

/// The type of source that produced this display row.
enum EntryType {
  /// A real bank transaction from Plaid.
  transaction,

  /// A user-created expense (predicted or concrete).
  expense,

  /// An auto-generated projection from a recurring rule.
  recurringProjection,
}

/// Whether the entry represents real or projected data.
enum EntryStatus { confirmed, projected, due }

/// A single computed display row in the waterfall ledger.
///
/// [LedgerEntry] is NOT persisted — it is rebuilt from the underlying
/// [Transaction], [Expense], and [RecurringRule] data every time the
/// waterfall is refreshed.
class LedgerEntry extends Equatable {
  /// ID of the source object (Transaction.id, Expense.id, etc.).
  final String sourceId;

  final String name;
  final double amount;
  final DateTime date;
  final EntryType type;
  final EntryStatus status;
  final String? category;

  /// Which budget this entry falls under (for display).
  final String? budgetName;

  /// Computed running balance (set by the waterfall engine).
  final double runningBalance;

  /// Human-readable label like "3 days", "2 months", "Past".
  final String timeUntilLabel;

  /// Whether this entry is linked to a transaction (for expenses).
  final bool isConcrete;

  const LedgerEntry({
    required this.sourceId,
    required this.name,
    required this.amount,
    required this.date,
    required this.type,
    this.status = EntryStatus.projected,
    this.category,
    this.budgetName,
    this.runningBalance = 0.0,
    this.timeUntilLabel = '',
    this.isConcrete = false,
  });

  LedgerEntry copyWith({
    double? runningBalance,
    String? timeUntilLabel,
  }) {
    return LedgerEntry(
      sourceId: sourceId,
      name: name,
      amount: amount,
      date: date,
      type: type,
      status: status,
      category: category,
      budgetName: budgetName,
      runningBalance: runningBalance ?? this.runningBalance,
      timeUntilLabel: timeUntilLabel ?? this.timeUntilLabel,
      isConcrete: isConcrete,
    );
  }

  @override
  List<Object?> get props => [
        sourceId,
        name,
        amount,
        date,
        type,
        status,
        category,
        budgetName,
        runningBalance,
        timeUntilLabel,
        isConcrete,
      ];
}
