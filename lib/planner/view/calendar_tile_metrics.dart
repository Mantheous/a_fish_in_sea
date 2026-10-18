import '../model/event_reschedule.dart';
import '../model/planner_event.dart';

/// Display policy for timed tiles in the calendar's day/week grid. Lives
/// beside the page rather than inside it: the page is a hotspot, and the
/// floor is read by both the Syncfusion slot settings and the tile's
/// resize math, so it deserves its own seam (and unit tests).

/// The smallest span a timed tile may occupy on the grid.
///
/// A zero-duration event (iCal `DTSTART` with no `DTEND`/`DURATION`, or a
/// hand-edited `start == end`) otherwise lays out a 0px-tall tile: it is
/// invisible and untappable, while still appearing in lists, the month
/// agenda and report blocks. Flooring the tile keeps such events visible
/// and clickable without touching the stored event itself — [tileDuration]
/// and Syncfusion's `minimumAppointmentDuration` only affect layout, and
/// dragging still moves the real zero-length span.
///
/// Matches [minEventDuration], the shortest span the editor and resize
/// handles will ever produce, so a point event reads exactly like the
/// smallest real event (a 15-minute block).
const Duration minimumTileDuration = minEventDuration;

/// The span a timed tile actually occupies in the day/week grid: the
/// event's own length, floored at [minimumTileDuration].
///
/// Resize handles scale drags with this (`pxPerMinute = height / span`),
/// so a zero-duration tile's handles move at the same px-per-minute as
/// the grid instead of the old 60-minute fallback that made them four
/// times too fast.
Duration tileDuration(PlannerEvent event) {
  final duration = event.end.isAfter(event.start)
      ? event.end.difference(event.start)
      : Duration.zero;
  return duration > minimumTileDuration ? duration : minimumTileDuration;
}
