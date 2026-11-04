import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:patrol/patrol.dart';

import '../test/support/recurring_payment_fixture.dart';

void main() {
  patrolTest(
    'recurring payment edit preserves concrete and hand edited copies',
    ($) async {
      final client = SyncClient(
        serverBase: () => const String.fromEnvironment(
          'SERVER_URL',
          defaultValue: 'http://127.0.0.1:8000',
        ),
        accessToken: () => null,
        refreshAccessToken: () async => null,
      );
      await client.register(
        'patrol-recurring-${DateTime.now().microsecondsSinceEpoch}@example.com',
        'patrol-pass-1',
      );
      final f = RecurringPaymentFixture();
      await f.pump($.tester);
      await f.edit($.tester);
      f.verify();
      f.verifyUndo();
    },
  );
}
