import 'dart:io';
import 'package:equatable/equatable.dart';

/// An immutable bank transaction imported from Plaid.
///
/// Transactions are the raw financial data from the user's bank account.
/// They are never modified after import — the user interface only changes
/// how transactions are *interpreted* (i.e. which expense they map to and
/// how they affect the budget).
class Transaction extends Equatable {
  /// Plaid's unique transaction ID.
  final String id;

  /// Plaid account this transaction belongs to.
  final String accountId;

  /// Transaction amount.  Plaid uses positive = debit (money leaving),
  /// negative = credit (money arriving).  We normalise to:
  ///   negative = spending, positive = income.
  final double amount;

  /// Date the transaction posted.
  final DateTime date;

  /// Merchant name or transaction description from the bank.
  final String name;

  /// Plaid's auto-detected category (e.g. "Food and Drink").
  final String? category;

  /// Whether the transaction is still pending at the bank.
  final bool pending;

  /// The ID of the [Expense] this transaction has been assigned to.
  /// This is the *only* mutable field — set by the user during
  /// reconciliation.
  final String? assignedExpenseId;

  const Transaction({
    required this.id,
    required this.accountId,
    required this.amount,
    required this.date,
    required this.name,
    this.category,
    this.pending = false,
    this.assignedExpenseId,
  });

  /// Whether this transaction has been reconciled with an expense.
  bool get isAssigned => assignedExpenseId != null;

  Transaction copyWith({
    String? assignedExpenseId,
    bool clearAssignment = false,
  }) {
    return Transaction(
      id: id,
      accountId: accountId,
      amount: amount,
      date: date,
      name: name,
      category: category,
      pending: pending,
      assignedExpenseId:
          clearAssignment ? null : (assignedExpenseId ?? this.assignedExpenseId),
    );
  }

  // ── Serialization ───────────────────────────────────────────────────

  /// Create a [Transaction] from a Plaid API JSON response.
  factory Transaction.fromPlaid(Map<String, dynamic> json) {
    // Plaid amounts: positive = money leaving account (debit),
    // negative = money entering (credit).  We flip the sign so that
    // spending is negative and income is positive (matching our
    // internal convention).
    final plaidAmount = (json['amount'] as num).toDouble();
    return Transaction(
      id: json['transaction_id'] as String,
      accountId: json['account_id'] as String,
      amount: -plaidAmount, // flip Plaid convention
      date: _parseDate(json['date'] as String),
      name: json['name'] as String? ?? json['merchant_name'] as String? ?? 'Unknown',
      category: (json['category'] as List<dynamic>?)?.join(' > '),
      pending: json['pending'] as bool? ?? false,
    );
  }

  /// Create a [Transaction] from local persistence JSON.
  factory Transaction.fromJson(Map<String, dynamic> json) {
    return Transaction(
      id: json['id'] as String,
      accountId: json['accountId'] as String,
      amount: (json['amount'] as num).toDouble(),
      date: DateTime.parse(json['date'] as String),
      name: json['name'] as String,
      category: json['category'] as String?,
      pending: json['pending'] as bool? ?? false,
      assignedExpenseId: json['assignedExpenseId'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'accountId': accountId,
        'amount': amount,
        'date': date.toIso8601String(),
        'name': name,
        'category': category,
        'pending': pending,
        'assignedExpenseId': assignedExpenseId,
      };

  @override
  List<Object?> get props => [
        id,
        accountId,
        amount,
        date,
        name,
        category,
        pending,
        assignedExpenseId,
      ];

  static DateTime _parseDate(String dateStr) {
    try {
      return DateTime.parse(dateStr);
    } catch (_) {
      try {
        return HttpDate.parse(dateStr);
      } catch (_) {
        // Fallback if both fail
        return DateTime.now();
      }
    }
  }
}
