import 'package:a_fish_in_sea/settings/view/api_tokens_section.dart';
import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Auth extends Mock implements AuthCubit {}

class _Client extends Mock implements SyncClient {}

void main() {
  for (final readOnly in [false, true]) {
    testWidgets('calendar key uses narrow scopes (readOnly=$readOnly)', (
      tester,
    ) async {
      final auth = _Auth();
      final client = _Client();
      when(
        () => auth.stream,
      ).thenAnswer((_) => const Stream<AuthState>.empty());
      when(() => auth.state).thenReturn(const AuthState());
      when(() => auth.syncClient).thenReturn(client);
      when(() => client.baseUrl).thenReturn('https://calendar.example/fish');
      when(() => client.listApiTokens()).thenAnswer((_) async => []);
      when(
        () => client.createApiToken(
          name: any(named: 'name'),
          scopes: any(named: 'scopes'),
          review: any(named: 'review'),
        ),
      ).thenAnswer(
        (_) async => (
          info: const ApiToken(
            id: 1,
            name: 'Muse',
            prefix: 'afm_test',
            scopes: ['calendar:read'],
            review: false,
          ),
          token: 'afm_one_time_secret',
        ),
      );
      await tester.pumpWidget(
        BlocProvider<AuthCubit>.value(
          value: auth,
          child: const MaterialApp(home: Scaffold(body: ApiTokensSection())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create token'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Muse');
      if (readOnly) {
        await tester.tap(find.text('Read only'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      verify(
        () => client.createApiToken(
          name: 'Muse',
          review: false,
          scopes: [readOnly ? 'calendar:read' : 'calendar:write'],
        ),
      ).called(1);
      expect(find.text('https://calendar.example/fish/mcp/'), findsOneWidget);
      expect(find.text('afm_one_time_secret'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('afm_one_time_secret'), findsNothing);
    });
  }
}
