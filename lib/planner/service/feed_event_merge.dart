import '../model/planner_event.dart';

/// Keeps user-owned metadata when a fresh feed copy replaces an event.
PlannerEvent preserveLocalFeedMetadata(
  PlannerEvent fresh,
  PlannerEvent previous,
) => fresh.copyWith(
  reminderMinutesBefore: previous.reminderMinutesBefore,
  tagIds: previous.tagIds,
);
