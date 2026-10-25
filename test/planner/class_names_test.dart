import 'package:a_fish_in_sea/planner/model/class_names.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const feeds = [
    Feed(
      id: 'feed:1789249594268000',
      name: 'Discrete Structure',
      url: 'https://example.com/discrete.ics',
      kind: FeedKind.learningSuite,
    ),
    Feed(
      id: 'gcal:me@example.com',
      name: 'Personal',
      url: '',
      kind: FeedKind.google,
    ),
  ];

  test('a feed id resolves to the name the user typed', () {
    expect(
      classNameFor('feed:1789249594268000', feeds),
      'Discrete Structure',
    );
  });

  test('canvas course labels pass through unchanged', () {
    expect(classNameFor('STAT 230-002', feeds), 'STAT 230-002');
    expect(classNameFor('HIST 205: 001-005', feeds), 'HIST 205: 001-005');
  });

  test('a removed feed id never leaks the raw id', () {
    expect(
      classNameFor('feed:1789249594268999', feeds),
      'Unknown class',
    );
    expect(classNameFor('gcal:gone@example.com', feeds), 'Unknown class');
  });

  test('empty key stays empty', () {
    expect(classNameFor('', feeds), '');
  });
}
