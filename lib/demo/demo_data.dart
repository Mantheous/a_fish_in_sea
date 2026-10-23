import 'demo_mode.dart';
import '../feedback/feedback_service.dart';
import '../finances/model/time_scale.dart';
import '../finances/model/transaction.dart';
import '../imports/import_service.dart';
import '../nodes/model/node.dart';
import '../planner/model/feed.dart';
import '../planner/model/planner_event.dart';
import '../planner/model/task_assignee.dart';
import '../planner/service/canvas_service.dart';
import '../planner/service/google_calendar_service.dart';
import '../planner/service/google_contacts_service.dart';
import '../planner/service/syllabus_draft.dart';
import '../reporting/model/place.dart';
import '../reporting/model/reported_entry.dart';
import '../reporting/model/tracked_point.dart';

/// All mock content for demo mode. Every builder derives dates from
/// [DateTime.now] so the demo always has something due today, something
/// overdue, and something this week — no matter when it is opened.
///
/// Conventions mirror the real importers so the demo exercises the same
/// code paths:
/// - Canvas homework events carry `sourceUid: event-assignment-<id>` and
///   their nodes use `sourceEventId == event.id`, `classId == feed.id`.
/// - [canvasSubmissions] heals one open homework item on sync (submitted),
///   excuses another, and leaves a bare `graded` untouched on purpose.
class DemoData {
  // ── Feeds ──────────────────────────────────────────────────────────

  static const canvasFeedId = 'demo-canvas';
  static const learningSuiteFeedId = 'demo-learningsuite';
  static const googleFeedId = 'demo-google';
  static const communityFeedId = 'demo-community';

  static List<Feed> feeds(DateTime now) => [
        Feed(
          id: canvasFeedId,
          name: 'Canvas · Fall 2026 (mock)',
          url: 'demo://canvas/fall-2026.ics',
          kind: FeedKind.canvas,
          colorValue: Feed.palette[1],
          createTasks: true,
          lastSyncAt: now,
        ),
        Feed(
          id: learningSuiteFeedId,
          name: 'REL 275 · Learning Suite (mock)',
          url: 'demo://learningsuite/rel-275.ics',
          kind: FeedKind.learningSuite,
          colorValue: Feed.palette[2],
          createTasks: true,
          lastSyncAt: now,
        ),
        Feed(
          id: googleFeedId,
          name: 'Family calendar (mock Google)',
          url: 'demo://google/family',
          kind: FeedKind.google,
          colorValue: Feed.palette[4],
          createTasks: false,
          calendarId: 'demo-cal-family',
          lastSyncAt: now,
        ),
        Feed(
          id: communityFeedId,
          name: 'Ward activities (mock iCal)',
          url: 'demo://ical/ward.ics',
          kind: FeedKind.other,
          colorValue: Feed.palette[5],
          createTasks: false,
          lastSyncAt: now,
        ),
      ];

  // ── Calendar events ────────────────────────────────────────────────

  static DateTime _at(DateTime day, int hour, [int minute = 0]) =>
      DateTime(day.year, day.month, day.day, hour, minute);

  /// Feed-sourced events, used both for the initial seed and for mock
  /// re-syncs (so refresh buttons visibly "do something" in demo).
  static List<PlannerEvent> feedEvents(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final overdue = today.subtract(const Duration(days: 1));
    return [
      // Canvas homework (become tasks via importFromFeed).
      PlannerEvent(
        id: '$canvasFeedId:event-assignment-101',
        subject: 'Problem Set 5 [STAT 230-002]',
        notes: 'Mock Canvas assignment — submitted in Canvas, '
            'so the next sync marks it done automatically.',
        start: _at(today.add(const Duration(days: 2)), 23, 59),
        end: _at(today.add(const Duration(days: 2)), 23, 59),
        allDay: true,
        feedId: canvasFeedId,
        sourceUid: 'event-assignment-101',
        classLabel: 'STAT 230-002',
      ),
      PlannerEvent(
        id: '$canvasFeedId:event-assignment-102',
        subject: 'Exit Quiz [STAT 230-002]',
        notes: 'Mock Canvas assignment — still missing, stays overdue '
            'until you tick it off.',
        start: _at(overdue, 23, 59),
        end: _at(overdue, 23, 59),
        allDay: true,
        feedId: canvasFeedId,
        sourceUid: 'event-assignment-102',
        classLabel: 'STAT 230-002',
      ),
      PlannerEvent(
        id: '$canvasFeedId:event-assignment-103',
        subject: 'Reading Response [WRTG 150]',
        notes: 'Due today. Excused in Canvas — sync will clear it.',
        start: _at(today, 23, 59),
        end: _at(today, 23, 59),
        allDay: true,
        feedId: canvasFeedId,
        sourceUid: 'event-assignment-103',
        classLabel: 'WRTG 150',
      ),
      // Canvas class session: calendar-only, never a task.
      PlannerEvent(
        id: '$canvasFeedId:class-stat-lecture',
        subject: 'STAT 230 Lecture',
        location: 'TMCB 120',
        start: _at(today.add(const Duration(days: 1)), 10),
        end: _at(today.add(const Duration(days: 1)), 10, 50),
        recurrenceRule: 'FREQ=WEEKLY;BYDAY=MO,WE,FR',
        feedId: canvasFeedId,
        sourceUid: 'class-stat-lecture',
        classLabel: 'STAT 230-002',
      ),
      // Learning Suite window-style assignment.
      PlannerEvent(
        id: '$learningSuiteFeedId:rel-quiz-3',
        subject: 'Quiz 3 — REL 275',
        notes: 'Learning Suite open..due window; due at the end.',
        start: _at(today.subtract(const Duration(days: 3)), 0),
        end: _at(today.add(const Duration(days: 4)), 23, 59),
        allDay: true,
        feedId: learningSuiteFeedId,
        sourceUid: 'rel-quiz-3',
        classLabel: 'REL 275',
      ),
      // Google events (writable — try editing one).
      PlannerEvent(
        id: 'gcal:$googleFeedId:demo-brunch',
        subject: 'Family brunch',
        location: 'Home',
        start: _at(today.add(const Duration(days: 2)), 10, 30),
        end: _at(today.add(const Duration(days: 2)), 12),
        feedId: googleFeedId,
        sourceUid: 'demo-brunch',
        assignees: const [
          TaskAssignee(
              id: 'demo-sam', displayName: 'Sam Rivera', email: 'sam@example.com'),
        ],
      ),
      PlannerEvent(
        id: 'gcal:$googleFeedId:demo-standup',
        subject: 'Team standup',
        start: _at(today, 9),
        end: _at(today, 9, 15),
        recurrenceRule: 'FREQ=WEEKLY;BYDAY=MO',
        feedId: googleFeedId,
        sourceUid: 'demo-standup',
      ),
      // Plain iCal community event.
      PlannerEvent(
        id: '$communityFeedId:ward-social',
        subject: 'Ward social',
        location: 'Cultural hall',
        start: _at(today.add(const Duration(days: 5)), 18),
        end: _at(today.add(const Duration(days: 5)), 20),
        feedId: communityFeedId,
        sourceUid: 'ward-social',
      ),
      ...DemoMocks.googleOverlay
          .where((e) => !DemoMocks.googleTombstones.contains(e.sourceUid)),
    ];
  }

  /// Personal (non-feed) events.
  static List<PlannerEvent> personalEvents(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return [
      PlannerEvent(
        id: 'demo-personal-deepwork',
        subject: 'Deep work block',
        notes: 'Personal event — drag me on the calendar.',
        start: _at(today, 14),
        end: _at(today, 16),
        placeId: 'demo-place-home',
      ),
      PlannerEvent(
        id: 'demo-personal-gym',
        subject: 'Gym',
        start: _at(today.add(const Duration(days: 1)), 7),
        end: _at(today.add(const Duration(days: 1)), 8),
        recurrenceRule: 'FREQ=WEEKLY;BYDAY=TU,TH',
        placeId: 'demo-place-gym',
      ),
    ];
  }

  // ── Nodes (tasks, homework, money) ─────────────────────────────────

  static List<Node> nodes(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final created = today.subtract(const Duration(days: 6));
    return [
      // Homework mirrors of the Canvas events above.
      Node(
        id: '$canvasFeedId:event-assignment-101',
        title: 'Problem Set 5 [STAT 230-002]',
        createdAt: created,
        schedule: ScheduleFacet(
            due: _at(today.add(const Duration(days: 2)), 23, 59)),
        sourceEventId: '$canvasFeedId:event-assignment-101',
        feedId: canvasFeedId,
        classId: canvasFeedId,
        classLabel: 'STAT 230-002',
      ),
      Node(
        id: '$canvasFeedId:event-assignment-102',
        title: 'Exit Quiz [STAT 230-002]',
        createdAt: created,
        schedule:
            ScheduleFacet(due: _at(today.subtract(const Duration(days: 1)), 23, 59)),
        sourceEventId: '$canvasFeedId:event-assignment-102',
        feedId: canvasFeedId,
        classId: canvasFeedId,
        classLabel: 'STAT 230-002',
      ),
      Node(
        id: '$canvasFeedId:event-assignment-103',
        title: 'Reading Response [WRTG 150]',
        createdAt: created,
        schedule: ScheduleFacet(due: _at(today, 23, 59)),
        sourceEventId: '$canvasFeedId:event-assignment-103',
        feedId: canvasFeedId,
        classId: canvasFeedId,
        classLabel: 'WRTG 150',
      ),
      Node(
        id: '$learningSuiteFeedId:rel-quiz-3',
        title: 'Quiz 3 — REL 275',
        createdAt: created,
        schedule: ScheduleFacet(
            due: _at(today.add(const Duration(days: 4)), 23, 59)),
        sourceEventId: '$learningSuiteFeedId:rel-quiz-3',
        feedId: learningSuiteFeedId,
        classId: learningSuiteFeedId,
        classLabel: 'REL 275',
      ),
      // Personal to-dos.
      Node(
        id: 'demo-todo-groceries',
        title: 'Buy groceries',
        notes: 'Mock personal task — try the checkbox, then undo.',
        createdAt: created,
        schedule: ScheduleFacet(due: _at(today, 18)),
      ),
      Node(
        id: 'demo-todo-call',
        title: 'Call mom back',
        createdAt: created,
        schedule: ScheduleFacet(
            due: _at(today.subtract(const Duration(days: 2)), 12)),
      ),
      // Money: budget template + dated instances (Unity-prefab style).
      Node(
        id: 'demo-budget-food',
        title: 'Food · October budget',
        createdAt: created,
        money: const MoneyFacet(
          targetAmount: 400,
          direction: MoneyDirection.spend,
          period: TimeScale.monthly,
          isRecurring: true,
          autoRollover: true,
        ),
        schedule: ScheduleFacet(
            due: DateTime(today.year, today.month + 1, 0, 23, 59)),
      ),
      Node(
        id: 'demo-exp-rent',
        title: 'Rent',
        createdAt: created,
        money: const MoneyFacet(
          targetAmount: 950,
          direction: MoneyDirection.spend,
          isFixed: true,
        ),
        schedule: ScheduleFacet(due: DateTime(today.year, today.month, 1).add(
            const Duration(days: 32)).copyWith(day: 1, hour: 12)),
      ),
      Node(
        id: 'demo-exp-gas',
        title: 'Gas',
        notes: 'Monthly \$50 template — override one month to see '
            'property overrides without touching the rule.',
        createdAt: created,
        money: const MoneyFacet(
          targetAmount: 50,
          direction: MoneyDirection.spend,
          period: TimeScale.monthly,
          isRecurring: true,
        ),
        schedule: ScheduleFacet(due: _at(today, 23, 59)),
      ),
      Node(
        id: 'demo-inc-paycheck',
        title: 'Paycheck',
        createdAt: created,
        money: const MoneyFacet(
          targetAmount: 1200,
          direction: MoneyDirection.income,
          period: TimeScale.biweekly,
          isRecurring: true,
        ),
        schedule: ScheduleFacet(
            due: _at(today.add(const Duration(days: 3)), 12)),
      ),
    ];
  }

  // ── Canvas / Google / Contacts mocks ───────────────────────────────

  static List<CanvasSubmission> canvasSubmissions() => const [
        CanvasSubmission(assignmentId: 101, submitted: true),
        CanvasSubmission(assignmentId: 103, excused: true),
        // Bare graded-without-submission: must NEVER auto-complete.
        CanvasSubmission(assignmentId: 102, graded: true, missing: true),
      ];

  static List<GoogleCalendarInfo> googleCalendars() => const [
        GoogleCalendarInfo(
          id: 'demo-cal-family',
          summary: 'Family calendar (mock)',
          primary: true,
          accessRole: 'owner',
        ),
        GoogleCalendarInfo(
          id: 'demo-cal-readonly',
          summary: 'Ward calendar (mock, read-only)',
          accessRole: 'reader',
        ),
      ];

  static List<GoogleContact> googleContacts() => const [
        GoogleContact(
            id: 'demo-maya',
            displayName: 'Maya Chen',
            email: 'maya@example.com'),
        GoogleContact(
            id: 'demo-sam',
            displayName: 'Sam Rivera',
            email: 'sam@example.com'),
        GoogleContact(
            id: 'demo-alvarez',
            displayName: 'Prof. Alvarez',
            email: 'alvarez@example.com'),
        GoogleContact(
            id: 'demo-jordan',
            displayName: 'Jordan Lee',
            email: 'jordan@example.com'),
        GoogleContact(
            id: 'demo-priya',
            displayName: 'Priya Nair',
            email: 'priya@example.com'),
      ];

  // ── Plaid mocks ────────────────────────────────────────────────────

  static List<Map<String, dynamic>> plaidAccounts() => [
        {
          'account_id': 'demo-checking',
          'name': 'Demo Checking ••9371',
          'type': 'depository',
          'balances': {'current': 2340.12},
        },
        {
          'account_id': 'demo-savings',
          'name': 'Demo Savings ••4410',
          'type': 'depository',
          'balances': {'current': 8100.00},
        },
      ];

  static Map<String, dynamic> plaidBalance() =>
      {'accounts': plaidAccounts()};

  /// Raw Plaid-shaped rows (positive = debit). [Transaction.fromPlaid]
  /// parses these, so the bank-sync path runs for real in demo.
  static List<Map<String, dynamic>> plaidTransactions(DateTime now) {
    String d(DateTime day) =>
        '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
    final today = DateTime(now.year, now.month, now.day);
    return [
      {
        'transaction_id': 'demo-txn-1',
        'account_id': 'demo-checking',
        'amount': 54.20,
        'date': d(today.subtract(const Duration(days: 1))),
        'name': 'TRADER JOES',
        'category': ['Food and Drink', 'Groceries'],
        'pending': false,
      },
      {
        'transaction_id': 'demo-txn-2',
        'account_id': 'demo-checking',
        'amount': 45.00,
        'date': d(today.subtract(const Duration(days: 2))),
        'name': 'CHEVRON GAS',
        'category': ['Travel', 'Gas Stations'],
        'pending': false,
      },
      {
        'transaction_id': 'demo-txn-3',
        'account_id': 'demo-checking',
        'amount': 12.50,
        'date': d(today.subtract(const Duration(days: 3))),
        'name': 'CAMPUS CAFE',
        'category': ['Food and Drink'],
        'pending': false,
      },
      {
        'transaction_id': 'demo-txn-4',
        'account_id': 'demo-checking',
        'amount': -1200.00,
        'date': d(today.subtract(const Duration(days: 4))),
        'name': 'CAMPUS PAYROLL',
        'category': ['Transfer', 'Payroll'],
        'pending': false,
      },
      {
        'transaction_id': 'demo-txn-5',
        'account_id': 'demo-checking',
        'amount': 950.00,
        'date': d(today.subtract(const Duration(days: 9))),
        'name': 'PROVO RENTALS',
        'category': ['Rent'],
        'pending': false,
      },
      {
        'transaction_id': 'demo-txn-6',
        'account_id': 'demo-checking',
        'amount': 8.75,
        'date': d(today),
        'name': 'CAMPUS CAFE',
        'category': ['Food and Drink'],
        'pending': true,
      },
    ];
  }

  /// Seeded [Transaction]s: a few already imported (one reconciled to the
  /// food budget to show the assigned state). The rest arrive the first
  /// time the user hits "Sync transactions", so the bank-sync path visibly
  /// does something in the demo.
  static List<Transaction> transactions(DateTime now) {
    final all = plaidTransactions(now)
        .map((j) => Transaction.fromPlaid(Map<String, dynamic>.from(j)))
        .toList();
    return [
      for (final t in all.take(3))
        if (t.id == 'demo-txn-1')
          t.copyWith(assignedNodeId: 'demo-budget-food')
        else
          t,
    ];
  }

  // ── Places / reporting / tracking ──────────────────────────────────

  static List<Place> places() => const [
        Place(
            id: 'demo-place-home',
            name: 'Home',
            lat: 40.2518,
            lng: -111.6493),
        Place(
            id: 'demo-place-library',
            name: 'Library',
            lat: 40.2489,
            lng: -111.6513),
        Place(
            id: 'demo-place-gym',
            name: 'Gym',
            lat: 40.2571,
            lng: -111.6544),
      ];

  static Map<String, List<ReportedEntry>> reportedEntries(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    String key(DateTime day) =>
        '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
    DateTime at(DateTime day, int h, [int m = 0]) =>
        DateTime(day.year, day.month, day.day, h, m);
    return {
      key(today): [
        ReportedEntry(
          id: 'demo-rep-1',
          title: 'Deep work block',
          start: at(today, 14),
          end: at(today, 15, 30),
          status: ReportStatus.attended,
          placeId: 'demo-place-home',
          minutesAtPlace: 90,
          auto: false,
        ),
        ReportedEntry(
          id: 'demo-rep-2',
          title: 'Team standup',
          start: at(today, 9),
          end: at(today, 9, 15),
          status: ReportStatus.partial,
          auto: true,
        ),
      ],
    };
  }

  static List<TrackedPoint> trackedPoints(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return [
      for (var i = 0; i < 8; i++)
        TrackedPoint(
          id: 'demo-pt-$i',
          timestamp:
              DateTime(today.year, today.month, today.day, 8, i * 7),
          lat: 40.2518 + i * 0.0004,
          lng: -111.6493 + i * 0.0003,
          accuracy: 12,
        ),
    ];
  }

  // ── Import inbox ─────────────────────────────────────────────────

  static const importBatchId = 9001;

  /// One mock staged batch ("Email forward") with two fresh items and one
  /// reschedule of an existing homework node. Item payloads are real
  /// [Node]/[PlannerEvent] JSON, so approving them round-trips through the
  /// same parsers the server path uses.
  static ImportBatch importBatch(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    DateTime at(DateTime day, int h, [int m = 0]) =>
        DateTime(day.year, day.month, day.day, h, m);
    final created = today.subtract(const Duration(days: 1));

    final rsvp = Node(
      id: 'demo-import-rsvp',
      title: 'RSVP for ward social',
      notes: 'Mock staged import — approve to create the task.',
      createdAt: created,
      schedule:
          ScheduleFacet(due: at(today.add(const Duration(days: 6)), 12)),
    );
    final studyGroup = PlannerEvent(
      id: 'demo-import-study',
      subject: 'Study group @ library',
      location: 'Library',
      start: at(today.add(const Duration(days: 3)), 16),
      end: at(today.add(const Duration(days: 3)), 18),
      placeId: 'demo-place-library',
    );
    final quizNew = Node(
      id: '$learningSuiteFeedId:rel-quiz-3',
      title: 'Quiz 3 — REL 275',
      notes: 'Rescheduled by the instructor.',
      createdAt: created,
      schedule: ScheduleFacet(
          due: at(today.add(const Duration(days: 6)), 23, 59)),
      sourceEventId: '$learningSuiteFeedId:rel-quiz-3',
      feedId: learningSuiteFeedId,
      classId: learningSuiteFeedId,
      classLabel: 'REL 275',
    );
    final quizOld = quizNew.copyWith(
      schedule: ScheduleFacet(
          due: at(today.add(const Duration(days: 4)), 23, 59)),
    );

    String statusOf(String itemId) =>
        DemoMocks.importDecisions[itemId] ?? 'pending';

    final items = [
      StagedItem(
        collection: 'nodes',
        itemId: rsvp.id,
        data: rsvp.toJson(),
        status: statusOf(rsvp.id),
      ),
      StagedItem(
        collection: 'events',
        itemId: studyGroup.id,
        data: studyGroup.toJson(),
        status: statusOf(studyGroup.id),
      ),
      StagedItem(
        collection: 'nodes',
        itemId: quizNew.id,
        data: quizNew.toJson(),
        status: statusOf(quizNew.id),
        existing: quizOld.toJson(),
      ),
    ];
    return ImportBatch(
      id: importBatchId,
      source: 'Email forward (mock)',
      status: items.every((i) => !i.isPending) ? 'approved' : 'pending',
      createdAt: today.subtract(const Duration(hours: 3)),
      items: items,
    );
  }

  // ── Feedback (demo mode) ───────────────────────────────────────────

  /// Read-only demo reports for the Feedback tab. The feedback endpoints
  /// need a signed-in session, so the demo tab seeds these instead of
  /// calling the server. Nothing here is persisted or submitted for real.
  static List<FeedbackReport> demoReports(DateTime now) => [
        FeedbackReport(
          id: 4001,
          kind: 'bug',
          title: 'Mock bug: swiped task deletes instead of snoozing',
          description: 'Demo report — read-only while demoing.',
          device: 'web (mock)',
          extra: 'Steps: open a task, swipe left, tap snooze.',
          status: 'filed',
          githubIssueNumber: 10,
          githubIssueUrl:
              'https://github.com/Mantheous/a_fish_in_sea/issues/10',
          email: DemoMode.demoEmail,
        ),
        FeedbackReport(
          id: 4002,
          kind: 'feature',
          title: 'Mock feature: dark mode toggle',
          description: 'Demo feature request awaiting review.',
          device: 'web (mock)',
          extra: 'Add a system dark-mode switch to Settings.',
          status: 'pending',
          email: DemoMode.demoEmail,
        ),
      ];

  // ── Syllabus + import inbox ────────────────────────────────────────

  static List<SyllabusDraft> syllabusDrafts(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return [
      SyllabusDraft(
        title: 'Midterm 2 [STAT 230-002]',
        due: today.add(const Duration(days: 9)),
        notes: 'Mock AI extraction — review, then create the task.',
      ),
      SyllabusDraft(
        title: 'Lab Report 4 [WRTG 150]',
        due: today.add(const Duration(days: 6)),
      ),
      SyllabusDraft(
        title: 'Quiz 4 — REL 275',
        due: today.add(const Duration(days: 11)),
      ),
    ];
  }
}

/// Mutable demo-only knobs: connection toggles, Google overlay edits, and
/// the import-inbox decision state. Reset on every [enterDemo].
class DemoMocks {
  static bool googleConnected = true;
  static bool canvasConnected = true;
  static bool stravaConnected = true;
  static String canvasHost = 'demo.instructure.com';

  /// User-created/edited Google events layered over [DemoData.feedEvents].
  static final List<PlannerEvent> googleOverlay = [];

  /// Remote ids the user deleted in demo (excluded from mock fetches).
  static final Set<String> googleTombstones = {};

  /// Import inbox decisions: itemId -> 'approved' | 'discarded'.
  /// 'batch' -> 'approved' | 'rejected' for whole-batch decisions.
  static final Map<String, String> importDecisions = {};

  static void reset() {
    googleConnected = true;
    canvasConnected = true;
    stravaConnected = true;
    canvasHost = 'demo.instructure.com';
    googleOverlay.clear();
    googleTombstones.clear();
    importDecisions.clear();
  }
}
