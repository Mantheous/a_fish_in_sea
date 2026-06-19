import 'dart:io';

import 'package:a_fish_in_sea/finances/service/plaid_config.dart';
import 'package:http/http.dart' as http;

bool isConnectionError(Object e) =>
    e is SocketException || e is http.ClientException;

String resolvePlaidBaseUrl() {
  final configured = PlaidConfig.serverUrl;
  if (configured != 'http://127.0.0.1:8000') return configured;
  if (Platform.isAndroid) return 'http://10.0.2.2:8000';
  return configured;
}
