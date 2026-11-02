import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/node_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_app.dart';

void main() {
  for (final frequency in [
    TimeScale.custom,
    TimeScale.weekly,
    TimeScale.monthly,
  ]) {
    testWidgets('rename preserves $frequency recurrence through restore', (
      tester,
    ) async {
      final recurrence = NodeRecurrence(
        frequency: frequency,
        customPeriodDays: 14,
        dayOfWeek: DateTime.friday,
        dayOfMonth: 23,
        endDate: DateTime(2027, 12, 31),
      );
      final original = Node(
        id: 'payment',
        title: 'Payment',
        createdAt: DateTime(2026, 11, 2),
        recurrence: recurrence,
      );
      await pumpGoldenPage(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showNodeEditor(
              context,
              existing: context.read<NodeCubit>().byId(original.id),
            ),
            child: const Text('Open goal'),
          ),
        ),
      );
      final nodes = tester.element(find.text('Open goal')).read<NodeCubit>();
      expect(nodes.addNode(original), isNull);
      await tester.tap(find.text('Open goal'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        'Renamed payment',
      );
      if (frequency == TimeScale.custom) {
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byType(DropdownButtonFormField<TimeScale>).last,
        );
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('node_editor_recurrence.png'),
        );
      }
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final restored = Node.fromJson(nodes.byId(original.id)!.toJson());
      expect(restored.title, 'Renamed payment');
      expect(restored.recurrence, recurrence);
      expect(tester.takeException(), isNull);
      if (frequency == TimeScale.custom) {
        expect(nodes.updateNode(restored), isNull);
        nodes.generateInstances(
          templateId: original.id,
          from: DateTime(2027, 1, 2),
          horizon: DateTime(2027, 1, 31),
        );
        expect(nodes.instancesOf(original.id).map((n) => n.schedule?.due), [
          DateTime(2027, 1, 2),
          DateTime(2027, 1, 16),
          DateTime(2027, 1, 30),
        ]);
      }
    });
  }
}
