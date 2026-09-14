import 'package:equatable/equatable.dart';

/// Whether an expense has been fulfilled or is still pending.
enum ExpenseStatus {
  /// A future projection — not yet due.
  projected,

  /// The expense period has arrived but no transaction matched yet.
  due,

  /// Linked to a real transaction; fully settled.
  paid,
}

/// The core expense model with Unity prefab-style inheritance.
///
/// An expense can optionally inherit field values from a parent expense
/// (e.g. a recurring rule generates a "template" expense, and each
/// occurrence is a child that inherits name, amount, category, etc.).
///
/// Individual fields can be **overridden** on a child without breaking
/// inheritance on other fields.  When linked to a real Plaid transaction,
/// the expense becomes **concrete** and severs all inheritance.
class Expense extends Equatable {
  final String id;
  final String name;
  final double amount; // negative = spending, positive = income
  final DateTime date;
  final String? category;
  final String? notes;

  // ── Prefab inheritance ──────────────────────────────────────────────

  /// ID of the parent expense this was cloned from (null = root).
  final String? parentExpenseId;

  /// ID of the recurring rule that generated this expense (if any).
  final String? sourceRuleId;

  /// The set of field names that have been explicitly overridden on this
  /// instance and should NOT inherit from the parent.
  final Set<String> overriddenFields;

  // ── Concrete state ──────────────────────────────────────────────────

  /// When non-null, this expense is linked to a real Plaid transaction
  /// and all inheritance is severed.
  final String? linkedTransactionId;

  /// Convenience getter — true when linked to a real transaction.
  bool get isConcrete => linkedTransactionId != null;

  final ExpenseStatus status;
  final List<String> tagIds;

  const Expense({
    required this.id,
    required this.name,
    required this.amount,
    required this.date,
    this.category,
    this.notes,
    this.parentExpenseId,
    this.sourceRuleId,
    this.overriddenFields = const {},
    this.linkedTransactionId,
    this.status = ExpenseStatus.projected,
    this.tagIds = const [],
  });

  // ── Copy / mutation helpers ─────────────────────────────────────────

  Expense copyWith({
    String? id,
    String? name,
    double? amount,
    DateTime? date,
    String? category,
    String? notes,
    String? parentExpenseId,
    String? sourceRuleId,
    Set<String>? overriddenFields,
    String? linkedTransactionId,
    bool clearLinkedTransaction = false,
    ExpenseStatus? status,
    List<String>? tagIds,
  }) {
    return Expense(
      id: id ?? this.id,
      name: name ?? this.name,
      amount: amount ?? this.amount,
      date: date ?? this.date,
      category: category ?? this.category,
      notes: notes ?? this.notes,
      parentExpenseId: parentExpenseId ?? this.parentExpenseId,
      sourceRuleId: sourceRuleId ?? this.sourceRuleId,
      overriddenFields: overriddenFields ?? this.overriddenFields,
      linkedTransactionId:
          clearLinkedTransaction ? null : (linkedTransactionId ?? this.linkedTransactionId),
      status: status ?? this.status,
      tagIds: tagIds ?? this.tagIds,
    );
  }

  /// Mark a single field as overridden with a new value.
  /// Returns a new [Expense] with the field updated and tracked.
  Expense overrideField(String fieldName, dynamic value) {
    final newOverrides = {...overriddenFields, fieldName};
    switch (fieldName) {
      case 'name':
        return copyWith(name: value as String, overriddenFields: newOverrides);
      case 'amount':
        return copyWith(amount: value as double, overriddenFields: newOverrides);
      case 'date':
        return copyWith(date: value as DateTime, overriddenFields: newOverrides);
      case 'category':
        return copyWith(category: value as String?, overriddenFields: newOverrides);
      case 'notes':
        return copyWith(notes: value as String?, overriddenFields: newOverrides);
      default:
        return copyWith(overriddenFields: newOverrides);
    }
  }

  /// Revert a field override so it re-inherits from the parent.
  /// The actual value resolution happens in the cubit (which has
  /// access to the parent expense).
  Expense revertField(String fieldName) {
    final newOverrides = {...overriddenFields}..remove(fieldName);
    return copyWith(overriddenFields: newOverrides);
  }

  /// Sever all inheritance by linking to a real transaction.
  Expense makeConcrete(String transactionId) {
    return copyWith(
      linkedTransactionId: transactionId,
      status: ExpenseStatus.paid,
      // All fields become "owned" — overriddenFields becomes irrelevant
      overriddenFields: {'name', 'amount', 'date', 'category', 'notes'},
    );
  }

  /// Split this expense into two: one for [splitAmount] and one for the
  /// remainder.  Returns `[reduced, remainder]`.
  ///
  /// The original expense keeps its ID with a reduced amount; the
  /// remainder gets a new ID.
  List<Expense> subdivide(double splitAmount) {
    final remainder = amount.abs() - splitAmount.abs();
    final isNeg = amount < 0;

    final reduced = copyWith(
      amount: isNeg ? -splitAmount.abs() : splitAmount.abs(),
      overriddenFields: {...overriddenFields, 'amount'},
    );

    final leftover = Expense(
      id: '${id}_rem_${DateTime.now().millisecondsSinceEpoch}',
      name: '$name (remainder)',
      amount: isNeg ? -remainder.abs() : remainder.abs(),
      date: date,
      category: category,
      parentExpenseId: parentExpenseId,
      sourceRuleId: sourceRuleId,
      status: status,
      tagIds: tagIds,
    );

    return [reduced, leftover];
  }

  // ── Serialization ───────────────────────────────────────────────────

  factory Expense.fromJson(Map<String, dynamic> json) {
    return Expense(
      id: json['id'] as String,
      name: json['name'] as String,
      amount: (json['amount'] as num).toDouble(),
      date: DateTime.parse(json['date'] as String),
      category: json['category'] as String?,
      notes: json['notes'] as String?,
      parentExpenseId: json['parentExpenseId'] as String?,
      sourceRuleId: json['sourceRuleId'] as String?,
      overriddenFields:
          (json['overriddenFields'] as List<dynamic>?)?.cast<String>().toSet() ?? {},
      linkedTransactionId: json['linkedTransactionId'] as String?,
      status: ExpenseStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => ExpenseStatus.projected,
      ),
      tagIds: _tagIdsFromJson(json['tagIds']),
    );
  }

  static List<String> _tagIdsFromJson(Object? raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final item in raw) {
      if (item is String && item.isNotEmpty) out.add(item);
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'amount': amount,
        'date': date.toIso8601String(),
        'category': category,
        'notes': notes,
        'parentExpenseId': parentExpenseId,
        'sourceRuleId': sourceRuleId,
        'overriddenFields': overriddenFields.toList(),
        'linkedTransactionId': linkedTransactionId,
        'status': status.name,
        'tagIds': tagIds,
      };

  @override
  List<Object?> get props => [
        id,
        name,
        amount,
        date,
        category,
        notes,
        parentExpenseId,
        sourceRuleId,
        overriddenFields,
        linkedTransactionId,
        status,
        tagIds,
      ];
}
