import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';

enum FeedKind { learningSuite, canvas, google, other }

extension FeedKindX on FeedKind {
  String get displayName => switch (this) {
        FeedKind.learningSuite => 'Learning Suite',
        FeedKind.canvas => 'Canvas',
        FeedKind.google => 'Google',
        FeedKind.other => 'Other',
      };
}

/// Deterministic color for a course label (e.g. "STAT 230-002" parsed
/// from Canvas titles) so a label always maps to the same palette color.
Color courseColor(String label) {
  var hash = 0;
  for (final code in label.codeUnits) {
    hash = (hash * 31 + code) & 0x7fffffff;
  }
  return Color(Feed.palette[hash % Feed.palette.length]);
}

/// Mutes any event color for calendar display: caps saturation and keeps
/// lightness in a mid range so Google's bright colors render dusty while
/// already-muted palette colors pass through unchanged. White event text
/// stays readable.
Color mutedCalendarColor(Color color) {
  final hsl = HSLColor.fromColor(color);
  final muted = hsl.withSaturation(
    hsl.saturation > 0.45 ? 0.45 : hsl.saturation,
  ).withLightness(hsl.lightness.clamp(0.42, 0.58));
  return muted.toColor();
}

class Feed extends Equatable {
  final String id;
  final String name;
  final String url;
  final FeedKind kind;
  final int colorValue;
  final bool enabled;
  final bool createTasks;
  final String? calendarId;
  final DateTime? lastSyncAt;
  final String? lastError;

  const Feed({
    required this.id,
    required this.name,
    required this.url,
    this.kind = FeedKind.other,
    this.colorValue = 0xFF6B8F8A,
    this.enabled = true,
    this.createTasks = true,
    this.calendarId,
    this.lastSyncAt,
    this.lastError,
  });

  Color get color => Color(colorValue);

  static const palette = <int>[
    0xFF6B8F8A,
    0xFF6A8FB5,
    0xFF8E7AAE,
    0xFFB2706B,
    0xFFB98A5A,
    0xFF7A9E7E,
    0xFF8B7D74,
    0xFF7E7AB8,
    0xFFB0768E,
    0xFF6AA2AD,
  ];

  static const _legacyPalette = <int, int>{
    0xFF00897B: 0xFF6B8F8A,
    0xFF1E88E5: 0xFF6A8FB5,
    0xFF8E24AA: 0xFF8E7AAE,
    0xFFE53935: 0xFFB2706B,
    0xFFFB8C00: 0xFFB98A5A,
    0xFF43A047: 0xFF7A9E7E,
    0xFF6D4C41: 0xFF8B7D74,
    0xFF5E35B1: 0xFF7E7AB8,
    0xFFD81B60: 0xFFB0768E,
    0xFF00ACC1: 0xFF6AA2AD,
  };

  static int migrateColorValue(int value) =>
      _legacyPalette[value] ?? value;

  Feed copyWith({
    String? name,
    String? url,
    FeedKind? kind,
    int? colorValue,
    bool? enabled,
    bool? createTasks,
    String? calendarId,
    bool clearCalendarId = false,
    DateTime? lastSyncAt,
    bool clearLastSyncAt = false,
    String? lastError,
    bool clearLastError = false,
  }) =>
      Feed(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        kind: kind ?? this.kind,
        colorValue: colorValue ?? this.colorValue,
        enabled: enabled ?? this.enabled,
        createTasks: createTasks ?? this.createTasks,
        calendarId:
            clearCalendarId ? null : (calendarId ?? this.calendarId),
        lastSyncAt: clearLastSyncAt ? null : (lastSyncAt ?? this.lastSyncAt),
        lastError: clearLastError ? null : (lastError ?? this.lastError),
      );

  factory Feed.fromJson(Map<String, dynamic> json) => Feed(
        id: json['id'] as String,
        name: json['name'] as String,
        url: json['url'] as String,
        kind: FeedKind.values.firstWhere(
          (k) => k.name == json['kind'],
          orElse: () => FeedKind.other,
        ),
        colorValue: migrateColorValue(
          json['colorValue'] as int? ?? 0xFF6B8F8A,
        ),
        enabled: json['enabled'] as bool? ?? true,
        createTasks: json['createTasks'] as bool? ?? true,
        calendarId: json['calendarId'] as String?,
        lastSyncAt: json['lastSyncAt'] == null
            ? null
            : DateTime.parse(json['lastSyncAt'] as String),
        lastError: json['lastError'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'kind': kind.name,
        'colorValue': colorValue,
        'enabled': enabled,
        'createTasks': createTasks,
        'calendarId': calendarId,
        'lastSyncAt': lastSyncAt?.toIso8601String(),
        'lastError': lastError,
      };

  @override
  List<Object?> get props => [
        id,
        name,
        url,
        kind,
        colorValue,
        enabled,
        createTasks,
        calendarId,
        lastSyncAt,
        lastError,
      ];
}
