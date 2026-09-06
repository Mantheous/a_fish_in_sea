import 'dart:convert';

import 'package:enough_icalendar/enough_icalendar.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:timezone/timezone.dart' as tz;

import '../model/feed.dart';
import '../model/ical_recurrence.dart';
import '../model/planner_event.dart';
import '../model/recurrence.dart';

class IcalFetchException implements Exception {
  final String message;
  const IcalFetchException(this.message);

  @override
  String toString() => message;
}

final RegExp _canvasCoursePattern = RegExp(r'\s*\[([^[\]]+)\]\s*$');

class IcalService {
  final http.Client _client;

  IcalService({http.Client? client}) : _client = client ?? http.Client();

  Future<String> fetchIcs({
    required String url,
    required String Function() proxyBase,
  }) async {
    final prefix = proxyBase().trim().replaceAll(RegExp(r'/+$'), '');
    String target;
    if (kIsWeb) {
      // Empty proxy base means "the server that serves this app" — resolve
      // against the app's own origin so the target is an absolute URL.
      final base = prefix.isEmpty ? Uri.base.origin : prefix;
      target = '$base/api/ical?url=${Uri.encodeComponent(url)}';
    } else {
      target = url;
    }
    final uri = Uri.tryParse(target);
    if (uri == null || !uri.isScheme('HTTP') && !uri.isScheme('HTTPS')) {
      throw IcalFetchException('Invalid feed URL: $url');
    }
    final http.Response response;
    try {
      response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      throw IcalFetchException('Could not reach feed: $e');
    }
    if (response.statusCode != 200) {
      throw IcalFetchException('Server returned ${response.statusCode}');
    }
    // Feeds in the wild (e.g. Learning Suite) sometimes declare UTF-8 but
    // contain stray non-UTF-8 bytes. Decode leniently so one bad byte
    // doesn't fail the whole sync (previously threw FormatException).
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    final trimmed = body.trimLeft();
    if (trimmed.startsWith('<') || trimmed.startsWith('{')) {
      throw const IcalFetchException('Response was not an iCal file');
    }
    if (!trimmed.contains('BEGIN:VCALENDAR')) {
      throw const IcalFetchException('No VCALENDAR found in response');
    }
    return body;
  }

  List<PlannerEvent> parseIcs(
    String text, {
    required String feedId,
    FeedKind kind = FeedKind.other,
  }) {
    final root = VComponent.parse(text);
    final calendar = root is VCalendar ? root : null;
    if (calendar == null) return const [];
    final events = <PlannerEvent>[];
    for (final child in calendar.children) {
      if (child is VEvent) {
        final event = _eventFromVEvent(child, feedId, kind);
        if (event != null) events.add(event);
      } else if (child is VTodo) {
        final event = _eventFromVTodo(child, feedId, kind);
        if (event != null) events.add(event);
      }
    }
    return events;
  }

  /// Canvas titles end with the course code in brackets, e.g.
  /// "Exit Quiz [STAT 230-002]". Splits that off into [PlannerEvent.classLabel].
  (String subject, String? classLabel) _splitCanvasTitle(String summary) {
    final match = _canvasCoursePattern.firstMatch(summary);
    if (match == null) return (summary.trim(), null);
    return (
      summary.substring(0, match.start).trim(),
      match.group(1)?.trim(),
    );
  }

  PlannerEvent? _eventFromVEvent(VEvent vevent, String feedId, FeedKind kind) {
    try {
      final startProp = vevent.getProperty<DateTimeProperty>(
        DateTimeProperty.propertyNameStart,
      );
      final start = vevent.start;
      if (startProp == null || start == null) return null;
      final allDay = _isDateOnly(startProp);
      final resolvedStart = _resolveDateTime(start, startProp);

      DateTime resolvedEnd;
      final endProp = vevent.getProperty<DateTimeProperty>(
        DateTimeProperty.propertyNameEnd,
      );
      final end = vevent.end;
      final duration = vevent.duration;
      if (end != null) {
        resolvedEnd = _resolveDateTime(end, endProp);
      } else if (duration != null) {
        resolvedEnd = resolvedStart.add(_durationFromIso(duration));
      } else if (allDay) {
        resolvedEnd = resolvedStart.add(const Duration(days: 1));
      } else {
        resolvedEnd = resolvedStart;
      }
      if (!resolvedEnd.isAfter(resolvedStart)) {
        resolvedEnd = resolvedStart;
      }

      final rule = _ruleFor(vevent.recurrenceRule, resolvedStart);

      final uid = vevent.uid;
      final id = 'hw:$feedId:${uid.isEmpty ? _fallbackKey(vevent, resolvedStart) : uid}';
      final rawSubject = (vevent.summary ?? '').trim();
      final (subject, classLabel) = kind == FeedKind.canvas && rawSubject.isNotEmpty
          ? _splitCanvasTitle(rawSubject)
          : (rawSubject, null);

      return PlannerEvent(
        id: id,
        subject: subject.isEmpty ? 'Untitled' : subject,
        notes: vevent.description,
        location: vevent.location,
        start: resolvedStart,
        end: resolvedEnd,
        allDay: allDay,
        recurrenceRule: rule,
        feedId: feedId,
        sourceUid: uid,
        classLabel: classLabel,
      );
    } catch (_) {
      return null;
    }
  }

  PlannerEvent? _eventFromVTodo(VTodo vtodo, String feedId, FeedKind kind) {
    try {
      final status = vtodo.status;
      if (status == TodoStatus.completed || status == TodoStatus.cancelled) {
        return null;
      }
      final dueProp = vtodo.getProperty<DateTimeProperty>(
        DateTimeProperty.propertyNameDue,
      );
      final due = dueProp?.dateTime;
      if (dueProp == null || due == null) return null;
      final allDay = _isDateOnly(dueProp);
      final resolvedDue = _resolveDateTime(due, dueProp);
      final rule = _ruleFor(vtodo.recurrenceRule, resolvedDue);
      final uid = vtodo.uid;
      final id = 'hw:$feedId:${uid.isEmpty ? _fallbackKey(vtodo, resolvedDue) : uid}';
      final rawSubject = (vtodo.summary ?? '').trim();
      final (subject, classLabel) = kind == FeedKind.canvas && rawSubject.isNotEmpty
          ? _splitCanvasTitle(rawSubject)
          : (rawSubject, null);
      return PlannerEvent(
        id: id,
        subject: subject.isEmpty ? 'Untitled' : subject,
        notes: vtodo.description,
        start: resolvedDue,
        end: resolvedDue,
        allDay: allDay,
        recurrenceRule: rule,
        feedId: feedId,
        sourceUid: uid,
        classLabel: classLabel,
      );
    } catch (_) {
      return null;
    }
  }

  String _ruleFor(Recurrence? recurrence, DateTime start) {
    if (recurrence == null) return '';
    final config = repeatConfigFromICal(
      _toNeutralRecurrence(recurrence),
      start,
    );
    return config?.ruleFor(start) ?? '';
  }

  ICalRecurrence _toNeutralRecurrence(Recurrence recurrence) => ICalRecurrence(
        frequency: switch (recurrence.frequency) {
          RecurrenceFrequency.secondly => ICalFrequency.secondly,
          RecurrenceFrequency.minutely => ICalFrequency.minutely,
          RecurrenceFrequency.hourly => ICalFrequency.hourly,
          RecurrenceFrequency.daily => ICalFrequency.daily,
          RecurrenceFrequency.weekly => ICalFrequency.weekly,
          RecurrenceFrequency.monthly => ICalFrequency.monthly,
          RecurrenceFrequency.yearly => ICalFrequency.yearly,
        },
        until: recurrence.until,
        count: recurrence.count,
        interval: recurrence.interval,
        byWeekDay: recurrence.byWeekDay
            ?.map((d) => ICalByDay(d.weekday, week: d.week))
            .toList(),
        bySecond: recurrence.bySecond,
        byMinute: recurrence.byMinute,
        byHour: recurrence.byHour,
        byYearDay: recurrence.byYearDay,
        byWeek: recurrence.byWeek,
        byMonth: recurrence.byMonth,
        byMonthDay: recurrence.byMonthDay,
        bySetPos: recurrence.bySetPos,
      );

  bool _isDateOnly(DateTimeProperty prop) {
    final value = prop[ParameterType.value];
    return value?.textValue.toUpperCase() == 'DATE';
  }

  DateTime _resolveDateTime(DateTime dt, DateTimeProperty? prop) {
    final tzid = prop?.timezoneId;
    if (tzid != null && tzid.isNotEmpty) {
      try {
        final location = tz.getLocation(tzid);
        final naive =
            DateTime(dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second);
        return tz.TZDateTime.from(naive, location).toLocal();
      } catch (_) {
        return dt;
      }
    }
    if (dt.isUtc) return dt.toLocal();
    return dt;
  }

  Duration _durationFromIso(IsoDuration duration) => Duration(
        days: duration.days + 7 * duration.weeks,
        hours: duration.hours,
        minutes: duration.minutes,
        seconds: duration.seconds,
      );

  String _fallbackKey(VComponent component, DateTime start) =>
      '${component.name}:${start.millisecondsSinceEpoch}';
}
