import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:plaid_flutter/plaid_flutter.dart';

/// Outcome of one Plaid Link session.
///
/// Previously this layer returned just the public token (or null), which
/// silently discarded the exit reason — a completed-looking bank auth that
/// ended in [LinkExit] (backed out before selecting accounts, OAuth
/// handoff not finished, institution error, …) looked identical to "never
/// tried", and the app just showed the Connect button again.
class PlaidLinkResult {
  const PlaidLinkResult({
    this.publicToken,
    this.exitErrorCode,
    this.exitErrorMessage,
    this.exitStatus,
    this.institutionName,
  });

  /// Non-null when the user fully completed Link (accounts selected).
  final String? publicToken;

  /// Plaid error code from [LinkExit.error], if Link reported one.
  final String? exitErrorCode;

  /// Human-readable error from [LinkExit.error], if any.
  final String? exitErrorMessage;

  /// Exit metadata status (e.g. `requires_account_selection`,
  /// `requires_credentials`), if reported.
  final String? exitStatus;

  /// Institution the user had selected when exiting, if reported.
  final String? institutionName;

  bool get succeeded => publicToken != null;

  /// Short machine-readable summary for server telemetry.
  Map<String, dynamic> toTelemetry() => {
        'succeeded': succeeded,
        if (exitErrorCode != null) 'error_code': exitErrorCode,
        if (exitErrorMessage != null) 'error_message': exitErrorMessage,
        if (exitStatus != null) 'exit_status': exitStatus,
        if (institutionName != null) 'institution_name': institutionName,
      };
}

/// User-facing explanation for a Link session that did not produce a
/// public token. Pure so it can be unit-tested.
String plaidExitMessage(PlaidLinkResult result) {
  if (result.exitErrorMessage != null &&
      result.exitErrorMessage!.isNotEmpty) {
    final code = result.exitErrorCode?.isNotEmpty == true
        ? ' (${result.exitErrorCode})'
        : '';
    return 'Bank linking failed$code: ${result.exitErrorMessage}';
  }
  switch (result.exitStatus) {
    // Mobile SDKs report camelCase, Plaid.js reports snake_case.
    case 'requiresAccountSelection':
    case 'requires_account_selection':
      return 'Bank login finished but no accounts were selected. '
          'Tap Connect again and select at least one account, then Continue.';
    case 'requiresCredentials':
    case 'requires_credentials':
      return 'Bank login was not completed. Tap Connect again and finish '
          'signing in to your bank.';
  }
  if (result.institutionName?.isNotEmpty == true) {
    return 'Left bank linking at ${result.institutionName} before any '
        'accounts were connected. Tap Connect again and complete all steps, '
        'including selecting accounts and tapping Continue.';
  }
  return 'Bank linking ended before any accounts were connected. '
      'Tap Connect again and complete all steps in Plaid Link, including '
      'selecting accounts and tapping Continue.';
}

/// Opens Plaid Link on supported platforms (iOS, Android, Web).
class PlaidLinkHandler {
  /// Whether the native / web Plaid Link SDK is available on this platform.
  static bool get isSupported {
    if (kIsWeb) return true;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return true;
      default:
        return false;
    }
  }

  /// Runs Link and returns the session result: a public token on success,
  /// or the exit reason when the user leaves Link without connecting.
  static Future<PlaidLinkResult> open(String linkToken) async {
    if (!isSupported) {
      return const PlaidLinkResult(exitStatus: 'unsupported_platform');
    }

    final completer = Completer<PlaidLinkResult>();
    late final StreamSubscription<LinkSuccess> successSub;
    late final StreamSubscription<LinkExit> exitSub;

    void cleanup() {
      successSub.cancel();
      exitSub.cancel();
    }

    successSub = PlaidLink.onSuccess.listen((event) {
      if (!completer.isCompleted) {
        completer.complete(
          PlaidLinkResult(publicToken: event.publicToken),
        );
      }
      cleanup();
    });

    exitSub = PlaidLink.onExit.listen((event) {
      if (!completer.isCompleted) {
        // displayMessage is the user-friendly text when Plaid provides it.
        final message = event.error?.displayMessage?.isNotEmpty == true
            ? event.error!.displayMessage
            : event.error?.message;
        completer.complete(PlaidLinkResult(
          exitErrorCode: event.error?.code,
          exitErrorMessage:
              message?.isNotEmpty == true ? message : null,
          exitStatus: event.metadata.status,
          institutionName:
              event.metadata.institution?.name.isNotEmpty == true
                  ? event.metadata.institution!.name
                  : null,
        ));
      }
      cleanup();
    });

    final configuration = LinkTokenConfiguration(token: linkToken);
    await PlaidLink.create(configuration: configuration);
    await PlaidLink.open();

    return completer.future;
  }
}
