part of 'calendar_report.dart';

/// Calendar-only identity; persisted entry ids remain unchanged.
String reportAcceptedDisplayIdFor(String day, String entryId) =>
    '${reportDisplayIdPrefix}accepted:${Uri.encodeComponent(day)}:$entryId';

/// Resolves the storage bucket as well as the entry, even when its start
/// time differs from its bucket. Ambiguous legacy display ids fail safely.
({String day, ReportedEntry entry})? findReportEntryLocationByDisplayId(
  Map<String, List<ReportedEntry>> reportsByDay,
  String displayId,
) {
  if (reportOwnerIdForDisplayId(displayId) != null) return null;
  ({String day, ReportedEntry entry})? legacy;
  var ambiguous = false;
  for (final day in reportsByDay.entries) {
    for (final entry in day.value) {
      if (reportAcceptedDisplayIdFor(day.key, entry.id) == displayId) {
        return (day: day.key, entry: entry);
      }
      if ('$reportDisplayIdPrefix${entry.id}' == displayId) {
        if (legacy != null) ambiguous = true;
        legacy = (day: day.key, entry: entry);
      }
    }
  }
  return ambiguous ? null : legacy;
}

/// Timer/live ids do not resolve to accepted entries.
ReportedEntry? findReportEntryByDisplayId(
  Map<String, List<ReportedEntry>> reportsByDay,
  String displayId,
) => findReportEntryLocationByDisplayId(reportsByDay, displayId)?.entry;
