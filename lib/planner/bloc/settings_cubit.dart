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

  const SettingsState({
    this.icalProxyBase = '',
    this.defaultCalendarView = CalendarView.week,
    this.dayStartHour = 6,
    this.dayEndHour = 24,
    this.snapMinutes = 15,
    this.defaultEventFeedId,
    this.trackingEnabled = true,
    this.trackingIntervalMinutes = 5,
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
      ];
}

class SettingsCubit extends HydratedCubit<SettingsState> {
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
      );

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
      };
}
