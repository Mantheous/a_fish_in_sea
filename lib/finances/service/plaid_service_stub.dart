import 'package:a_fish_in_sea/finances/service/plaid_config.dart';
import 'package:http/http.dart' as http;

bool isConnectionError(Object e) => e is http.ClientException;

String resolvePlaidBaseUrl() => PlaidConfig.serverUrl;
