import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/model/calendar_source.dart';
import 'package:a_fish_in_sea/planner/model/color_prefs.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/event_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

PlannerEvent _event({
  String id = 'e1',
  String? classLabel,
  String? feedId,
  int? colorValue,
  bool isTask = false,
}) => PlannerEvent(
  id: id,
  subject: 'Event',
  start: DateTime(2026, 10, 24, 9),
  end: DateTime(2026, 10, 24, 10),
  classLabel: classLabel,
  feedId: feedId,
  colorValue: colorValue,
  isTask: isTask,
);

void main() {
  const homework = 0xFF6A8FB5;
  const classOverride = 0xFFB2706B;
  const personal = 0xFF7E7AB8;

  group('ColorPrefs persistence', () {
    test('round trips every field', () {
      const prefs = ColorPrefs(
        homework: homework,
        personal: personal,
        classes: {'STAT 230-002': classOverride},
        applyToCalendar: false,
        applyToTaskLists: true,
      );
      final restored = ColorPrefs.fromJson(prefs.toJson());
      expect(restored, prefs);
    });

    test('a missing blob means defaults, never a throw', () {
      expect(ColorPrefs.fromJson(null), const ColorPrefs());
      expect(ColorPrefs.fromJson('nope'), const ColorPrefs());
      expect(ColorPrefs.fromJson(const []), const ColorPrefs());
    });

    test('unknown or invalid keys fall back per field', () {
      final restored = ColorPrefs.fromJson({
        'homework': 'blue',
        'personal': 0x7E7AB8,
        'classes': {
          'WRTG 150': 0xFF7A9E7E,
          'broken': 'red',
          17: 0xFF6AA2AD,
          '  ': 0xFF6AA2AD,
        },
        'applyToCalendar': 'yes',
        'applyToTaskLists': false,
      });
      expect(restored.homework, isNull);
      // Pre-alpha colors are normalized instead of discarded.
      expect(restored.personal, 0xFF7E7AB8);
      expect(restored.classes, {'WRTG 150': 0xFF7A9E7E});
      expect(restored.applyToCalendar, isTrue);
      expect(restored.applyToTaskLists, isFalse);
    });

    test('withClassColor trims, sets, and clears one entry', () {
      var prefs = const ColorPrefs().withClassColor('  STAT 230  ', 12);
      expect(prefs.classColorFor('STAT 230'), 12);
      prefs = prefs.withClassColor('STAT 230', null);
      expect(prefs.classes, isEmpty);
    });
  });

  group('resolveEventColor priority', () {
    const feedColors = {'canvas': Color(0xFF6AA2AD)};

    test('homework color beats a class override for task events', () {
      final color = resolveEventColor(
        _event(isTask: true, classLabel: 'STAT 230', feedId: 'canvas'),
        feedColors,
        const ColorPrefs(
          homework: homework,
          classes: {'STAT 230': classOverride},
        ),
      );
      expect(color, const Color(homework));
    });

    test('non-homework keeps the class override', () {
      final color = resolveEventColor(
        _event(classLabel: 'STAT 230'),
        feedColors,
        const ColorPrefs(
          homework: homework,
          classes: {'STAT 230': classOverride},
        ),
      );
      expect(color, const Color(classOverride));
    });

    test('a linked personal node is not homework, even from a feed', () {
      final node = Node(
        id: 'n1',
        title: 'Study',
        createdAt: DateTime(2026, 10, 1),
      );
      expect(node.isHomework, isFalse);
      final color = resolveEventColor(
        _event(isTask: true, feedId: 'canvas'),
        feedColors,
        const ColorPrefs(homework: homework),
        node: node,
      );
      expect(color, isNot(const Color(homework)));
    });

    test('no overrides keeps the deterministic class color', () {
      final color = resolveEventColor(
        _event(classLabel: 'STAT 230'),
        feedColors,
        const ColorPrefs(),
      );
      expect(color, courseColor('STAT 230'));
    });

    test('classless events fall through event, feed, then personal color', () {
      expect(
        resolveEventColor(
          _event(colorValue: 0xFFE53935),
          feedColors,
          const ColorPrefs(),
        ),
        mutedCalendarColor(const Color(0xFFE53935)),
      );
      expect(
        resolveEventColor(
          _event(feedId: 'canvas'),
          feedColors,
          const ColorPrefs(),
        ),
        mutedCalendarColor(const Color(0xFF6AA2AD)),
      );
      expect(
        resolveEventColor(_event(), feedColors, const ColorPrefs()),
        const Color(defaultPersonalEventColor),
      );
      expect(
        resolveEventColor(
          _event(),
          feedColors,
          const ColorPrefs(personal: personal),
        ),
        const Color(personal),
      );
    });

    test('switching the calendar surface off ignores overrides', () {
      const prefs = ColorPrefs(
        homework: homework,
        personal: personal,
        classes: {'STAT 230': classOverride},
        applyToCalendar: false,
      );
      expect(
        resolveEventColor(
          _event(isTask: true, classLabel: 'STAT 230'),
          feedColors,
          prefs,
        ),
        courseColor('STAT 230'),
      );
      expect(
        resolveEventColor(_event(), feedColors, prefs),
        const Color(defaultPersonalEventColor),
      );
    });
  });

  group('isHomeworkEvent', () {
    test('feed events and class-labeled tasks count as homework', () {
      expect(isHomeworkEvent(_event(isTask: true, feedId: 'f')), isTrue);
      expect(isHomeworkEvent(_event(isTask: true, classLabel: 'X')), isTrue);
      expect(isHomeworkEvent(_event(isTask: true)), isFalse);
      expect(isHomeworkEvent(_event(feedId: 'f')), isFalse);
    });
  });

  group('calendar visibility tree', () {
    const feed = Feed(
      id: 'canvas',
      name: 'Canvas',
      url: 'https://example.com/feed.ics',
      kind: FeedKind.canvas,
    );

    CalendarLeaf leafFor(ColorPrefs prefs) {
      final groups = buildCalendarTree(
        feeds: const [feed],
        events: [_event(feedId: 'canvas', classLabel: 'STAT 230')],
        prefs: prefs,
      );
      return groups
          .expand((group) => group.leaves)
          .firstWhere((leaf) => leaf.title == 'STAT 230');
    }

    test('uses the class override so the filter dot matches the tiles', () {
      final leaf = leafFor(
        const ColorPrefs(classes: {'STAT 230': classOverride}),
      );
      expect(leaf.colorValue, classOverride);
    });

    test('keeps the automatic color when the calendar surface is off', () {
      final leaf = leafFor(
        const ColorPrefs(
          classes: {'STAT 230': classOverride},
          applyToCalendar: false,
        ),
      );
      expect(leaf.colorValue, courseColor('STAT 230').toARGB32());
    });
  });
}
