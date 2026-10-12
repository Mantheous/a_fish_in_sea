import 'package:a_fish_in_sea/planner/model/assignment_template.dart';
import 'package:flutter_test/flutter_test.dart';

TemplateSample s(String feed, String title, {DateTime? due}) =>
    TemplateSample(feedId: feed, title: title, due: due);

void main() {
  group('assignmentTemplateKey', () {
    test('strips section numbers (Math 290 video quizzes)', () {
      expect(assignmentTemplateKey('Video Quiz 3.1'), 'video quiz');
      expect(assignmentTemplateKey('Video Quiz 3.4b'), 'video quiz');
      expect(assignmentTemplateKey('Video Quiz 12'), 'video quiz');
    });

    test('strips bare numbers and HW prefixes', () {
      expect(assignmentTemplateKey('Homework 42'), 'homework');
      expect(assignmentTemplateKey('Homework 43'), 'homework');
      expect(assignmentTemplateKey('HW 3'), 'hw');
      expect(assignmentTemplateKey('Quiz 6'), 'quiz');
      expect(assignmentTemplateKey('Reading Quiz 1'), 'reading quiz');
      expect(assignmentTemplateKey('Problem Set 4'),
          assignmentTemplateKey('Problem set 5'));
    });

    test('keeps exact repeats intact', () {
      expect(assignmentTemplateKey('Exit Quiz'), 'exit quiz');
    });

    test('strips trailing dates but keeps the base', () {
      expect(assignmentTemplateKey('In Class MWF Sep 04'), 'in class mwf');
      expect(assignmentTemplateKey('Lecture Fri Oct 3'), 'lecture');
    });

    test('strips numbered remarks, keeps meaningful ones', () {
      expect(assignmentTemplateKey('Lab 2 (Ch 3)'), 'lab');
      expect(assignmentTemplateKey('Quiz (Practice)'), 'quiz (practice)');
    });

    test('does not merge distinct types', () {
      expect(assignmentTemplateKey('Exam 2') == assignmentTemplateKey('Midterm exam'),
          isFalse);
      expect(assignmentTemplateKey('Quiz') == assignmentTemplateKey('Quiz Retake'),
          isFalse);
      expect(assignmentTemplateKey('Final report') ==
          assignmentTemplateKey('Final project proposal'), isFalse);
    });

    test('is case- and whitespace-insensitive', () {
      expect(assignmentTemplateKey('  VIDEO   Quiz 3.1 '), 'video quiz');
    });
  });

  group('detectRepeatingGroups', () {
    final weekly = [
      for (var i = 0; i < 4; i++)
        s('math290', 'Video Quiz 1.$i',
            due: DateTime(2030, 1, 7 + 7 * i, 9)),
    ];

    test('flags 4 weekly quizzes as repeating', () {
      final groups = detectRepeatingGroups(weekly);
      expect(groups, hasLength(1));
      final g = groups.single;
      expect(g.templateKey, 'video quiz');
      expect(g.count, 4);
      expect(g.isRepeating, isTrue);
      expect(g.medianGapDays, 7.0);
      expect(describeCadence(g.medianGapDays), 'about weekly');
    });

    test('pairs are candidates but not repeating', () {
      final groups = detectRepeatingGroups([
        s('f1', 'Homework 1', due: DateTime(2030, 1, 7)),
        s('f1', 'Homework 2', due: DateTime(2030, 1, 14)),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.isRepeating, isFalse);
    });

    test('irregular gaps are not repeating', () {
      final groups = detectRepeatingGroups([
        s('f1', 'Quiz 1', due: DateTime(2030, 1, 7)),
        s('f1', 'Quiz 2', due: DateTime(2030, 1, 8)),
        s('f1', 'Quiz 3', due: DateTime(2030, 2, 7)),
      ]);
      expect(groups.single.isRepeating, isFalse);
    });

    test('never merges across feeds', () {
      final groups = detectRepeatingGroups([
        ...weekly,
        for (var i = 0; i < 4; i++)
          s('stat230', 'Video Quiz 2.$i',
              due: DateTime(2030, 1, 7 + 7 * i, 9)),
      ]);
      expect(groups, hasLength(2));
      expect(groups.map((g) => g.feedId).toSet(), {'math290', 'stat230'});
    });

    test('singletons are dropped', () {
      expect(detectRepeatingGroups([s('f1', 'Final report')]), isEmpty);
    });
  });

  group('feed-truth due math', () {
    test('point items are due at start, windows at end', () {
      final start = DateTime(2030, 1, 7, 9);
      final end = DateTime(2030, 1, 7, 10);
      expect(
          assignmentBaseDue(start: start, end: end, allDay: false), start);
      expect(
          assignmentBaseDue(
              start: start,
              end: start.add(const Duration(days: 5)),
              allDay: true),
          start.add(const Duration(days: 5)));
    });

    test('shiftOf measures whole days from base', () {
      final base = DateTime(2030, 1, 7, 9);
      expect(
          assignmentShiftOf(
              due: base.subtract(const Duration(days: 2)), base: base),
          -2);
      expect(assignmentShiftOf(due: base, base: base), 0);
      expect(assignmentShiftOf(due: null, base: base), isNull);
    });
  });
}
