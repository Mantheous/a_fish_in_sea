import 'package:flutter/foundation.dart';

/// The ONE backend this app talks to.
///
/// Industry standard: the app pairs with a fixed server address baked in
/// at build time — never a per-device override. (A stored per-device URL
/// caused real lock-outs: reinstalls kept a stale address that overrode
/// the current server and pointed sign-in at a retired backend.)
///
/// Override at build/run time when the server runs on another host:
/// `flutter run --dart-define=SERVER_URL=http://192.168.1.10:8000`
/// (the legacy `PLAID_SERVER_URL` define still works as a fallback).
///
/// The default is the Tailscale Funnel HTTPS endpoint (publicly-trusted
/// Let's Encrypt cert, proxied to the API server), so auth tokens and
/// bank data are never sent in cleartext. Only use an `http://` override
/// for local development.
class ServerConfig {
  static const String _fromEnvironment = String.fromEnvironment(
    'SERVER_URL',
  );
  static const String _legacyEnvironment = String.fromEnvironment(
    'PLAID_SERVER_URL',
  );

  static String get baseUrl {
    if (_fromEnvironment.isNotEmpty) {
      return _trim(_fromEnvironment);
    }
    if (_legacyEnvironment.isNotEmpty) return _trim(_legacyEnvironment);
    if (kIsWeb) return webBase;
    return 'https://alauris.tail088878.ts.net/fish';
  }

  /// Same-origin base for web builds, preserving the subpath the app is
  /// served from (e.g. `/fish` behind the Tailnet funnel).
  ///
  /// `Uri.base.origin` strips the path, so an app loaded from
  /// `https://host/fish/` would otherwise talk to `https://host/api/...`
  /// — which is a different Tailscale serve target (the old viewer on `/`)
  /// and answers 501. Deriving the base from the page URL keeps API calls
  /// under the same prefix that was stripped to reach this server.
  static String get webBase => baseForUri(Uri.base);

  /// Pure helper for [webBase] so it can be unit-tested on the VM.
  static String baseForUri(Uri uri) {
    var path = uri.path;
    final lastSlash = path.lastIndexOf('/');
    final lastSegment =
        lastSlash < 0 ? path : path.substring(lastSlash + 1);
    if (lastSegment.contains('.')) {
      path = lastSlash <= 0 ? '' : path.substring(0, lastSlash);
    }
    final trimmed = path.replaceAll(RegExp(r'/+$'), '');
    if (trimmed.isEmpty) return uri.origin;
    return _trim('${uri.origin}$trimmed');
  }

  static String _trim(String url) =>
      url.trim().replaceAll(RegExp(r'/+$'), '');
}

/// Single place that decides which server the app talks to.
///
/// NOTE: [configured] (the retired per-device "Sync server URL" setting)
/// is intentionally ignored — see [ServerConfig]. It is still persisted
/// so old stored data loads, but it no longer affects transport.
String resolveAppServerBase(String configured) {
  var effective = ServerConfig.baseUrl;
  if (effective.isEmpty) {
    if (kIsWeb) return ServerConfig.webBase;
    return 'http://127.0.0.1:8000';
  }
  // Android emulator: loopback means the emulator itself, not the dev
  // machine hosting the server.
  if (!kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      (effective == 'http://127.0.0.1:8000' ||
          effective == 'http://localhost:8000')) {
    return 'http://10.0.2.2:8000';
  }
  return effective;
}
