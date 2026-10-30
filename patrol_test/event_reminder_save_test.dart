import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/view/event_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';

class _Storage extends Mock implements Storage {}

void main() {
  // Chrome covers save/edit without Android permissions. The Android method
  // channel and denial warning are covered by event_reminder_delivery_test.
  patrolTest('appointment reminder survives saving and reopening', ($) async {
    $.tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
      $.tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );
    final storage = _Storage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    await $.pumpWidgetAndSettle(const MyApp());
    final stamp = DateTime.now().millisecondsSinceEpoch;
    await $(TextField).at(0).enterText('patrol-reminder-$stamp@example.com');
    await $(TextField).at(1).enterText('patrol-pass-1');
    await $('Create account').tap();
    await $(HomePage).waitUntilVisible();
    final context = $.tester.element(find.byType(HomePage));
    final calendar = context.read<CalendarCubit>();
    final title = 'Appointment $stamp';
    final editor = showEventEditor(
      context,
      initialSubject: title,
      initialDate: DateTime.now().add(const Duration(days: 1)),
    );
    await $.pumpAndSettle();
    final reminder = find.byType(DropdownButtonFormField<int?>);
    await $.tester.ensureVisible(reminder);
    await $.tester.tap(reminder);
    await $.pumpAndSettle();
    await $('10 minutes before').tap();
    await $.pumpAndSettle();
    await $('Add').tap();
    await $.pumpAndSettle();
    expect(await editor, isTrue);
    final saved = calendar.state.singleWhere((event) => event.subject == title);
    expect(saved.reminderMinutesBefore, 10);
    final reopened = showEventEditor(context, existing: saved);
    await $.pumpAndSettle();
    await $.tester.ensureVisible(find.byType(DropdownButtonFormField<int?>));
    expect($('10 minutes before').visible, true);
    await $('Cancel').tap();
    await $.pumpAndSettle();
    await reopened;
    expect(calendar.byId(saved.id)?.reminderMinutesBefore, 10);
  });
}
