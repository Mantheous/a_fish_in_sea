/// Base URL for the local Plaid backend.
///
/// Override at build/run time when the server runs on another host:
/// `flutter run --dart-define=PLAID_SERVER_URL=http://192.168.1.10:8000`
class PlaidConfig {
  static const String _fromEnvironment = String.fromEnvironment(
    'PLAID_SERVER_URL',
  );

  static String get serverUrl {
    if (_fromEnvironment.isNotEmpty) return _fromEnvironment;
    return 'http://100.111.106.47:8000';
  }
}
