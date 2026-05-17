import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:plaid_flutter/plaid_flutter.dart';

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

  /// Runs Link and returns the public token on success, or null if the user
  /// exited or Link is unavailable.
  static Future<String?> open(String linkToken) async {
    if (!isSupported) return null;

    final completer = Completer<String?>();
    late final StreamSubscription<LinkSuccess> successSub;
    late final StreamSubscription<LinkExit> exitSub;

    void cleanup() {
      successSub.cancel();
      exitSub.cancel();
    }

    successSub = PlaidLink.onSuccess.listen((event) {
      if (!completer.isCompleted) {
        completer.complete(event.publicToken);
      }
      cleanup();
    });

    exitSub = PlaidLink.onExit.listen((_) {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
      cleanup();
    });

    final configuration = LinkTokenConfiguration(token: linkToken);
    await PlaidLink.create(configuration: configuration);
    await PlaidLink.open();

    return completer.future;
  }
}
