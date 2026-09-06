import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../model/planner_event.dart';

class GoogleCalendarInfo {
  final String id;
  final String summary;
  final bool primary;
  final String? accessRole;
  final int? colorValue;

  const GoogleCalendarInfo({
    required this.id,
    required this.summary,
    this.primary = false,
    this.accessRole,
    this.colorValue,
  });

  bool get canWrite => accessRole == 'writer' || accessRole == 'owner';

  factory GoogleCalendarInfo.fromJson(Map<String, dynamic> json) =>
      GoogleCalendarInfo(
        id: json['id'] as String,
        summary: (json['summary'] as String?)?.isNotEmpty == true
            ? json['summary'] as String
            : 'Calendar',
        primary: json['primary'] as bool? ?? false,
        accessRole: json['accessRole'] as String?,
        colorValue: parseCssColor(json['backgroundColor'] as String?),
      );
}

/// Serializes a DateTime the way Google requires: UTC values keep the
/// `Z` suffix, local values carry their numeric offset. A naive local
/// string (no offset) is rejected on insert with "Missing time zone
/// definition", so this must be used for every timed start/end we send.
String isoWithOffset(DateTime value) {
  if (value.isUtc) return value.toIso8601String();
  final offset = value.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final abs = offset.abs();
  final hours = abs.inHours.toString().padLeft(2, '0');
  final minutes = (abs.inMinutes % 60).toString().padLeft(2, '0');
  return '${value.toIso8601String()}$sign$hours:$minutes';
}

/// Extracts the first RRULE from Google's recurrence list
/// (e.g. `["RRULE:FREQ=WEEKLY;BYDAY=MO"]`) into the app's bare rule format.
/// Returns '' when there is no usable RRULE.
String parseRecurrenceRule(Object? raw) {
  if (raw is! List) return '';
  for (final entry in raw) {
    if (entry is! String) continue;
    final rule = entry.trim();
    if (rule.toUpperCase().startsWith('RRULE:')) {
      return rule.substring('RRULE:'.length);
    }
  }
  return '';
}

class GoogleCalendarException implements Exception {
  final String message;
  final int? statusCode;
  final bool needsReconnect;
  const GoogleCalendarException(
    this.message, {
    this.statusCode,
    this.needsReconnect = false,
  });

  @override
  String toString() => message;
}

/// Parses a CSS hex color ("#039be5", "039be5") into an ARGB int.
/// Returns null when the value is missing or malformed.
int? parseCssColor(String? raw) {
  if (raw == null) return null;
  var hex = raw.trim();
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (hex.length == 3) {
    hex = hex.split('').map((c) => '$c$c').join();
  }
  if (hex.length != 6) return null;
  final rgb = int.tryParse(hex, radix: 16);
  if (rgb == null) return null;
  return 0xFF000000 | rgb;
}

/// Talks to the Python server's Google Calendar endpoints. The server holds
/// the OAuth tokens and expands recurring events, so the app only deals
/// with a flat list of occurrences.
class GoogleCalendarService {
  final String Function() baseUrl;
  final String Function() userId;
  final http.Client _client;

  GoogleCalendarService({
    required this.baseUrl,
    required this.userId,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Map<String, String> get _headers => {'X-App-User-Id': userId()};

  /// Empty base URL means "the server that serves this app" on web; native
  /// builds fall back to the local dev server.
  Uri _uri(String path, [Map<String, String>? query]) {
    final base = baseUrl().trim().replaceAll(RegExp(r'/+$'), '');
    final effectiveBase = base.isEmpty
        ? (kIsWeb ? Uri.base.origin : 'http://127.0.0.1:8000')
        : base;
    final resolved = Uri.parse(
      effectiveBase.isEmpty ? path : '$effectiveBase$path',
    );
    if (query == null) return resolved;
    return resolved.replace(queryParameters: {
      ...resolved.queryParameters,
      ...query,
    });
  }

  Map<String, dynamic> _decode(http.Response response) {
    if (response.statusCode != 200) {
      String message = 'Server returned ${response.statusCode}';
      bool needsReconnect = false;
      try {
        final body = jsonDecode(response.body);
        if (body is Map && body['error'] is String) {
          message = body['error'] as String;
        }
        if (body is Map && body['needsReconnect'] == true) {
          needsReconnect = true;
        }
      } catch (_) {}
      throw GoogleCalendarException(
        message,
        statusCode: response.statusCode,
        needsReconnect: needsReconnect,
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<bool> isConnected() async {
    final data = _decode(await _client.get(_uri('/api/google/status'),
        headers: _headers));
    return data['connected'] as bool? ?? false;
  }

  /// Returns the Google consent URL to open in a browser. The server derives
  /// the redirect URI from the host the request came in on, so this flow
  /// must be started from a host registered in the Google Cloud console
  /// (e.g. http://localhost:8000).
  Future<String> authUrl() async {
    final data = _decode(await _client.get(_uri('/api/google/auth_url'),
        headers: _headers));
    if (data['url'] is! String) {
      throw const GoogleCalendarException('Server did not return an auth URL');
    }
    return data['url'] as String;
  }

  Future<void> disconnect() async {
    await _client.post(_uri('/api/google/disconnect'), headers: _headers);
  }

  Future<List<GoogleCalendarInfo>> listCalendars() async {
    final data = _decode(await _client.get(_uri('/api/google/calendars'),
        headers: _headers));
    final list = data['calendars'];
    if (list is! List) return const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(GoogleCalendarInfo.fromJson)
        .toList();
  }

  Map<String, dynamic> _writeBody(PlannerEvent event) {
    final body = {
      'summary': event.subject,
      if (event.notes != null) 'description': event.notes,
      if (event.location != null) 'location': event.location,
      'start': isoWithOffset(event.start),
      'end': isoWithOffset(event.end),
      'allDay': event.allDay,
    };
    if (event.recurrenceRule.isNotEmpty) {
      body['recurrence'] = ['RRULE:${event.recurrenceRule}'];
    }
    return body;
  }

  /// Like [_writeBody] but without recurrence: patching a recurring
  /// instance must not carry a recurrence (Google rejects it), so the edit
  /// becomes an exception affecting only that occurrence.
  Map<String, dynamic> _instanceWriteBody(PlannerEvent event) {
    final body = _writeBody(event);
    body.remove('recurrence');
    return body;
  }

  Future<PlannerEvent> _parseWriteResponse(
    http.Response response,
    String feedId,
  ) async {
    final data = _decode(response);
    final raw = data['event'];
    if (raw is! Map<String, dynamic>) {
      throw const GoogleCalendarException(
        'Server did not return the saved event',
      );
    }
    final event = _eventFromJson(raw, feedId, null);
    if (event == null) {
      throw const GoogleCalendarException(
        'Server returned an event without an id',
      );
    }
    return event;
  }

  Future<PlannerEvent> createEvent({
    required String calendarId,
    required String feedId,
    required PlannerEvent event,
  }) async {
    final response = await _client.post(
      _uri('/api/google/events'),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'calendarId': calendarId,
        ..._writeBody(event),
      }),
    );
    return _parseWriteResponse(response, feedId);
  }

  Future<PlannerEvent> updateEvent({
    required String calendarId,
    required String feedId,
    required String eventId,
    required PlannerEvent event,
    bool instanceEdit = false,
  }) async {
    final response = await _client.patch(
      _uri('/api/google/events'),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'calendarId': calendarId,
        'eventId': eventId,
        ... (instanceEdit ? _instanceWriteBody(event) : _writeBody(event)),
      }),
    );
    return _parseWriteResponse(response, feedId);
  }

  Future<void> deleteEvent({
    required String calendarId,
    required String eventId,
  }) async {
    final response = await _client.delete(
      _uri('/api/google/events'),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'calendarId': calendarId,
        'eventId': eventId,
      }),
    );
    _decode(response);
  }

  Future<List<PlannerEvent>> fetchEvents({
    required String calendarId,
    required String feedId,
  }) async {
    final data = _decode(
      await _client.get(
        _uri('/api/google/events', {'calendarId': calendarId}),
        headers: _headers,
      ),
    );
    final list = data['events'];
    if (list is! List) return const [];
    final calendar = data['calendar'];
    final calendarColor = calendar is Map<String, dynamic>
        ? parseCssColor(calendar['backgroundColor'] as String?)
        : null;
    final events = <PlannerEvent>[];
    for (final raw in list) {
      if (raw is! Map<String, dynamic>) continue;
      final event = _eventFromJson(raw, feedId, calendarColor);
      if (event != null) events.add(event);
    }
    return events;
  }

  PlannerEvent? _eventFromJson(
    Map<String, dynamic> json,
    String feedId,
    int? calendarColor,
  ) {
    final id = json['id'] as String?;
    final startRaw = json['start'] as String?;
    if (id == null || startRaw == null) return null;
    final endRaw = json['end'] as String?;
    final allDay = json['allDay'] as bool? ?? false;
    final start = DateTime.parse(startRaw);
    var end = endRaw == null ? start : DateTime.parse(endRaw);
    final localStart = start.isUtc ? start.toLocal() : start;
    var localEnd = end.isUtc ? end.toLocal() : end;
    if (!localEnd.isAfter(localStart)) {
      localEnd = allDay ? localStart.add(const Duration(days: 1)) : localStart;
    }
    return PlannerEvent(
      id: 'gcal:$feedId:$id',
      subject: (json['summary'] as String?)?.trim().isEmpty ?? true
          ? 'Untitled'
          : (json['summary'] as String).trim(),
      notes: (json['description'] as String?)?.trim().isEmpty ?? true
          ? null
          : json['description'] as String,
      location: (json['location'] as String?)?.trim().isEmpty ?? true
          ? null
          : json['location'] as String,
      start: localStart,
      end: localEnd,
      allDay: allDay,
      recurrenceRule: parseRecurrenceRule(json['recurrence']),
      feedId: feedId,
      sourceUid: id,
      seriesId: json['seriesId'] as String?,
      colorValue:
          parseCssColor(json['backgroundColor'] as String?) ?? calendarColor,
    );
  }

  Future<PlannerEvent> fetchEvent({
    required String calendarId,
    required String feedId,
    required String eventId,
  }) async {
    final data = _decode(
      await _client.get(
        _uri('/api/google/events/one', {
          'calendarId': calendarId,
          'eventId': eventId,
        }),
        headers: _headers,
      ),
    );
    final raw = data['event'];
    if (raw is! Map<String, dynamic>) {
      throw const GoogleCalendarException('Server did not return the event');
    }
    final event = _eventFromJson(raw, feedId, null);
    if (event == null) {
      throw const GoogleCalendarException(
        'Server returned an event without an id',
      );
    }
    return event;
  }
}
