import 'package:a_fish_in_sea/anki/anki_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseAnkiReviewCounts', () {
    test('bare number counts toward every deck', () {
      final r = parseAnkiReviewCounts('42\n');
      expect(r.total, 42);
      expect(r.byDeck, {'*': 42});
    });

    test('deck lines with comma or colon, comments skipped', () {
      final r = parseAnkiReviewCounts('''
# pasted from Anki stats
Japanese, 30
Medicine: 12

42
''');
      expect(r.byDeck, {'Japanese': 30, 'Medicine': 12, '*': 42});
      expect(r.total, 84);
    });

    test('repeated decks accumulate', () {
      final r = parseAnkiReviewCounts('Japanese, 10\nJapanese, 5\n');
      expect(r.byDeck, {'Japanese': 15});
      expect(r.total, 15);
    });

    test('subdeck :: names survive the colon form', () {
      final r = parseAnkiReviewCounts('Parent::Child: 7\n');
      expect(r.byDeck, {'Parent::Child': 7});
    });

    test('garbage names its line, emptiness throws', () {
      expect(() => parseAnkiReviewCounts('Japanese, lots'),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              contains('Line 1'))));
      expect(() => parseAnkiReviewCounts('10\nnope\n'),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              contains('Line 2'))));
      expect(() => parseAnkiReviewCounts('Japanese, -3'),
          throwsA(isA<FormatException>()));
      expect(() => parseAnkiReviewCounts('# nothing here\n\n'),
          throwsA(isA<FormatException>()));
    });
  });
}
