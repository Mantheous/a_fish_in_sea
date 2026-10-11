import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/finances/model/granularity.dart';
import 'package:a_fish_in_sea/finances/model/ledger_entry.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

/// Persistence contract for [WaterfallState].
///
/// The AGENTS.md rule behind the first group: `HydratedMixin.hydrate()`
/// resets a cubit to empty AND overwrites storage when `fromJson` throws,
/// so a schema change that breaks parsing silently deletes user data on
/// the next boot. `fromJson` must therefore never throw on a plausible
/// payload — every field falls back to its default individually.
///
/// The second group covers the other half: [WaterfallState.buckets] is
/// derived, so it must never round-trip through storage or sync.
void main() {
  late Storage storage;

  setUp(() {
    storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  WaterfallCubit buildCubit() => WaterfallCubit(
        nodeCubit: NodeCubit(),
        transactionsCubit: TransactionsCubit(),
        plaidCubit: PlaidCubit(),
      );

  group('fromJson never throws on a plausible payload', () {
    test('wrong-typed numbers fall back to defaults', () {
      final cubit = buildCubit();
      final restored = cubit.fromJson({
        'startingBalance': 'not a number',
        'monthlyThresholdDays': '60',
        'weeklyThresholdDays': true,
      });
      expect(restored, isNotNull);
      expect(restored!.startingBalance, 0.0);
      expect(restored.monthlyThresholdDays, 60);
      expect(restored.weeklyThresholdDays, 7);
    });

    test('a string date, a number date and a bad date all fall back', () {
      final cubit = buildCubit();
      expect(cubit.fromJson({'projectionHorizon': 'not-a-date'}), isNotNull);
      expect(cubit.fromJson({'projectionHorizon': 42}), isNotNull);
      expect(cubit.fromJson({'projectionHorizon': null}), isNotNull);
    });

    test('an unknown viewScale falls back through orElse, not a throw', () {
      final cubit = buildCubit();
      final restored = cubit.fromJson({'viewScale': 'fortnightly'});
      expect(restored, isNotNull);
      expect(restored!.viewScale, TimeScale.monthly);
    });

    test('a completely empty payload still restores', () {
      final cubit = buildCubit();
      expect(cubit.fromJson(const {}), isNotNull);
    });

    test('a correct payload round-trips', () {
      final cubit = buildCubit();
      final json = {
        'startingBalance': 1234.5,
        'monthlyThresholdDays': 90,
        'weeklyThresholdDays': 14,
        'viewScale': 'weekly',
      };
      final restored = cubit.fromJson(json)!;
      expect(restored.startingBalance, 1234.5);
      expect(restored.monthlyThresholdDays, 90);
      expect(restored.weeklyThresholdDays, 14);
      expect(restored.viewScale, TimeScale.weekly);
      // And back out again: every value we put in comes back out.
      // (projectionHorizon is always emitted, which is why this is
      // field-wise rather than map equality.)
      final again = cubit.toJson(restored)!;
      expect(again['startingBalance'], 1234.5);
      expect(again['monthlyThresholdDays'], 90);
      expect(again['weeklyThresholdDays'], 14);
      expect(again['viewScale'], 'weekly');
      // Round-trips a second time to the same values.
      final twice = cubit.fromJson(again)!;
      expect(twice.monthlyThresholdDays, 90);
      expect(twice.weeklyThresholdDays, 14);
      expect(twice.viewScale, TimeScale.weekly);
    });
  });

  group('the derived buckets are never persisted', () {
    test('toJson carries no buckets key', () {
      final cubit = buildCubit();
      final state = WaterfallState(
        projectionHorizon: DateTime(2027, 1, 1),
        buckets: [
          LedgerBucket(
            granularity: DisplayGranularity.monthly,
            bucketStart: DateTime(2027, 1, 1),
            entries: [
              LedgerEntry(
                sourceId: 'x',
                name: 'x',
                amount: -1,
                date: DateTime(2027, 1, 2),
                type: EntryType.expense,
              ),
            ],
          ),
        ],
      );
      final json = cubit.toJson(state)!;
      expect(json.containsKey('buckets'), isFalse);
      // And restoring it yields empty buckets — they are recomputed by
      // rebuild(), never carried over the wire.
      final restored = cubit.fromJson(json)!;
      expect(restored.buckets, isEmpty);
    });

    test('applySyncedConfig cannot import buckets', () {
      final cubit = buildCubit();
      cubit.applySyncedConfig({
        'startingBalance': 10.0,
        'monthlyThresholdDays': 30,
      });
      expect(cubit.state.startingBalance, 10.0);
      expect(cubit.state.monthlyThresholdDays, 30);
      expect(cubit.state.buckets, isEmpty);
    });
  });
}
