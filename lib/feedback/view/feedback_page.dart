import 'package:a_fish_in_sea/feedback/feedback_service.dart';
import 'package:a_fish_in_sea/navigation/view/app_drawer.dart';
import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';

/// Feedback tab: bug reports + feature requests without a GitHub account.
///
/// Policy: bugs file as auto-approved issues (fixed automatically by the
/// agent builder); features go through triage + manual approval. New
/// reporters land in a review queue; admins can trust a reporter so
/// their future submissions file immediately.
class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key});

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _device = TextEditingController();
  final _extra = TextEditingController();
  String _kind = 'bug';
  bool _loading = true;
  bool _submitting = false;
  String? _error;
  FeedbackStatus _status = const FeedbackStatus();
  List<FeedbackReport> _mine = const [];
  List<FeedbackReport> _pending = const [];
  List<TrustedReporter> _trusted = const [];

  FeedbackService get _service =>
      FeedbackService(context.read<AuthCubit>().syncClient);

  @override
  void initState() {
    super.initState();
    _device.text = _platformLabel;
    _refresh();
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _device.dispose();
    _extra.dispose();
    super.dispose();
  }

  static String get _platformLabel {
    if (kIsWeb) return 'web (${defaultTargetPlatform.name})';
    return defaultTargetPlatform.name;
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final status = await _service.status();
      final mine = await _service.mine();
      var pending = const <FeedbackReport>[];
      var trusted = const <TrustedReporter>[];
      if (status.isAdmin) {
        pending = await _service.pending();
        trusted = await _service.trusted();
      }
      if (!mounted) return;
      setState(() {
        _status = status;
        _mine = mine;
        _pending = pending;
        _trusted = trusted;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    final title = _title.text.trim();
    final description = _description.text.trim();
    if (title.isEmpty || description.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Title and details are required')),
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      final report = await _service.submit(
        kind: _kind,
        title: title,
        description: description,
        device: _device.text.trim(),
        extra: _extra.text.trim(),
        appPlatform: _platformLabel,
      );
      if (!mounted) return;
      _title.clear();
      _description.clear();
      _extra.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_submittedMessage(report))),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Submit failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _submittedMessage(FeedbackReport report) {
    if (report.status == 'filed') {
      return report.isBug
          ? 'Bug filed — it will be fixed automatically.'
          : 'Feature filed — it goes through triage next.';
    }
    return 'Sent — an admin will review it before filing.';
  }

  Future<void> _openIssue(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (kIsWeb) {
      await launchUrl(uri, webOnlyWindowName: '_blank');
    } else {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _approve(FeedbackReport report) async {
    var trust = report.status == 'pending' && !_isKnownReporter(report.email);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text('Approve #${report.id}?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                report.isBug
                    ? 'Files as auto-approved — the builder fixes it automatically.'
                    : 'Files for triage — still needs manual approval before building.',
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Trust this reporter'),
                subtitle: const Text(
                    'Future submissions file immediately, no review.'),
                value: trust,
                onChanged: (v) => setDialogState(() => trust = v ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Approve + file'),
            ),
          ],
        ),
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      await _service.approve(report.id, trustUser: trust);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Filed on GitHub')),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Approve failed: $e')),
      );
    }
  }

  bool _isKnownReporter(String email) =>
      _trusted.any((t) => t.email.toLowerCase() == email.toLowerCase());

  Future<void> _deny(FeedbackReport report) async {
    final reason = TextEditingController();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Deny #${report.id}?'),
        content: TextField(
          controller: reason,
          decoration: const InputDecoration(
            labelText: 'Reason (shown to the reporter)',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Deny'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      await _service.deny(report.id, reason.text.trim());
      reason.dispose();
      if (!mounted) return;
      await _refresh();
    } catch (e) {
      reason.dispose();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deny failed: $e')),
      );
    }
  }

  Future<void> _addTrusted() async {
    final email = TextEditingController();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Trust a reporter'),
        content: TextField(
          controller: email,
          decoration: const InputDecoration(
            labelText: 'App-account email',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.emailAddress,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Trust'),
          ),
        ],
      ),
    );
    final value = email.text.trim();
    email.dispose();
    if (confirm != true || value.isEmpty || !mounted) return;
    try {
      await _service.trust(value);
      if (!mounted) return;
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not trust: $e')),
      );
    }
  }

  Future<void> _untrust(TrustedReporter reporter) async {
    try {
      await _service.untrust(reporter.email);
      if (!mounted) return;
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Remove failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Feedback'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      drawer: const AppDrawer(),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  if (_error != null)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(_error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      ),
                    ),
                  _PolicyCard(status: _status),
                  _NewReportCard(
                    kind: _kind,
                    onKindChanged: (v) => setState(() => _kind = v),
                    title: _title,
                    description: _description,
                    device: _device,
                    extra: _extra,
                    submitting: _submitting,
                    onSubmit: _submit,
                  ),
                  _MyReportsCard(
                    reports: _mine,
                    onOpenIssue: _openIssue,
                  ),
                  if (_status.isAdmin) ...[
                    _PendingCard(
                      reports: _pending,
                      onApprove: _approve,
                      onDeny: _deny,
                      onOpenIssue: _openIssue,
                    ),
                    _TrustedCard(
                      trusted: _trusted,
                      onAdd: _addTrusted,
                      onRemove: _untrust,
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

class _PolicyCard extends StatelessWidget {
  final FeedbackStatus status;

  const _PolicyCard({required this.status});

  @override
  Widget build(BuildContext context) {
    final line = status.isAdmin
        ? 'You are an admin — review the queue below.'
        : status.isTrusted
            ? 'You are a trusted reporter — your submissions file on GitHub immediately, no review.'
            : 'New reporters are reviewed once — after approval your future submissions file immediately.';
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How this works',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text(
                'Bugs are approved + fixed automatically. Features go through triage and need manual approval. No GitHub account needed — the server files the issue for you.'),
            const SizedBox(height: 4),
            Text(line, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _NewReportCard extends StatelessWidget {
  final String kind;
  final ValueChanged<String> onKindChanged;
  final TextEditingController title;
  final TextEditingController description;
  final TextEditingController device;
  final TextEditingController extra;
  final bool submitting;
  final VoidCallback onSubmit;

  const _NewReportCard({
    required this.kind,
    required this.onKindChanged,
    required this.title,
    required this.description,
    required this.device,
    required this.extra,
    required this.submitting,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final isBug = kind == 'bug';
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('New report',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'bug',
                  icon: Icon(Icons.bug_report_outlined),
                  label: Text('Bug'),
                ),
                ButtonSegment(
                  value: 'feature',
                  icon: Icon(Icons.lightbulb_outline),
                  label: Text('Feature'),
                ),
              ],
              selected: {kind},
              onSelectionChanged: (s) => onKindChanged(s.first),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: title,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: description,
              decoration: InputDecoration(
                labelText: isBug ? 'Steps to reproduce' : 'Problem / use case',
                hintText: isBug
                    ? 'What did you do, what did you expect, what happened instead?'
                    : 'What problem does this solve? Who is it for?',
                border: const OutlineInputBorder(),
              ),
              maxLines: 4,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: device,
              decoration: const InputDecoration(
                labelText: 'Device / target',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: extra,
              decoration: InputDecoration(
                labelText: isBug ? 'Logs / screenshots' : 'Proposed change',
                border: const OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: submitting ? null : onSubmit,
              icon: submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_outlined),
              label: Text(isBug
                  ? 'Submit bug (auto-fixed)'
                  : 'Suggest feature (needs approval)'),
            ),
          ],
        ),
      ),
    );
  }
}

Color _statusColor(BuildContext context, String status) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    'filed' => Colors.green,
    'denied' => scheme.error,
    _ => Colors.orange,
  };
}

class _ReportTile extends StatelessWidget {
  final FeedbackReport report;
  final String? subtitle;
  final List<Widget> trailing;
  final Future<void> Function(String url)? onOpenIssue;

  const _ReportTile({
    required this.report,
    this.subtitle,
    this.trailing = const [],
    this.onOpenIssue,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        report.isBug ? Icons.bug_report_outlined : Icons.lightbulb_outline,
      ),
      title: Text(report.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subtitle != null) Text(subtitle!),
          Row(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 4, right: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: _statusColor(context, report.status).withValues(
                    alpha: 0.15,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  report.status,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: _statusColor(context, report.status),
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              if (report.githubIssueNumber != null)
                Text(
                  '#${report.githubIssueNumber}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
            ],
          ),
          if (report.status == 'denied' && report.denyReason.isNotEmpty)
            Text('Denied: ${report.denyReason}'),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (report.githubIssueUrl.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.open_in_new, size: 20),
              tooltip: 'Open GitHub issue',
              onPressed: () => onOpenIssue?.call(report.githubIssueUrl),
            ),
          ...trailing,
        ],
      ),
    );
  }
}

class _MyReportsCard extends StatelessWidget {
  final List<FeedbackReport> reports;
  final Future<void> Function(String url) onOpenIssue;

  const _MyReportsCard({required this.reports, required this.onOpenIssue});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('My reports (${reports.length})',
                style: Theme.of(context).textTheme.titleMedium),
            if (reports.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Nothing submitted yet.'),
              ),
            for (final report in reports)
              _ReportTile(
                report: report,
                onOpenIssue: onOpenIssue,
              ),
          ],
        ),
      ),
    );
  }
}

class _PendingCard extends StatelessWidget {
  final List<FeedbackReport> reports;
  final Future<void> Function(FeedbackReport) onApprove;
  final Future<void> Function(FeedbackReport) onDeny;
  final Future<void> Function(String url) onOpenIssue;

  const _PendingCard({
    required this.reports,
    required this.onApprove,
    required this.onDeny,
    required this.onOpenIssue,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Review queue (${reports.length})',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Approving a bug files it as auto-approved (fixed automatically). Approving a feature sends it to triage.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (reports.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Queue is empty.'),
              ),
            for (final report in reports)
              _ReportTile(
                report: report,
                subtitle:
                    '${report.email} · ${report.isBug ? 'bug' : 'feature'}\n${report.description}',
                onOpenIssue: onOpenIssue,
                trailing: [
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: 'Deny',
                    onPressed: () => onDeny(report),
                  ),
                  IconButton(
                    icon: const Icon(Icons.check, size: 20),
                    tooltip: 'Approve + file',
                    onPressed: () => onApprove(report),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _TrustedCard extends StatelessWidget {
  final List<TrustedReporter> trusted;
  final VoidCallback onAdd;
  final Future<void> Function(TrustedReporter) onRemove;

  const _TrustedCard({
    required this.trusted,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Trusted reporters (${trusted.length})',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                FilledButton.tonalIcon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Trust'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Trusted reporters skip the review queue — their bugs auto-file as approved, their features go straight to triage.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (trusted.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Nobody trusted yet.'),
              ),
            for (final reporter in trusted)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.verified_outlined),
                title: Text(reporter.email),
                subtitle: reporter.addedBy.isEmpty
                    ? null
                    : Text('added by ${reporter.addedBy}'),
                trailing: IconButton(
                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                  tooltip: 'Remove trust',
                  onPressed: () => onRemove(reporter),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
