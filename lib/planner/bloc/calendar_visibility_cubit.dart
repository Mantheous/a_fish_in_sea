import 'package:equatable/equatable.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';

import '../model/calendar_source.dart';
import '../model/feed.dart';
import '../model/planner_event.dart';

/// Tri-state for a group checkbox.
enum CalendarGroupVisibility { all, none, some }

class CalendarVisibilityState extends Equatable {
  /// Hidden group ids (`group:*`) and leaf calendar ids. Absent = visible,
  /// so newly added calendars (Google, classes, future Finance ones) show
  /// by default and stale ids for deleted feeds are harmless.
  final Set<String> hiddenIds;

  const CalendarVisibilityState({this.hiddenIds = const {}});

  bool isHidden(String id) => hiddenIds.contains(id);

  bool get hasHidden => hiddenIds.isNotEmpty;

  CalendarVisibilityState copyWith({Set<String>? hiddenIds}) =>
      CalendarVisibilityState(hiddenIds: hiddenIds ?? this.hiddenIds);

  @override
  List<Object?> get props => [
        // Sorted for stable == across restores.
        [...hiddenIds]..sort(),
      ];
}

/// Per-device view filter: which calendars show in the calendar view.
///
/// Separate from [Feed.enabled] (which gates syncing): a feed can keep
/// syncing in the background while hidden from the calendar. New ids default
/// to visible; unknown ids are kept so prefs survive feed deletes/re-adds.
class CalendarVisibilityCubit extends HydratedCubit<CalendarVisibilityState> {
  CalendarVisibilityCubit() : super(const CalendarVisibilityState());

  bool isLeafVisible(String leafId, String groupId) =>
      !state.hiddenIds.contains(leafId) &&
      !state.hiddenIds.contains(groupId);

  bool isEventVisible(PlannerEvent event, Map<String, Feed> feedById) {
    final feed = feedById[event.feedId];
    final leafId = calendarLeafIdForEvent(event, feed);
    final groupId = groupIdForLeaf(leafId, feed);
    return isLeafVisible(leafId, groupId);
  }

  List<PlannerEvent> filterVisible(
    List<PlannerEvent> events,
    Map<String, Feed> feedById,
  ) =>
      events.where((e) => isEventVisible(e, feedById)).toList();

  CalendarGroupVisibility groupState(
    String groupId,
    List<String> childLeafIds,
  ) {
    if (state.hiddenIds.contains(groupId)) return CalendarGroupVisibility.none;
    if (childLeafIds.isEmpty) return CalendarGroupVisibility.all;
    var hidden = 0;
    for (final id in childLeafIds) {
      if (state.hiddenIds.contains(id)) hidden++;
    }
    if (hidden == 0) return CalendarGroupVisibility.all;
    if (hidden == childLeafIds.length) return CalendarGroupVisibility.none;
    return CalendarGroupVisibility.some;
  }

  void setLeafVisible(String leafId, bool visible) {
    final next = Set<String>.of(state.hiddenIds);
    if (visible) {
      if (!next.remove(leafId)) return;
    } else {
      if (!next.add(leafId)) return;
    }
    emit(state.copyWith(hiddenIds: next));
  }

  void toggleLeaf(String leafId) =>
      setLeafVisible(leafId, state.hiddenIds.contains(leafId));

  /// Toggling a group hides the group itself (cheap, covers future
  /// children) when everything is visible; otherwise it unhides the group
  /// and all its current children.
  void setGroupVisible(
    String groupId,
    List<String> childLeafIds,
    bool visible,
  ) {
    final next = Set<String>.of(state.hiddenIds);
    if (visible) {
      next.remove(groupId);
      for (final id in childLeafIds) {
        next.remove(id);
      }
    } else {
      next.add(groupId);
    }
    emit(state.copyWith(hiddenIds: next));
  }

  void toggleGroup(String groupId, List<String> childLeafIds) {
    final current = groupState(groupId, childLeafIds);
    setGroupVisible(
      groupId,
      childLeafIds,
      current != CalendarGroupVisibility.all,
    );
  }

  void showAll() {
    if (state.hiddenIds.isNotEmpty) {
      emit(const CalendarVisibilityState());
    }
  }

  @override
  CalendarVisibilityState? fromJson(Map<String, dynamic> json) {
    try {
      final raw = json['hiddenIds'];
      if (raw == null) return const CalendarVisibilityState();
      if (raw is! List) return const CalendarVisibilityState();
      final ids = <String>{};
      for (final item in raw) {
        if (item is String && item.isNotEmpty) ids.add(item);
      }
      return CalendarVisibilityState(hiddenIds: ids);
    } catch (_) {
      return const CalendarVisibilityState();
    }
  }

  @override
  Map<String, dynamic> toJson(CalendarVisibilityState state) => {
        'hiddenIds': [...state.hiddenIds]..sort(),
      };
}
