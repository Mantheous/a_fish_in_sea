import 'package:flutter/material.dart';

/// How long the calendar's drag/resize undo prompt stays up.
const calendarUndoPromptDuration = Duration(seconds: 2);

/// Shows the calendar's one undo prompt, replacing any prompt already up.
///
/// Action snackbars persist forever by default (`persist` follows the
/// presence of an action), and queued drags would otherwise stack into a
/// prompt that never leaves the screen. Every calendar undo prompt goes
/// through here so they all dismiss on the same short timer.
void showCalendarUndoSnackBar({
  required ScaffoldMessengerState messenger,
  required String message,
  required VoidCallback onUndo,
}) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: calendarUndoPromptDuration,
        persist: false,
        action: SnackBarAction(label: 'Undo', onPressed: onUndo),
      ),
    );
}
