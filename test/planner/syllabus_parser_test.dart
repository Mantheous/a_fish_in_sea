import 'package:a_fish_in_sea/planner/service/syllabus_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final ref = DateTime(2026, 8, 15);

  test('extracts month-name dates', () {
    final out = parseSyllabusLocally('HW 3 due Oct 12', now: ref);
    expect(out, hasLength(1));
    expect(out.single.title, contains('HW 3'));
    expect(out.single.due, DateTime(2026, 10, 12));
  });

  test('extracts numeric dates', () {
    final out = parseSyllabusLocally('Problem Set 4 — 10/12', now: ref);
    expect(out, hasLength(1));
    expect(out.single.due, DateTime(2026, 10, 12));
  });

  test('extracts ISO dates', () {
    final out = parseSyllabusLocally('Final report 2026-12-01', now: ref);
    expect(out.single.due, DateTime(2026, 12, 1));
  });

  test('rolls stale dates to next year', () {
    final out = parseSyllabusLocally('Quiz 1 Jan 10', now: ref);
    expect(out.single.due, DateTime(2027, 1, 10));
  });

  test('ignores lecture topics and headers', () {
    final out = parseSyllabusLocally(
      'Syllabus\nOffice Hours\nPostmodernism\nBring your copy of The Tempest\nQuiz 2 Sep 20',
      now: ref,
    );
    expect(out, hasLength(1));
    expect(out.single.title, contains('Quiz 2'));
  });

  test('keeps undated assignments, drops date-only fragments', () {
    final out = parseSyllabusLocally(
      'Final project proposal\nOct 12\nMidterm exam',
      now: ref,
    );
    expect(out.map((d) => d.title), containsAll(['Final project proposal', 'Midterm exam']));
    expect(out.any((d) => d.title == 'Oct 12'), isFalse);
  });

  test('dedupes and sorts by due date', () {
    final out = parseSyllabusLocally(
      'Exam 2 Nov 5\nHW 1 Sep 1\nHW 1 Sep 1',
      now: ref,
    );
    expect(out, hasLength(2));
    expect(out.first.title, contains('HW 1'));
    expect(out.last.title, contains('Exam 2'));
  });
}
