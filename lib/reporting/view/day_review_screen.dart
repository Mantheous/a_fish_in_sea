import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../../common/undo/undo_bar.dart';
import '../../planner/bloc/calendar_cubit.dart';
import '../../planner/bloc/feed_cubit.dart';
import '../bloc/places_cubit.dart';
import '../bloc/reporting_cubit.dart';
import '../bloc/tracking_cubit.dart';
import '../model/place.dart';
import '../model/reported_entry.dart';
import '../reporting_logic.dart';
import '../service/location_service.dart';
import 'places_sheet.dart';

List<PlannedSlice> daySlices(
  CalendarCubit calendar,
  FeedCubit feeds,
  DateTime day,
) {
  final dayStart = DateTime(day.year, day.month, day.day);
  final dayEnd = dayStart.add(const Duration(days: 1));
  final visible = feeds.visibleEvents(calendar.state);
  final slices = <PlannedSlice>[];
  for (final event in visible) {
    if (event.allDay) {
      if (event.start.isBefore(dayEnd) &&
          event.endOfDay.isAfter(dayStart)) {
        slices.add(PlannedSlice(
          eventId: event.id,
          title: event.subject,
          placeId: event.placeId,
          start: dayStart,
          end: dayStart,
          allDay: true,
        ));
      }
      continue;
    }
    final duration = event.end.isAfter(event.start)
        ? event.end.difference(event.start)
        : const Duration(hours: 1);
    for (final occ in calendar.occurrencesOf(event, dayStart, dayEnd)) {
      slices.add(PlannedSlice(
        eventId: event.id,
        title: event.subject,
        placeId: event.placeId,
        start: occ,
        end: occ.add(duration),
      ));
    }
  }
  slices.sort((a, b) => a.start.compareTo(b.start));
  return slices;
}

class DayReviewScreen extends StatefulWidget {
  const DayReviewScreen({super.key});

  @override
  State<DayReviewScreen> createState() => _DayReviewScreenState();
}

class _DayReviewScreenState extends State<DayReviewScreen> {
  DateTime _day = DateTime.now();
  double _scrubMin = 12 * 60;
  Timer? _playTimer;
  bool _playing = false;
  bool _runningReport = false;

  @override
  void dispose() {
    _playTimer?.cancel();
    super.dispose();
  }

  DateTime get _dayStart =>
      DateTime(_day.year, _day.month, _day.day);

  void _togglePlay(int pointCount) {
    if (_playing) {
      _playTimer?.cancel();
      setState(() => _playing = false);
      return;
    }
    setState(() => _playing = true);
    _playTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!mounted) return;
      setState(() {
        _scrubMin += 10;
        if (_scrubMin >= 24 * 60) {
          _scrubMin = (24 * 60 - 1).toDouble();
          _playing = false;
          _playTimer?.cancel();
        }
      });
    });
  }

  Future<void> _runAutoReport() async {
    if (_runningReport) return;
    setState(() => _runningReport = true);
    try {
      final pending = await takePendingPoints();
      if (!mounted) return;
      if (pending.isNotEmpty) {
        context.read<TrackingCubit>().mergePoints(pending);
      }
      if (!mounted) return;
      final calendar = context.read<CalendarCubit>();
      final feeds = context.read<FeedCubit>();
      final places = context.read<PlacesCubit>().state;
      final points =
          context.read<TrackingCubit>().state.pointsOnDay(_day);
      context.read<ReportingCubit>().runAutoReport(
            day: _day,
            planned: daySlices(calendar, feeds, _day),
            dwells: clusterDwells(points, places),
            placeNames: {for (final p in places) p.id: p.name},
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Auto-report updated (${points.length} points)')),
        );
      }
    } finally {
      if (mounted) setState(() => _runningReport = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final points = context.watch<TrackingCubit>().state.pointsOnDay(_day);
    final places = context.watch<PlacesCubit>().state;
    final reported = context.watch<ReportingCubit>().entriesForDay(_day);
    final calendar = context.watch<CalendarCubit>();
    final feeds = context.watch<FeedCubit>();
    final planned = daySlices(calendar, feeds, _day);

    final scrubTime =
        _dayStart.add(Duration(minutes: _scrubMin.round()));
    final atScrub = _positionAt(points, scrubTime);
    final center = atScrub ??
        (points.isNotEmpty
            ? LatLng(points.last.lat, points.last.lng)
            : places.isNotEmpty
                ? LatLng(places.first.lat, places.first.lng)
                : const LatLng(40.23, -111.66));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Day review'),
        actions: const [UndoRedoActions()],
      ),
      body: Column(
        children: [
          DayPicker(
            day: _day,
            onChanged: (d) => setState(() {
              _day = d;
              _playing = false;
              _playTimer?.cancel();
            }),
          ),
          SizedBox(
          height: 240,
          child: Stack(
            children: [
              FlutterMap(
                options: MapOptions(initialCenter: center, initialZoom: points.isEmpty ? 11 : 14),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'a_fish_in_sea',
                  ),
                  if (places.isNotEmpty)
                    CircleLayer(
                      circles: [
                        for (final place in places)
                          CircleMarker(
                            point: LatLng(place.lat, place.lng),
                            radius: place.radiusM,
                            useRadiusInMeter: true,
                            color: Colors.teal.withValues(alpha: 0.15),
                            borderColor: Colors.teal,
                            borderStrokeWidth: 2,
                          ),
                      ],
                    ),
                  if (points.length >= 2)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: [
                            for (final p in points) LatLng(p.lat, p.lng),
                          ],
                          color: Colors.blue,
                          strokeWidth: 4,
                        ),
                      ],
                    ),
                  MarkerLayer(
                    markers: [
                      if (atScrub != null)
                        Marker(
                          point: atScrub,
                          width: 36,
                          height: 36,
                          child: const Icon(Icons.location_on,
                              color: Colors.red, size: 32),
                        ),
                      for (final place in places)
                        Marker(
                          point: LatLng(place.lat, place.lng),
                          width: 120,
                          height: 28,
                          child: Container(
                            alignment: Alignment.topCenter,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.teal),
                              ),
                              child: Text(place.name,
                                  style: const TextStyle(fontSize: 11),
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              if (points.isEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    color: Colors.black54,
                    padding: const EdgeInsets.all(8),
                    child: const Text(
                      'No points this day — press Start on Home to record.',
                      style: TextStyle(color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${points.length} points · ${reported.length} reported',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton.icon(
                onPressed: () => showPlacesSheet(context),
                icon: const Icon(Icons.place_outlined, size: 18),
                label: const Text('Places'),
              ),
              const SizedBox(width: 4),
              FilledButton.icon(
                onPressed: _runningReport ? null : _runAutoReport,
                icon: _runningReport
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_fix_high, size: 18),
                label: const Text('Auto-report'),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Text('Plan',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              Expanded(
                child: Text('Reported (editable)',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _PlanColumn(planned: planned, reported: reported)),
                Expanded(
                  child: _ReportedColumn(
                    day: _day,
                    entries: reported,
                    places: places,
                  ),
                ),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            padding: EdgeInsets.fromLTRB(
              4,
              4,
              12,
              4 + MediaQuery.of(context).padding.bottom,
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: _playing ? 'Pause' : 'Play day',
                  icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                  onPressed: () => _togglePlay(points.length),
                ),
                Expanded(
                  child: Slider(
                    min: 0,
                    max: 24 * 60 - 1,
                    divisions: 24 * 12,
                    value: _scrubMin.clamp(0, 24 * 60 - 1),
                    label: DateFormat('h:mm a').format(scrubTime),
                    onChanged: (v) => setState(() => _scrubMin = v),
                  ),
                ),
                SizedBox(
                  width: 72,
                  child: Text(
                    DateFormat('h:mm a').format(scrubTime),
                    style: Theme.of(context).textTheme.labelLarge,
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  LatLng? _positionAt(List<dynamic> points, DateTime time) {
    LatLng? last;
    for (final p in points) {
      final point = p as dynamic;
      final ts = point.timestamp as DateTime;
      if (ts.isAfter(time)) break;
      last = LatLng(point.lat as double, point.lng as double);
    }
    return last;
  }
}

class DayPicker extends StatelessWidget {
  final DateTime day;
  final ValueChanged<DateTime> onChanged;

  const DayPicker({super.key, required this.day, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final isToday = isSameDay(day, today);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () =>
                onChanged(day.subtract(const Duration(days: 1))),
          ),
          Expanded(
            child: InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: day,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2100),
                );
                if (picked != null) onChanged(picked);
              },
              child: Text(
                isToday
                    ? 'Today · ${DateFormat('EEE, MMM d').format(day)}'
                    : DateFormat('EEE, MMM d, yyyy').format(day),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: isToday
                ? null
                : () => onChanged(day.add(const Duration(days: 1))),
          ),
        ],
      ),
    );
  }
}

class _PlanColumn extends StatelessWidget {
  final List<PlannedSlice> planned;
  final List<ReportedEntry> reported;

  const _PlanColumn({required this.planned, required this.reported});

  @override
  Widget build(BuildContext context) {
    final actionable = planned.where((p) => !p.allDay).toList();
    if (actionable.isEmpty) {
      return const Center(child: Text('No planned events'));
    }
    final byEvent = {for (final r in reported) r.eventId: r};
    final timeFormat = DateFormat('h:mm a');
    return ListView.builder(
      itemCount: actionable.length,
      itemBuilder: (context, index) {
        final item = actionable[index];
        final match = byEvent[item.eventId];
        return ListTile(
          dense: true,
          title: Text(item.title,
              style: Theme.of(context).textTheme.bodyMedium),
          subtitle: Text(
            '${timeFormat.format(item.start)} – ${timeFormat.format(item.end)}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          trailing: match == null
              ? const Icon(Icons.help_outline, size: 18)
              : _StatusDot(status: match.status),
        );
      },
    );
  }
}

class _StatusDot extends StatelessWidget {
  final ReportStatus status;

  const _StatusDot({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      ReportStatus.attended => Colors.green,
      ReportStatus.partial => Colors.orange,
      ReportStatus.missed => Colors.red,
      ReportStatus.extra => Colors.blue,
    };
    return Tooltip(
      message: status.name,
      child: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

class _ReportedColumn extends StatelessWidget {
  final DateTime day;
  final List<ReportedEntry> entries;
  final List<Place> places;

  const _ReportedColumn({
    required this.day,
    required this.entries,
    required this.places,
  });

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Nothing reported yet — run Auto-report, then tap an entry to edit it.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final timeFormat = DateFormat('h:mm a');
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return ListTile(
          dense: true,
          title: Text(entry.title,
              style: Theme.of(context).textTheme.bodyMedium),
          subtitle: Text(
            '${timeFormat.format(entry.start)} – ${timeFormat.format(entry.end)}'
            '${entry.auto ? ' · auto' : ''}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          trailing: _StatusDot(status: entry.status),
          onTap: () => showReportedEditor(context, day: day, entry: entry),
        );
      },
    );
  }
}

Future<void> showReportedEditor(
  BuildContext context, {
  required DateTime day,
  required ReportedEntry entry,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: _ReportedEditorSheet(day: day, entry: entry),
    ),
  );
}

class _ReportedEditorSheet extends StatefulWidget {
  final DateTime day;
  final ReportedEntry entry;

  const _ReportedEditorSheet({required this.day, required this.entry});

  @override
  State<_ReportedEditorSheet> createState() => _ReportedEditorSheetState();
}

class _ReportedEditorSheetState extends State<_ReportedEditorSheet> {
  late final TextEditingController _title;
  late ReportStatus _status;
  late TimeOfDay _start;
  late TimeOfDay _end;
  late String? _placeId;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.entry.title);
    _status = widget.entry.status;
    _start = TimeOfDay.fromDateTime(widget.entry.start);
    _end = TimeOfDay.fromDateTime(widget.entry.end);
    _placeId = widget.entry.placeId;
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  DateTime _at(TimeOfDay t) =>
      DateTime(widget.day.year, widget.day.month, widget.day.day, t.hour, t.minute);

  @override
  Widget build(BuildContext context) {
    final places = context.watch<PlacesCubit>().state;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Edit reported entry',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ReportStatus>(
              initialValue: _status,
              decoration: const InputDecoration(
                labelText: 'Marked as',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                    value: ReportStatus.attended, child: Text('Attended')),
                DropdownMenuItem(
                    value: ReportStatus.partial, child: Text('Partial')),
                DropdownMenuItem(
                    value: ReportStatus.missed, child: Text('Missed')),
                DropdownMenuItem(
                    value: ReportStatus.extra, child: Text('Extra')),
              ],
              onChanged: (v) =>
                  setState(() => _status = v ?? ReportStatus.attended),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: _placeId,
              decoration: const InputDecoration(
                labelText: 'Place',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('No place')),
                for (final place in places)
                  DropdownMenuItem(
                      value: place.id, child: Text(place.name)),
              ],
              onChanged: (v) => setState(() => _placeId = v),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _TimeField(
                    label: 'Start',
                    value: _start,
                    onChanged: (v) => setState(() => _start = v),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _TimeField(
                    label: 'End',
                    value: _end,
                    onChanged: (v) => setState(() => _end = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    context
                        .read<ReportingCubit>()
                        .deleteEntry(widget.day, widget.entry.id);
                    Navigator.of(context).pop();
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  child: const Text('Delete'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    var end = _at(_end);
                    final start = _at(_start);
                    if (!end.isAfter(start)) {
                      end = start.add(const Duration(hours: 1));
                    }
                    context.read<ReportingCubit>().upsertEntry(
                          widget.day,
                          widget.entry.copyWith(
                            title: _title.text.trim().isEmpty
                                ? widget.entry.title
                                : _title.text.trim(),
                            placeId: _placeId,
                            clearPlaceId: _placeId == null,
                            start: start,
                            end: end,
                            status: _status,
                          ),
                        );
                    Navigator.of(context).pop();
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TimeField extends StatelessWidget {
  final String label;
  final TimeOfDay value;
  final ValueChanged<TimeOfDay> onChanged;

  const _TimeField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(labelText: label),
      child: InkWell(
        onTap: () async {
          final picked = await showTimePicker(
            context: context,
            initialTime: value,
          );
          if (picked != null) onChanged(picked);
        },
        child: Text(value.format(context)),
      ),
    );
  }
}
