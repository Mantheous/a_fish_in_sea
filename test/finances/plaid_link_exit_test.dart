import 'package:a_fish_in_sea/finances/service/plaid_link_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('plaidExitMessage', () {
    test('prefers the Plaid error message with code', () {
      const result = PlaidLinkResult(
        exitErrorCode: 'INSTITUTION_ERROR',
        exitErrorMessage: 'Institution login failed',
      );
      final message = plaidExitMessage(result);
      expect(message, contains('INSTITUTION_ERROR'));
      expect(message, contains('Institution login failed'));
    });

    test('account-selection exit tells the user to select accounts', () {
      for (final status in [
        'requiresAccountSelection',
        'requires_account_selection',
      ]) {
        final message = plaidExitMessage(PlaidLinkResult(exitStatus: status));
        expect(message, contains('no accounts were selected'),
            reason: 'status=$status');
      }
    });

    test('credentials exit tells the user to finish signing in', () {
      for (final status in ['requiresCredentials', 'requires_credentials']) {
        final message = plaidExitMessage(PlaidLinkResult(exitStatus: status));
        expect(message, contains('not completed'), reason: 'status=$status');
      }
    });

    test('institution name is mentioned when known', () {
      const result = PlaidLinkResult(
        institutionName: 'Chase',
        exitStatus: 'requiresCredentials',
      );
      // Explicit error statuses win; generic institution exit names the bank.
      expect(
        plaidExitMessage(const PlaidLinkResult(institutionName: 'Chase')),
        contains('Chase'),
      );
      expect(plaidExitMessage(result), isNotEmpty);
    });

    test('plain exit still gives an actionable message', () {
      final message = plaidExitMessage(const PlaidLinkResult());
      expect(message, contains('selecting accounts'));
    });
  });

  group('PlaidLinkResult.toTelemetry', () {
    test('omits null fields', () {
      const result = PlaidLinkResult(exitStatus: 'requiresCredentials');
      final telemetry = result.toTelemetry();
      expect(telemetry['succeeded'], isFalse);
      expect(telemetry['exit_status'], 'requiresCredentials');
      expect(telemetry.containsKey('error_code'), isFalse);
    });

    test('success carries the token flag', () {
      const result = PlaidLinkResult(publicToken: 'public-123');
      expect(result.succeeded, isTrue);
      expect(result.toTelemetry()['succeeded'], isTrue);
    });
  });
}
