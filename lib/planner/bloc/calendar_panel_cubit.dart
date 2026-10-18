import 'package:bloc/bloc.dart';

/// Default width of the calendar's right-hand side panel (wide screens).
const double calendarPanelDefaultWidth = 360;

/// Hard bounds for the panel's width, whatever the window size.
const double calendarPanelMinWidth = 280;
const double calendarPanelMaxWidth = 800;

/// Remembers how wide the user dragged the calendar side panel, so the
/// choice survives page switches (CalendarPage is rebuilt on every
/// navigation). In-memory only (not hydrated): UI chrome, no user data, so
/// there is no persistence schema to migrate and nothing for the data
/// guardian to audit. Provided above `MaterialApp` in main.dart.
class CalendarPanelCubit extends Cubit<double> {
  CalendarPanelCubit() : super(calendarPanelDefaultWidth);

  void setWidth(double width) {
    if (width.isNaN || width.isInfinite) return;
    final clamped = width
        .clamp(calendarPanelMinWidth, calendarPanelMaxWidth)
        .toDouble();
    if (clamped != state) emit(clamped);
  }

  void resetWidth() => setWidth(calendarPanelDefaultWidth);
}
