import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

/// `//` comments, blank lines and unparsable lines inside [TimingPoints] /
/// [HitObjects] are written back, and stay next to the objects they were
/// written for when those are edited, moved or deleted.
void main() {
  const src = 'osu file format v14\r\n'
      '\r\n'
      '[General]\r\n'
      'AudioFilename: a.mp3\r\n'
      '\r\n'
      '[TimingPoints]\r\n'
      '// intro\r\n'
      '0,500,4,1,0,100,1,0\r\n'
      '\r\n'
      '// kiai\r\n'
      '2000,-100,4,1,0,100,0,1\r\n'
      '\r\n'
      '\r\n'
      '[HitObjects]\r\n'
      '// first pattern\r\n'
      '100,100,1000,5,0,0:0:0:0:\r\n'
      '200,100,1500,1,0,0:0:0:0:\r\n'
      '\r\n'
      '// second pattern\r\n'
      '300,100,2000,1,0,0:0:0:0:\r\n'
      'garbage line\r\n'
      '400,100,2500,1,0,0:0:0:0:\r\n'
      '// the end\r\n';

  test('unedited files round-trip byte for byte', () {
    final warnings = <String>[];
    final b = OsuParser.parse(src, warnings: warnings);
    expect(b.hitObjects, hasLength(4));
    expect(b.timingPoints, hasLength(2));
    expect(warnings, hasLength(1)); // the garbage line is reported, but kept
    expect(OsuWriter.write(b), src);
  });

  test('an edited object keeps the comment above it', () {
    final b = OsuParser.parse(src);
    final h = b.hitObjects[2]; // @2000, under "// second pattern"
    final history = EditHistory(b);
    history.execute(ReplaceHitObjectsCommand([h], [h.translated(const Vec2(10, 0))]));
    final out = OsuWriter.write(b);
    expect(out, contains('// second pattern\r\n310,100,2000,1,0,0:0:0:0:\r\n'));
    history.undo();
    expect(OsuWriter.write(b), src);
  });

  test('deleting the object under a comment leaves the comment in place', () {
    final b = OsuParser.parse(src);
    EditHistory(b).execute(RemoveHitObjectsCommand([b.hitObjects[2]]));
    final out = OsuWriter.write(b);
    expect(out, contains('200,100,1500,1,0,0:0:0:0:\r\n\r\n// second pattern\r\ngarbage line\r\n400,100,2500'));
  });

  test('comments stay at their time when their object moves away; new objects slot in', () {
    final b = OsuParser.parse(src);
    final history = EditHistory(b);
    final first = b.hitObjects[0];
    // The first object moves past the second pattern. Its comment describes
    // that part of the map, so it stays at its old time (1000), before the
    // first object at or after it.
    history.execute(ReplaceHitObjectsCommand([first], [first.copyWithBase(time: 2200)]));
    history.execute(AddHitObjectsCommand([const HitCircle(position: Vec2(0, 0), time: 3000)]));
    final lines = OsuWriter.write(b).split('\r\n');
    final hit = lines.sublist(lines.indexOf('[HitObjects]') + 1);
    expect(hit, [
      '// first pattern',
      '200,100,1500,1,0,0:0:0:0:',
      '',
      '// second pattern',
      '300,100,2000,1,0,0:0:0:0:',
      '100,100,2200,5,0,0:0:0:0:',
      'garbage line',
      '400,100,2500,1,0,0:0:0:0:',
      '0,0,3000,1,0,0:0:0:0:',
      '// the end',
      '',
    ]);
  });

  test('timing point comments survive edits too', () {
    final b = OsuParser.parse(src);
    final green = b.timingPoints[1];
    EditHistory(b).execute(ReplaceTimingPointCommand(green, green.copyWith(volume: 50)));
    expect(OsuWriter.write(b), contains('// kiai\r\n2000,-100,4,1,0,50,0,1\r\n'));
  });

  test('a new difficulty drops the hit object comments but keeps timing ones', () {
    final b = DifficultyOps.derive(OsuParser.parse(src), version: 'New');
    final out = OsuWriter.write(b);
    expect(out, contains('// kiai'));
    expect(out, isNot(contains('pattern')));
    expect(out, isNot(contains('garbage')));
  });
}
