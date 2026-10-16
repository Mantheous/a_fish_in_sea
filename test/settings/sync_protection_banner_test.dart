import 'package:a_fish_in_sea/settings/view/settings_page.dart';
import 'package:a_fish_in_sea/sync/sync_meta_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../goldens/golden_app.dart';

/// The Settings → Sync data-loss protection banner: shown only when the
/// sync mass-deletion guard withheld deletions, and its restore action
/// clears the sync bookkeeping so the next pull re-downloads the cloud copy.
void main() {
  testWidgets('protection banner appears and restore clears bookkeeping',
      (tester) async {
    final engine = await pumpGoldenPage(tester, const SettingsPage());

    // No banner in the normal case.
    expect(find.textContaining('Sync held back deletions'), findsNothing);

    // Simulate a guarded sync (a device that lost local events).
    engine.meta.save(
      upsert: {
        'events/e1': const ItemMeta(hash: 'h', serverTime: 't'),
      },
    );
    engine.protectedDeletions.value = ['events'];
    await tester.pump();

    // The Sync section sits below the fold in the lazy settings list.
    // Scroll to the restore action itself: sections below Sync (e.g. API
    // tokens) may push the banner above the viewport when scrolling to
    // the sign-out button at the section's end.
    await tester.scrollUntilVisible(
      find.text('Restore missing items from cloud'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    expect(find.textContaining('Sync held back deletions'), findsOneWidget);
    expect(find.textContaining('events'), findsWidgets);
    final restore = find.text('Restore missing items from cloud');
    expect(restore, findsOneWidget);

    await tester.tap(restore);
    await tester.pump();

    // Restore resets the bookkeeping (the sync itself no-ops signed out).
    expect(engine.meta.state.items, isEmpty);
    expect(engine.meta.state.cursor, isNull);
  });
}
