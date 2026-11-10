import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/settings/view/settings_page.dart';
import 'package:a_fish_in_sea/sync/sync_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../goldens/golden_app.dart';

/// Settings → Sync sign-out dialog: the keep-or-remove choice, with Keep and
/// dismissal leaving local data alone and Remove wiping the visible cubits.
Future<void> openSignOutDialog(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('Sign out…'),
    400,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(find.text('Sign out…'));
  // Let the dialog entrance animation finish before asserting or goldening.
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

/// Flushes cubit debounce timers (e.g. WaterfallCubit's 50ms rebuild after
/// a node edit) so no timer is still pending when the tree is disposed.
Future<void> settleCubits(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('sign-out dialog golden', (tester) async {
    await pumpGoldenPage(tester, const SettingsPage());
    await openSignOutDialog(tester);
    expect(find.text('Keep on this device'), findsOneWidget);
    expect(find.text('Remove from this device'), findsOneWidget);
    await expectLater(
      find.byType(AlertDialog),
      matchesGoldenFile('sign_out_dialog.png'),
    );
  });

  testWidgets('Keep preserves local data, Remove wipes it', (tester) async {
    final SyncEngine engine =
        await pumpGoldenPage(tester, const SettingsPage());
    engine.nodes.addNode(
      Node(id: 't1', title: 'v1', createdAt: DateTime(2026)),
    );
    await settleCubits(tester);

    await openSignOutDialog(tester);
    await tester.tap(find.text('Keep on this device'));
    await settleCubits(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(engine.nodes.byId('t1')?.title, 'v1');

    await openSignOutDialog(tester);
    await tester.tap(find.text('Remove from this device'));
    await settleCubits(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(engine.nodes.byId('t1'), isNull);
  });

  testWidgets('dismissing the dialog changes nothing', (tester) async {
    final SyncEngine engine =
        await pumpGoldenPage(tester, const SettingsPage());
    engine.nodes.addNode(
      Node(id: 't1', title: 'v1', createdAt: DateTime(2026)),
    );
    await settleCubits(tester);

    await openSignOutDialog(tester);
    await tester.tapAt(const Offset(10, 10));
    await settleCubits(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(engine.nodes.byId('t1')?.title, 'v1');
  });
}
