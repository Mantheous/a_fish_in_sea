import 'package:equatable/equatable.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

class SettingsState extends Equatable {
  final String icalProxyBase;
  final CalendarView defaultCalendarView;
  final double dayStartHour;
  final double dayEndHour;
  final int snapMinutes;
  final String? defaultEventFeedId;

  const SettingsState({
    this.icalProxyBase = '',
    this.defaultCalendarView = CalendarView.week,
    this.dayStartHour = 6,
    this.dayEndHour = 24,
    this.snapMinutes = 15,
    this.defaultEventFeedId,
  });

  SettingsState copyWith({
    String? icalProxyBase,
    CalendarView? defaultCalendarView,
    double? dayStartHour,
    double? dayEndHour,
    int? snapMinutes,
    String? defaultEventFeedId,
    bool clearDefaultEventFeedId = false,
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
      ];
}

class SettingsCubit extends HydratedCubit<SettingsState> {
  SettingsCubit() : super(const SettingsState());

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

  void setDefaultEventFeedId(String? feedId) {
    final trimmed = feedId?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      emit(state.copyWith(clearDefaultEventFeedId: true));
    } else {
      emit(state.copyWith(defaultEventFeedId: trimmed));
    }
  }

  static CalendarView _parseView(String? name) {
    if (name == null) return CalendarView.week;
    for (final view in CalendarView.values) {
      if (view.name == name) return view;
    }
    return CalendarView.week;
  }

  static double _parseHour(Object? value, double fallback) {
    if (value is num) return value.toDouble().clamp(0, 24).toDouble();
    return fallback;
  }

  static int _parseSnap(Object? value) {
    if (value is num) return value.toInt().clamp(1, 60);
    return 15;
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
      );

  @override
  Map<String, dynamic> toJson(SettingsState state) => {
        'icalProxyBase': state.icalProxyBase,
        'defaultCalendarView': state.defaultCalendarView.name,
        'dayStartHour': state.dayStartHour,
        'dayEndHour': state.dayEndHour,
        'snapMinutes': state.snapMinutes,
        'defaultEventFeedId': state.defaultEventFeedId,
      };
}
