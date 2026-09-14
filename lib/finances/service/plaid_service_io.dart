import 'dart:io';

import 'package:a_fish_in_sea/planner/service/server_base.dart';
import 'package:http/http.dart' as http;

bool isConnectionError(Object e) =>
    e is SocketException || e is http.ClientException;

/// Plaid backend = the one app server ([ServerConfig]).
String resolvePlaidBaseUrl() {
  final configured = ServerConfig.baseUrl;
  if (configured != 'http://127.0.0.1:8000') return configured;
  if (Platform.isAndroid) return 'http://10.0.2.2:8000';
  return configured;
}
