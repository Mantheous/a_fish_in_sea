import '../sync/sync_client.dart';

/// One bug report or feature request filed from the Feedback tab.
/// Reporters only need an app account — the server files the GitHub
/// issue with its own token, so no GitHub account is required.
class FeedbackReport {
  final int id;
  final String kind; // 'bug' | 'feature'
  final String title;
  final String description;
  final String device;
  final String extra;
  final String status; // 'pending' | 'filed' | 'denied'
  final int? githubIssueNumber;
  final String githubIssueUrl;
  final String denyReason;
  final String email;
  final String reviewedBy;

  const FeedbackReport({
    required this.id,
    required this.kind,
    required this.title,
    required this.description,
    required this.device,
    required this.extra,
    required this.status,
    this.githubIssueNumber,
    this.githubIssueUrl = '',
    this.denyReason = '',
    this.email = '',
    this.reviewedBy = '',
  });

  bool get isBug => kind == 'bug';

  factory FeedbackReport.fromJson(Map<String, dynamic> json) => FeedbackReport(
        id: (json['id'] as num?)?.toInt() ?? 0,
        kind: json['kind'] as String? ?? 'bug',
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        device: json['device'] as String? ?? '',
        extra: json['extra'] as String? ?? '',
        status: json['status'] as String? ?? 'pending',
        githubIssueNumber: (json['github_issue_number'] as num?)?.toInt(),
        githubIssueUrl: json['github_issue_url'] as String? ?? '',
        denyReason: json['deny_reason'] as String? ?? '',
        email: json['email'] as String? ?? '',
        reviewedBy: json['reviewed_by'] as String? ?? '',
      );
}

class FeedbackStatus {
  final bool isAdmin;
  final bool isTrusted;

  const FeedbackStatus({this.isAdmin = false, this.isTrusted = false});

  factory FeedbackStatus.fromJson(Map<String, dynamic> json) => FeedbackStatus(
        isAdmin: json['is_admin'] as bool? ?? false,
        isTrusted: json['is_trusted'] as bool? ?? false,
      );
}

class TrustedReporter {
  final String email;
  final String addedBy;

  const TrustedReporter({required this.email, this.addedBy = ''});

  factory TrustedReporter.fromJson(Map<String, dynamic> json) =>
      TrustedReporter(
        email: json['email'] as String? ?? '',
        addedBy: json['added_by'] as String? ?? '',
      );
}

/// Typed client for /api/v1/feedback. Transport (base URL, bearer token,
/// 401→refresh) is the shared [SyncClient]; this class only shapes payloads.
class FeedbackService {
  final SyncClient client;

  FeedbackService(this.client);

  static const _base = '/api/v1/feedback';

  Future<FeedbackStatus> status() async {
    final body = await client.apiGet('$_base/status');
    return FeedbackStatus.fromJson(Map<String, dynamic>.from(body as Map));
  }

  Future<FeedbackReport> submit({
    required String kind,
    required String title,
    required String description,
    String device = '',
    String extra = '',
    String appPlatform = '',
    String appVersion = '',
  }) async {
    final body = await client.apiPost(_base, {
      'kind': kind,
      'title': title,
      'description': description,
      'device': device,
      'extra': extra,
      'app_platform': appPlatform,
      'app_version': appVersion,
    });
    return FeedbackReport.fromJson(Map<String, dynamic>.from(body as Map));
  }

  Future<List<FeedbackReport>> mine() async {
    final body = await client.apiGet('$_base/mine');
    return (body as List)
        .whereType<Map>()
        .map((e) => FeedbackReport.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<List<FeedbackReport>> pending() async {
    final body = await client.apiGet('$_base/pending');
    return (body as List)
        .whereType<Map>()
        .map((e) => FeedbackReport.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<FeedbackReport> approve(int id, {bool trustUser = false}) async {
    final body = await client.apiPost('$_base/$id/approve', {
      'trust_user': trustUser,
    });
    return FeedbackReport.fromJson(Map<String, dynamic>.from(body as Map));
  }

  Future<FeedbackReport> deny(int id, String reason) async {
    final body = await client.apiPost('$_base/$id/deny', {'reason': reason});
    return FeedbackReport.fromJson(Map<String, dynamic>.from(body as Map));
  }

  Future<List<TrustedReporter>> trusted() async {
    final body = await client.apiGet('$_base/trusted');
    return (body as List)
        .whereType<Map>()
        .map((e) => TrustedReporter.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<void> trust(String email) async {
    await client.apiPost('$_base/trusted', {'email': email});
  }

  Future<void> untrust(String email) async {
    await client.apiDelete('$_base/trusted/${Uri.encodeComponent(email)}');
  }
}
