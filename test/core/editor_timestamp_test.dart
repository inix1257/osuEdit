import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

void main() {
  test('parses stable timestamps with combo numbers', () {
    final ts = EditorTimestamp.parse('00:01:234 (1,2,3) - ')!;
    expect(ts.time, 1234);
    expect(ts.combos, [1, 2, 3]);
  });

  test('finds the timestamp inside a modding post; lists are optional', () {
    final ts = EditorTimestamp.parse('hmm, 12:34:567 - this jump is huge')!;
    expect(ts.time, 12 * 60000 + 34 * 1000 + 567);
    expect(ts.combos, isEmpty);
    expect(EditorTimestamp.parse('123:00:001 (4) -')!.time, 123 * 60000 + 1);
  });

  test('mania object lists keep only the time', () {
    final ts = EditorTimestamp.parse('00:05:000 (5000|1,5100|2) -')!;
    expect(ts.time, 5000);
    expect(ts.combos, isEmpty);
  });

  test('rejects text without a timestamp', () {
    expect(EditorTimestamp.parse(''), isNull);
    expect(EditorTimestamp.parse('1:2:3'), isNull);
    expect(EditorTimestamp.parse('nice map'), isNull);
  });

  test('formats like stable and round-trips', () {
    expect(const EditorTimestamp(1234, [1, 2, 3]).format(), '00:01:234 (1,2,3) - ');
    expect(const EditorTimestamp(61005).format(), '01:01:005 - ');
    final back = EditorTimestamp.parse(const EditorTimestamp(754321, [7]).format())!;
    expect(back.time, 754321);
    expect(back.combos, [7]);
  });
}
