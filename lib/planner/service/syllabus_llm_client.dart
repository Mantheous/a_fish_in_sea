import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'syllabus_draft.dart';
import 'syllabus_parser.dart';
import 'server_base.dart';

class SyllabusLlmException implements Exception {
  final String message;
  const SyllabusLlmException(this.message);

  @override
  String toString() => message;
}

/// Calls the app server's `/api/syllabus/extract` (which proxies to
/// Ollama on Alauris over localhost — the app never talks to Ollama
/// directly, so no new public surface). Any failure throws
/// [SyllabusLlmException] and the caller falls back to [parseSyllabusLocally].
Future<List<SyllabusDraft>> extractSyllabusViaServer(
  String text, {
  required String Function() proxyBase,
  http.Client? client,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const [];
  // Keep in sync with the server-side cap.
  final payload = trimmed.length > 15000 ? trimmed.substring(0, 15000) : trimmed;

  final prefix = proxyBase().trim().replaceAll(RegExp(r'/+$'), '');
  final String target;
  if (kIsWeb) {
    final base = prefix.isEmpty ? ServerConfig.webBase : prefix;
    target = '$base/api/syllabus/extract';
  } else {
    if (prefix.isEmpty) {
      throw const SyllabusLlmException('No sync server URL set');
    }
    target = '$prefix/api/syllabus/extract';
  }
  final uri = Uri.tryParse(target);
  if (uri == null || (!uri.isScheme('HTTP') && !uri.isScheme('HTTPS'))) {
    throw SyllabusLlmException('Invalid server URL: $target');
  }

  final httpClient = client ?? http.Client();
  final http.Response response;
  try {
    response = await httpClient
        .post(
          uri,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'text': payload}),
        )
        .timeout(timeout);
  } catch (e) {
    throw SyllabusLlmException('Could not reach server: $e');
  }
  if (response.statusCode != 200) {
    throw SyllabusLlmException('Server returned ${response.statusCode}');
  }
  try {
    final decoded = jsonDecode(response.body);
    final raw =
        decoded is Map ? decoded['drafts'] as List<dynamic>? : null;
    if (raw == null) throw const FormatException('missing drafts');
    final out = <SyllabusDraft>[];
    for (final item in raw.take(100)) {
      if (item is! Map) continue;
      final title = (item['title'] as String? ?? '').trim();
      if (title.isEmpty) continue;
      out.add(SyllabusDraft.fromJson(Map<String, dynamic>.from(item)));
    }
    return out;
  } catch (e) {
    throw SyllabusLlmException('Bad server response: $e');
  }
}
