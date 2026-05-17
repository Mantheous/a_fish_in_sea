import 'dart:math';

/// Stable per-install identifier sent to the Plaid backend.
///
/// Each app install gets its own id so multiple developers can connect
/// different sandbox banks without sharing one in-memory access token.
class PlaidUserId {
  static String generate() {
    final random = Random.secure();
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(24, (_) => chars[random.nextInt(chars.length)]).join();
  }
}
