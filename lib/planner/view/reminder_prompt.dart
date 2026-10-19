import 'package:flutter/material.dart';

import '../bloc/calendar_cubit.dart';
import '../model/planner_event.dart';
import '../service/appointment_heuristic.dart';
import '../service/event_reminders.dart';

/// Post-save nudge for issue #3: a one-off event that looks like an
/// appointment gets a "want a reminder?" prompt. Returns silently when the
/// event does not qualify (repeating, all-day, chore-like, reminder already
/// set, or starting in the past).
Future<void> maybePromptForEventReminder(
  BuildContext context,
  PlannerEvent saved, {
  required CalendarCubit calendar,
}) async {
  if (!shouldPromptForReminder(saved)) return;
  if (!context.mounted) return;
  final picked = await showDialog<int?>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('Set a reminder?'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(
            'This looks like an appointment. '
            'Want a notification before "${saved.subject}" starts?',
            style: Theme.of(dialogContext).textTheme.bodyMedium,
          ),
        ),
        for (final minutes in promptReminderChoices)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(minutes),
            child: Text(eventReminderLabel(minutes)),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(dialogContext).pop(null),
          child: const Text('No thanks'),
        ),
      ],
    ),
  );
  if (picked == null || picked <= 0) return;
  final current = calendar.byId(saved.id);
  if (current == null) return;
  final updated = current.copyWith(reminderMinutesBefore: picked);
  calendar.updateEvent(updated);
  await EventReminderService.scheduleReminder(updated);
}

/// Dropdown used by the event editor to pick a local reminder offset.
/// Reminders are device-local (never pushed to Google) and scheduled with
/// flutter_local_notifications on save.
class ReminderField extends StatelessWidget {
  final int? value;
  final ValueChanged<int?> onChanged;

  const ReminderField({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    // Non-preset offsets (e.g. 15 from the post-save prompt, or values from
    // older builds) would crash DropdownButtonFormField because initialValue
    // must match exactly one item. Surface them as an extra item so the edit
    // form still mounts and Delete stays reachable.
    final effectiveValue =
        (value != null && value! <= 0) ? null : value;
    final extraValue =
        (effectiveValue != null && !eventReminderChoices.contains(effectiveValue))
            ? effectiveValue
            : null;
    return DropdownButtonFormField<int?>(
      initialValue: effectiveValue,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Reminder',
        border: OutlineInputBorder(),
        helperText: 'Device-local notification before the event',
      ),
      items: [
        const DropdownMenuItem(value: null, child: Text('No reminder')),
        if (extraValue != null)
          DropdownMenuItem(
            value: extraValue,
            child: Text(eventReminderLabel(extraValue)),
          ),
        for (final minutes in eventReminderChoices)
          DropdownMenuItem(
            value: minutes,
            child: Text(eventReminderLabel(minutes)),
          ),
      ],
      onChanged: onChanged,
    );
  }
}
