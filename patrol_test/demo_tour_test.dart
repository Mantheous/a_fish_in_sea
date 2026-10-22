import 'package:a_fish_in_sea/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';

class MockStorage extends Mock implements Storage {}

/// Demo tour end-to-end for issue #56: a signed-out visitor enters demo
/// mode from the auth page, sees the mock-data banner, exits, and lands
/// back on the auth page with no demo banner left behind.
///
/// The balance/estimates byte-identical restore is locked by the widget
/// test in test/demo/demo_mode_test.dart; this locks the visible flow
/// (the buttons a user actually taps).
///
/// Run headless (no server needed — demo is offline, like smoke_test):
///   patrol test --device chrome --web-headless \
///     --target patrol_test/demo_tour_test.dart \
///     --dart-define=SERVER_URL=http://127.0.0.1:8000
void main() {
  patrolTest('demo tour enters on mock data and exits cleanly', ($) async {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    await $.pumpWidgetAndSettle(const MyApp());

    await $('Try demo mode (no sign-in)').scrollTo();
    await $('Try demo mode (no sign-in)').tap();
    await $.pumpAndSettle();

    expect(
      $('Demo mode · mock data — nothing here is saved.').visible,
      true,
    );

    await $('Exit demo').tap();
    await $.pumpAndSettle();

    expect(
      $('Demo mode · mock data — nothing here is saved.').visible,
      false,
    );
    expect($('Try demo mode (no sign-in)').visible, true);
  });
}
