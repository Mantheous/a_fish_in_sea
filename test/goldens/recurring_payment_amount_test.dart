import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/recurring_payment_fixture.dart';

void main() {
  testWidgets(
    'recurring amount save refreshes only untouched future payments',
    (tester) async {
      final f = RecurringPaymentFixture();
      await f.pump(tester);
      final emissions = <Object>[];
      // The fixture closes the cubit and its broadcast stream in tearDown.
      f.nodes.stream.listen(emissions.add);
      await f.edit(tester);

      expect(emissions, hasLength(1));
      f.verify();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('recurring_payment_amount.png'),
      );
      f.verifyUndo();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'renaming a recurring payment before its amount still refreshes forecasts',
    (tester) async {
      final f = RecurringPaymentFixture();
      await f.pump(tester);
      expect(
        f.nodes.updateNode(f.template.copyWith(title: 'Monthly rent')),
        isNull,
      );
      expect(f.nodes.byId(f.refreshedId)!.title, 'Monthly rent');
      _restore(f);
      await tester.pumpAndSettle();
      f.before = List.of(f.nodes.state);
      f.undo.resetHistory();
      final emissions = <Object>[];
      f.nodes.stream.listen(emissions.add);

      await f.edit(tester);

      expect(emissions, hasLength(1));
      expect(f.nodes.byId(f.template.id)!.title, 'Monthly rent');
      f.verify();
      f.verifyUndo();
      expect(f.nodes.byId(f.template.id)!.title, 'Monthly rent');
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'amount save preserves restored unmarked individual title edits',
    (tester) async {
      final f = RecurringPaymentFixture();
      await f.pump(tester);
      final customId = f.nodes.instancesOf(f.template.id)[10].id;
      _restore(
        f,
        legacyText: {
          customId: {'title': 'My special rent payment'},
        },
      );
      expect(f.nodes.byId(customId)!.overriddenFields, isEmpty);
      expect(f.nodes.byId(customId)!.money!.targetAmount, 100);
      f.before = List.of(f.nodes.state);
      f.undo.resetHistory();

      await f.edit(tester);

      f.verify();
      expect(f.nodes.byId(customId)!.title, 'My special rent payment');
      expect(f.nodes.byId(customId)!.money!.targetAmount, 100);
      f.verifyUndo();
      await tester.pumpAndSettle();
    },
  );

  for (final initialNotes in [null, 'Original payment notes']) {
    testWidgets(
      'template notes change from $initialNotes keeps forecasts fresh',
      (tester) async {
        final f = RecurringPaymentFixture();
        await f.pump(tester, notes: initialNotes);
        final copies = f.nodes.instancesOf(f.template.id);
        final legacyTitleId = copies[10].id;
        final legacyNotesId = copies[6].id;
        _restore(
          f,
          legacyText: {
            legacyTitleId: {'title': 'My special rent payment'},
            legacyNotesId: {'notes': 'My individual payment notes'},
          },
        );
        final protectedBefore = {
          for (final n in f.nodes.state.where((n) => n.isInstance))
            if (!f.refreshedIds.contains(n.id)) n.id: n,
        };
        final newNotes = initialNotes == null ? 'Updated payment notes' : null;
        expect(
          f.nodes.updateNode(
            f.template.copyWith(notes: newNotes, clearNotes: newNotes == null),
          ),
          isNull,
        );
        for (final entry in protectedBefore.entries) {
          expect(f.nodes.byId(entry.key), entry.value);
        }
        for (final id in f.refreshedIds) {
          expect(f.nodes.byId(id)!.notes, newNotes);
          expect(f.nodes.byId(id)!.money!.targetAmount, 100);
        }
        // Re-read serialized state: the subsequent amount save cannot rely on
        // in-memory template history to distinguish inherited and custom text.
        _restore(f);
        await tester.pumpAndSettle();
        f.before = List.of(f.nodes.state);
        f.undo.resetHistory();
        final emissions = <Object>[];
        f.nodes.stream.listen(emissions.add);

        await f.edit(tester);

        expect(emissions, hasLength(1));
        f.verify();
        f.verifyUndo();
        expect(f.nodes.byId(f.template.id)!.notes, newNotes);
        await tester.pumpAndSettle();
      },
    );
  }
}

void _restore(
  RecurringPaymentFixture f, {
  Map<String, Map<String, Object?>> legacyText = const {},
}) {
  final json = f.nodes.toJson(f.nodes.state);
  for (final row in json['nodes'] as List) {
    final edits = legacyText[row['id']];
    if (edits != null) {
      row.addAll(edits);
      row.remove('overriddenFields');
    }
  }
  f.nodes.emitSilent(f.nodes.fromJson(json)!);
}
