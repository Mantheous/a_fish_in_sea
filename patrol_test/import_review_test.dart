import 'dart:convert';

import 'package:a_fish_in_sea/imports/view/import_review_screen.dart';
import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';

class MockStorage extends Mock implements Storage {}

/// Import review end-to-end (issue #66): approving one staged row must not
/// wipe the "updates existing" warnings on the remaining rows.
///
/// Run against the live dev API server:
///   patrol test --device chrome --web-headless \
///     --target patrol_test/import_review_test.dart \
///     --dart-define=SERVER_URL=http://127.0.0.1:8000
///
/// Uses a unique email per run so reruns never 409. Leaves one junk
/// account plus one junk import batch per run on the dev server.
void main() {
  patrolTest('approving one row keeps warnings on the rest', ($) async {
    const base = String.fromEnvironment('SERVER_URL',
        defaultValue: 'http://127.0.0.1:8000');
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final email = 'patrol-import-$stamp@example.com';
    const password = 'patrol-pass-1';
    final keepId = 'patrol-keep-$stamp';
    final freshId = 'patrol-fresh-$stamp';

    Future<dynamic> post(String path, Map<String, dynamic> body,
        {String? token}) async {
      final res = await http.post(
        Uri.parse('$base/api/v1$path'),
        headers: {
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: jsonEncode(body),
      );
      assert(res.statusCode < 300, '$path: ${res.statusCode} ${res.body}');
      return jsonDecode(res.body);
    }

    // Seed the server BEFORE the app launches: a live row, then a staged
    // batch where one row collides with it and one is brand new.
    final reg = await post('/auth/register',
        {'email': email, 'password': password}) as Map<String, dynamic>;
    final jwt = reg['access_token'] as String;
    Map<String, dynamic> node(String id, String title, String due) => {
          'collection': 'nodes',
          'item_id': id,
          'data': {
            'id': id,
            'title': title,
            'status': 'open',
            'schedule': {'due': due}
          },
        };
    await post('/sync/push', {
      'changes': [node(keepId, 'Patrol keep', '2026-10-15T23:59:00')]
    }, token: jwt);
    final created = await post('/tokens',
        {'name': 'patrol import', 'scopes': ['sync'], 'review': true},
        token: jwt) as Map<String, dynamic>;
    await post(
        '/imports',
        {
          'items': [
            node(freshId, 'Patrol fresh', '2026-10-20T23:59:00'),
            node(keepId, 'Patrol keep (rescheduled)', '2026-10-17T23:59:00'),
          ],
          'source': 'patrol',
        },
        token: created['token'] as String);

    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    await $.pumpWidgetAndSettle(const MyApp());

    await $(TextField).at(0).enterText(email);
    await $(TextField).at(1).enterText(password);
    await $('Sign in').tap();
    await $.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);

    // The inbox card announces the staged batch; open the review screen.
    await $('Import received: 2 items to review').scrollTo();
    await $('Import received: 2 items to review').tap();
    await $.pumpAndSettle();
    expect(find.byType(ImportReviewScreen), findsOneWidget);
    expect(find.textContaining('Updates existing'), findsOneWidget);

    // Approve the first (fresh) row; the colliding row keeps its warning.
    await $(Icons.check).at(0).tap();
    await $.pumpAndSettle();

    expect(find.text('Added'), findsOneWidget);
    expect(find.textContaining('Updates existing'), findsOneWidget);
    expect(find.textContaining('go through'), findsNothing);
  });
}
