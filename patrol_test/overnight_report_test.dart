import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:a_fish_in_sea/reporting/bloc/reporting_cubit.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  patrolTest('Day review title edit preserves an overnight report', ($) async {
    $.tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
      $.tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    await $.pumpWidgetAndSettle(const MyApp());
    final stamp = DateTime.now().microsecondsSinceEpoch;
    await $(TextField).at(0).enterText('patrol-overnight-$stamp@example.com');
    await $(TextField).at(1).enterText('patrol-pass-1');
    await $('Create account').tap();
    await $.pumpAndSettle();
    final context = $.tester.element(find.byType(HomePage));
    final reporting = context.read<ReportingCubit>();
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    final start = DateTime(day.year, day.month, day.day, 23);
    final end = DateTime(day.year, day.month, day.day + 1, 1);
    reporting.upsertEntry(
      day,
      ReportedEntry(
        id: 'overnight',
        title: 'Overnight work',
        start: start,
        end: end,
        status: ReportStatus.attended,
      ),
    );
    await $('Review').scrollTo().tap();
    await $.pumpAndSettle();
    await $('Overnight work').tap();
    await $.pumpAndSettle();
    await $(TextField).enterText('Overnight work renamed');
    await $('Save').tap();
    await $.pumpAndSettle();
    expect(reporting.entriesForDay(day).single.title, 'Overnight work renamed');
    expect(reporting.entriesForDay(day).single.start, start);
    expect(reporting.entriesForDay(day).single.end, end);
    expect(find.text('Overnight work renamed'), findsOneWidget);
  });
}
