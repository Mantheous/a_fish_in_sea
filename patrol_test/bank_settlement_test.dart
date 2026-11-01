import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:patrol/patrol.dart';

import '../test/support/bank_settlement_fixture.dart';

void main() {
  patrolTest('bank sync retains settled purchase in its budget exactly once', (
    $,
  ) async {
    final f = BankSettlementFixture();
    final client = SyncClient(
      serverBase: () => const String.fromEnvironment(
        'SERVER_URL',
        defaultValue: 'http://127.0.0.1:8000',
      ),
      accessToken: () => null,
      refreshAccessToken: () async => null,
    );
    // Authenticate against the dev API; bank responses are deterministic
    // because real Plaid sandbox purchases cannot be forced to settle.
    await client.register(
      'patrol-settlement-${DateTime.now().microsecondsSinceEpoch}@example.com',
      'patrol-pass-1',
    );
    await f.pump($.tester);
    await $('Sync Transactions').tap();
    await $.pumpAndSettle();
    f.verify();
    await $('Sync Transactions').tap();
    await $.pumpAndSettle();
    f.verify();
  });
}
