import 'package:equatable/equatable.dart';

import '../../nodes/model/node.dart';

/// An assignment candidate extracted from syllabus text, awaiting user
/// approval. Never persisted — only materialized into [Node]s via
/// [toNode] after the user checks it off in the review sheet.
class SyllabusDraft extends Equatable {
  final String title;
  final DateTime? due;
  final String? notes;

  const SyllabusDraft({required this.title, this.due, this.notes});

  SyllabusDraft copyWith({String? title, DateTime? due, bool clearDue = false, String? notes, bool clearNotes = false}) {
    return SyllabusDraft(
      title: title ?? this.title,
      due: clearDue ? null : (due ?? this.due),
      notes: clearNotes ? null : (notes ?? this.notes),
    );
  }

  /// Materializes an approved draft as a manual (non-imported) node.
  Node toNode({String? classId, String? classLabel}) {
    final trimmedNotes = notes?.trim();
    return Node(
      id: 'node:${DateTime.now().microsecondsSinceEpoch}:${title.hashCode & 0xffffff}',
      title: title.trim(),
      notes: trimmedNotes == null || trimmedNotes.isEmpty ? null : trimmedNotes,
      createdAt: DateTime.now(),
      schedule: due == null ? null : ScheduleFacet(due: due),
      classId: classId,
      classLabel: classLabel,
    );
  }

  factory SyllabusDraft.fromJson(Map<String, dynamic> json) {
    final title = (json['title'] as String? ?? '').trim();
    DateTime? due;
    final rawDue = json['due'];
    if (rawDue is String && rawDue.isNotEmpty) {
      due = DateTime.tryParse(rawDue);
    }
    final notes = (json['notes'] as String?)?.trim();
    return SyllabusDraft(
      title: title,
      due: due,
      notes: notes == null || notes.isEmpty ? null : notes,
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'due': due?.toIso8601String(),
        'notes': notes,
      };

  @override
  List<Object?> get props => [title, due, notes];
}
