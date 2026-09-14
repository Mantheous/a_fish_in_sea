import 'package:equatable/equatable.dart';

enum ReportStatus { attended, partial, missed, extra }

class ReportedEntry extends Equatable {
  final String id;
  final String? eventId;
  final String? placeId;
  final String title;
  final DateTime start;
  final DateTime end;
  final ReportStatus status;
  final bool auto;
  final int minutesAtPlace;
  final List<String> tagIds;

  const ReportedEntry({
    required this.id,
    this.eventId,
    this.placeId,
    required this.title,
    required this.start,
    required this.end,
    required this.status,
    this.auto = true,
    this.minutesAtPlace = 0,
    this.tagIds = const [],
  });

  ReportedEntry copyWith({
    String? title,
    String? placeId,
    bool clearPlaceId = false,
    DateTime? start,
    DateTime? end,
    ReportStatus? status,
    bool? auto,
    int? minutesAtPlace,
    List<String>? tagIds,
  }) =>
      ReportedEntry(
        id: id,
        eventId: eventId,
        placeId: clearPlaceId ? null : (placeId ?? this.placeId),
        title: title ?? this.title,
        start: start ?? this.start,
        end: end ?? this.end,
        status: status ?? this.status,
        auto: auto ?? this.auto,
        minutesAtPlace: minutesAtPlace ?? this.minutesAtPlace,
        tagIds: tagIds ?? this.tagIds,
      );

  factory ReportedEntry.fromJson(Map<String, dynamic> json) => ReportedEntry(
        id: json['id'] as String,
        eventId: json['eventId'] as String?,
        placeId: json['placeId'] as String?,
        title: json['title'] as String,
        start: DateTime.parse(json['start'] as String),
        end: DateTime.parse(json['end'] as String),
        status: ReportStatus.values.firstWhere(
          (e) => e.name == json['status'],
          orElse: () => ReportStatus.partial,
        ),
        auto: json['auto'] as bool? ?? true,
        minutesAtPlace: (json['minutesAtPlace'] as num?)?.toInt() ?? 0,
        tagIds: _tagIdsFromJson(json['tagIds']),
      );

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
        'eventId': eventId,
        'placeId': placeId,
        'title': title,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'status': status.name,
        'auto': auto,
        'minutesAtPlace': minutesAtPlace,
        'tagIds': tagIds,
      };

  @override
  List<Object?> get props => [
        id,
        eventId,
        placeId,
        title,
        start,
        end,
        status,
        auto,
        minutesAtPlace,
        tagIds
      ];
}
