import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

/// Mobile phones start on the day view; web desktop and desktop start on week.
/// Mobile browsers (android/iOS on web) also start on day — the app is
/// served as a web build, so `isWeb` alone can't decide.
CalendarView platformDefaultFor({
  required bool isWeb,
  required TargetPlatform platform,
}) {
  switch (platform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return CalendarView.day;
    case TargetPlatform.fuchsia:
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
      return CalendarView.week;
  }
}

CalendarView get platformDefaultCalendarView => platformDefaultFor(
      isWeb: kIsWeb,
      platform: defaultTargetPlatform,
    );

class SettingsState extends Equatable {
  final String icalProxyBase;
  final CalendarView defaultCalendarView;
  final double dayStartHour;
  final double dayEndHour;
  final int snapMinutes;
  final String? defaultEventFeedId;
  final bool trackingEnabled;
  final int trackingIntervalMinutes;

  /// AnkiConnect endpoint for memorization goals. Per-device like
  /// [icalProxyBase]: a desktop talks to its own localhost, a phone to a
  /// LAN address — roaming one value would break the other device.
  final String ankiConnectHost;

  const SettingsState({
    this.icalProxyBase = '',
    this.defaultCalendarView = CalendarView.week,
    this.dayStartHour = 6,
    this.dayEndHour = 24,
    this.snapMinutes = 15,
    this.defaultEventFeedId,
    this.trackingEnabled = true,
    this.trackingIntervalMinutes = 5,
    this.ankiConnectHost = SettingsCubit.defaultAnkiConnectHost,
  });

  SettingsState copyWith({
    String? icalProxyBase,
    CalendarView? defaultCalendarView,
    double? dayStartHour,
    double? dayEndHour,
    int? snapMinutes,
    String? defaultEventFeedId,
    bool clearDefaultEventFeedId = false,
    bool? trackingEnabled,
    int? trackingIntervalMinutes,
    String? ankiConnectHost,
  }) {
    return SettingsState(
      icalProxyBase: icalProxyBase ?? this.icalProxyBase,
      defaultCalendarView: defaultCalendarView ?? this.defaultCalendarView,
      dayStartHour: dayStartHour ?? this.dayStartHour,
      dayEndHour: dayEndHour ?? this.dayEndHour,
      snapMinutes: snapMinutes ?? this.snapMinutes,
      defaultEventFeedId: clearDefaultEventFeedId
          ? null
          : (defaultEventFeedId ?? this.defaultEventFeedId),
      trackingEnabled: trackingEnabled ?? this.trackingEnabled,
      trackingIntervalMinutes:
          trackingIntervalMinutes ?? this.trackingIntervalMinutes,
      ankiConnectHost: ankiConnectHost ?? this.ankiConnectHost,
    );
  }

  @override
  List<Object?> get props => [
        icalProxyBase,
        defaultCalendarView,
        dayStartHour,
        dayEndHour,
        snapMinutes,
        defaultEventFeedId,
        trackingEnabled,
        trackingIntervalMinutes,
        ankiConnectHost,
      ];
}

class SettingsCubit extends HydratedCubit<SettingsState> {
  static const String defaultAnkiConnectHost = 'http://127.0.0.1:8765';

  SettingsCubit()
      : super(SettingsState(defaultCalendarView: platformDefaultCalendarView));

  void setIcalProxyBase(String url) =>
      emit(state.copyWith(icalProxyBase: url.trim()));

  void setDefaultCalendarView(CalendarView view) =>
      emit(state.copyWith(defaultCalendarView: view));

  void setDayStartHour(double hour) {
    final clamped = hour.clamp(0, 24).toDouble();
    final end = state.dayEndHour;
    emit(state.copyWith(
      dayStartHour: clamped >= end ? end - 0.5 : clamped,
    ));
  }

  void setDayEndHour(double hour) {
    final clamped = hour.clamp(0, 24).toDouble();
    final start = state.dayStartHour;
    emit(state.copyWith(
      dayEndHour: clamped <= start ? start + 0.5 : clamped,
    ));
  }

  void setDayHours(double startHour, double endHour) {    var start = startHour.clamp(0, 24).toDouble();
    var end = endHour.clamp(0, 24).toDouble();
    if (end <= start) {
      if (start >= 24) {
        start = 23.5;
        end = 24;
      } else {
        end = start + 0.5;
      }
    }
    emit(state.copyWith(dayStartHour: start, dayEndHour: end));
  }

  static const List<int> snapChoices = [5, 10, 15, 30, 60];

  void setSnapMinutes(int minutes) {
    emit(state.copyWith(snapMinutes: minutes.clamp(1, 60)));
  }

  static const List<int> trackingIntervalChoices = [1, 2, 5, 10, 15];

  void setTrackingEnabled(bool enabled) {
    emit(state.copyWith(trackingEnabled: enabled));
  }

  void setTrackingIntervalMinutes(int minutes) {
    emit(state.copyWith(trackingIntervalMinutes: minutes.clamp(1, 15)));
  }

  void setDefaultEventFeedId(String? feedId) {
    final trimmed = feedId?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      emit(state.copyWith(clearDefaultEventFeedId: true));
    } else {
      emit(state.copyWith(defaultEventFeedId: trimmed));
    }
  }

  /// AnkiConnect endpoint. Blank resets to the local default; validation
  /// (and its displayable error) lives in the client at sync time.
  void setAnkiConnectHost(String host) {
    final trimmed = host.trim();
    emit(state.copyWith(
        ankiConnectHost:
            trimmed.isEmpty ? defaultAnkiConnectHost : trimmed));
  }

  /// Sync apply: takes the roamed settings but keeps the per-device
  /// server URL (different networks need different URLs).
  void applySyncedJson(Map<String, dynamic> json) {
    final restored = fromJson(json);
    if (restored == null) return;
    emit(restored.copyWith(
      icalProxyBase: state.icalProxyBase,
      ankiConnectHost: state.ankiConnectHost,
    ));
  }

  static CalendarView _parseView(String? name) {
    if (name == null) return platformDefaultCalendarView;
    for (final view in CalendarView.values) {
      if (view.name == name) return view;
    }
    return platformDefaultCalendarView;
  }

  static double _parseHour(Object? value, double fallback) {
    if (value is num) return value.toDouble().clamp(0, 24).toDouble();
    return fallback;
  }

  static int _parseSnap(Object? value) {
    if (value is num) return value.toInt().clamp(1, 60);
    return 15;
  }

  static int _parseTrackingInterval(Object? value) {
    if (value is num) return value.toInt().clamp(1, 15);
    return 5;
  }

  @override
  SettingsState? fromJson(Map<String, dynamic> json) => SettingsState(
        icalProxyBase: json['icalProxyBase'] as String? ?? '',
        defaultCalendarView:
            _parseView(json['defaultCalendarView'] as String?),
        dayStartHour: _parseHour(json['dayStartHour'], 6),
        dayEndHour: _parseHour(json['dayEndHour'], 24),
        snapMinutes: _parseSnap(json['snapMinutes']),
        defaultEventFeedId: json['defaultEventFeedId'] as String?,
        trackingEnabled: json['trackingEnabled'] as bool? ?? true,
        trackingIntervalMinutes:
            _parseTrackingInterval(json['trackingIntervalMinutes']),
        ankiConnectHost: _parseAnkiHost(json['ankiConnectHost']),
      );

  static String _parseAnkiHost(Object? value) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return defaultAnkiConnectHost;
  }

  @override
  Map<String, dynamic> toJson(SettingsState state) => {
        'icalProxyBase': state.icalProxyBase,
        'defaultCalendarView': state.defaultCalendarView.name,
        'dayStartHour': state.dayStartHour,
        'dayEndHour': state.dayEndHour,
        'snapMinutes': state.snapMinutes,
        'defaultEventFeedId': state.defaultEventFeedId,
        'trackingEnabled': state.trackingEnabled,
        'trackingIntervalMinutes': state.trackingIntervalMinutes,
        'ankiConnectHost': state.ankiConnectHost,
      };
}
