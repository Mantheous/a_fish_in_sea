import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
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

  for (final initialFixed in [false, true]) {
    testWidgets(
      'fixed amount toggle from $initialFixed survives restore and amount save',
      (tester) async {
        final f = RecurringPaymentFixture();
        await f.pump(tester, isFixed: initialFixed);
        final protectedBefore = {
          for (final n in f.nodes.state.where((n) => n.isInstance))
            if (!f.refreshedIds.contains(n.id)) n.id: n,
        };

        await f.edit(tester, amount: null, toggleFixed: true);

        expect(f.nodes.byId(f.template.id)!.money!.isFixed, !initialFixed);
        for (final entry in protectedBefore.entries) {
          expect(f.nodes.byId(entry.key), entry.value);
        }
        for (final id in f.refreshedIds) {
          expect(f.nodes.byId(id)!.money!.isFixed, !initialFixed);
          expect(f.nodes.byId(id)!.money!.targetAmount, 100);
        }
        _restore(f);
        await tester.pumpAndSettle();
        f.before = List.of(f.nodes.state);
        f.undo.resetHistory();
        final emissions = <Object>[];
        f.nodes.stream.listen(emissions.add);

        await f.edit(tester);

        expect(emissions, hasLength(1));
        f.verify();
        final saved = List.of(f.nodes.state);
        f.verifyUndo();
        expect(f.nodes.state, saved);
        f.verify();
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'period-only editor save survives restore and later amount save',
    (tester) async {
      final f = RecurringPaymentFixture();
      await f.pump(
        tester,
        money: const MoneyFacet(targetAmount: 100, period: TimeScale.monthly),
      );
      final protectedBefore = {
        for (final n in f.nodes.state.where((n) => n.isInstance))
          if (!f.refreshedIds.contains(n.id)) n.id: n,
      };

      await f.edit(tester, amount: null, period: TimeScale.weekly);

      expect(f.nodes.byId(f.template.id)!.money!.period, TimeScale.weekly);
      for (final entry in protectedBefore.entries) {
        expect(f.nodes.byId(entry.key), entry.value);
      }
      for (final id in f.refreshedIds) {
        expect(f.nodes.byId(id)!.money!.period, TimeScale.weekly);
        expect(f.nodes.byId(id)!.money!.targetAmount, 100);
      }
      _restore(f);
      await tester.pumpAndSettle();
      f.before = List.of(f.nodes.state);
      f.undo.resetHistory();
      final emissions = <Object>[];
      f.nodes.stream.listen(emissions.add);

      await f.edit(tester);

      expect(emissions, hasLength(1));
      f.verify();
      final saved = List.of(f.nodes.state);
      f.verifyUndo();
      expect(f.nodes.state, saved);
      f.verify();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'time-target editor save survives restore and later amount save',
    (tester) async {
      final f = RecurringPaymentFixture();
      await f.pump(tester);
      // Legacy unmarked time edits must stay protected too.
      final legacy = f.nodes.instancesOf(f.template.id)[6];
      f.nodes.writeNodes(
        upserts: [
          legacy.copyWith(
            effort: const EffortFacet(targetMinutes: 45),
            overriddenFields: {},
          ),
        ],
      );
      final protectedBefore = {
        for (final n in f.nodes.state.where((n) => n.isInstance))
          if (!f.refreshedIds.contains(n.id)) n.id: n,
      };

      await f.edit(tester, amount: null, targetMinutes: '30');

      const effort = EffortFacet(targetMinutes: 30);
      expect(f.nodes.byId(f.template.id)!.effort, effort);
      for (final entry in protectedBefore.entries) {
        expect(f.nodes.byId(entry.key), entry.value);
      }
      _restore(f);
      await tester.pumpAndSettle();
      f.before = List.of(f.nodes.state);
      f.undo.resetHistory();
      final emissions = <Object>[];
      f.nodes.stream.listen(emissions.add);

      await f.edit(tester);

      expect(emissions, hasLength(1));
      f.verify();
      for (final id in f.refreshedIds) {
        expect(f.nodes.byId(id)!.effort, effort);
      }
      final saved = List.of(f.nodes.state);
      f.verifyUndo();
      expect(f.nodes.state, saved);
      f.verify();
      await tester.pumpAndSettle();
    },
  );

  final settings = <String, MoneyFacet Function(MoneyFacet)>{
    'custom period length': (m) => m.copyWith(customPeriodDays: 120),
    'clearing custom period': (m) =>
        m.copyWith(period: TimeScale.monthly, clearCustomPeriod: true),
    'clearing period': (m) =>
        m.copyWith(clearPeriod: true, clearCustomPeriod: true),
    'income direction': (m) => m.copyWith(direction: MoneyDirection.income),
    'saving direction': (m) => m.copyWith(direction: MoneyDirection.save),
    'auto rollover': (m) => m.copyWith(autoRollover: true),
  };
  for (final setting in settings.entries) {
    testWidgets('${setting.key} keeps restored future amounts fresh', (
      tester,
    ) async {
      final f = RecurringPaymentFixture();
      await f.pump(
        tester,
        money: const MoneyFacet(
          targetAmount: 100,
          period: TimeScale.custom,
          customPeriodDays: 90,
        ),
      );
      // An unmarked legacy setting edit must also keep the whole copy protected.
      final legacy = f.nodes.instancesOf(f.template.id)[6];
      f.nodes.writeNodes(
        upserts: [
          legacy.copyWith(
            money: legacy.money!.copyWith(customPeriodDays: 7),
            overriddenFields: {},
          ),
        ],
      );
      final protectedBefore = {
        for (final n in f.nodes.state.where((n) => n.isInstance))
          if (!f.refreshedIds.contains(n.id)) n.id: n,
      };
      final money = setting.value(f.template.money!);

      expect(f.nodes.updateNode(f.template.copyWith(money: money)), isNull);

      for (final entry in protectedBefore.entries) {
        expect(f.nodes.byId(entry.key), entry.value);
      }
      for (final id in f.refreshedIds) {
        expect(f.nodes.byId(id)!.money, money);
      }
      _restore(f);
      await tester.pumpAndSettle();
      f.before = List.of(f.nodes.state);
      f.oldBalance = f.waterfall.state.rows
          .singleWhere((r) => r.sourceId == f.refreshedId)
          .runningBalance;
      f.undo.resetHistory();
      final emissions = <Object>[];
      f.nodes.stream.listen(emissions.add);

      await f.edit(tester);

      expect(emissions, hasLength(1));
      f.verify();
      final saved = List.of(f.nodes.state);
      f.verifyUndo();
      expect(f.nodes.state, saved);
      f.verify();
      await tester.pumpAndSettle();
    });
  }

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
