import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

final _src = File('test/fixtures/sample_v14.osu').readAsStringSync();

/// The sample with a green point sharing the first red point's time.
final _shared = _src.replaceFirst(
  '1000,333.333333333333,4,2,0,60,1,0\r\n',
  '1000,333.333333333333,4,2,0,60,1,0\r\n1000,-50,4,2,0,60,0,0\r\n',
);

List<double> _times(Beatmap b) => [for (final h in b.hitObjects) h.time];

void main() {
  group('red and green points at the same time', () {
    test('changing the red point keeps it ahead of the green one', () {
      final b = OsuParser.parse(_shared);
      final h = EditHistory(b);
      final red = b.timingPoints.first;
      h.execute(ReplaceTimingPointCommand(red, red.copyWith(beatLength: 300)));
      expect(b.timingPoints[0].uninherited, isTrue);
      expect(b.timingPoints[1].uninherited, isFalse);
      expect(TimingInfo.of(b).sliderVelocityAt(1500), 2); // the green point still applies
      h.undo();
      expect(OsuWriter.write(b), _shared);
    });

    test('a moved point goes back to its place on undo', () {
      final b = OsuParser.parse(_shared);
      final h = EditHistory(b);
      final red = b.timingPoints.first;
      h.execute(ReplaceTimingPointCommand(red, red.copyWith(time: 1010)));
      expect(b.timingPoints[0].uninherited, isFalse);
      h.undo();
      expect(OsuWriter.write(b), _shared);
      h.redo();
      expect(b.timingPoints[1].time, 1010);
    });

    test('a red point added where a green one is goes first', () {
      final b = OsuParser.parse(_src);
      b.insertTimingPoint(TimingPoint.red(time: 3666, bpm: 100));
      final at = [for (final p in b.timingPoints) if (p.time == 3666) p.uninherited];
      expect(at, [true, false]);
    });
  });

  group('retime section', () {
    test('an offset change moves the section, green points and spinner ends', () {
      final b = OsuParser.parse(_src);
      final h = EditHistory(b);
      final red = b.timingPoints.first;
      h.execute(TimingOps.retimeSection(b, red, red.copyWith(time: 1010))!);
      expect(_times(b), [1010, 1343, 1676, 2343, 3676, 4343, 5010, 6343, 9000, 9500, 10000]);
      expect((b.hitObjects[7] as Spinner).endTime, 8010);
      expect([for (final p in b.timingPoints) p.time], [1010, 3676, 5010, 9000]);
      h.undo();
      expect(OsuWriter.write(b), _src);
    });

    test('a BPM change keeps every object on its beat', () {
      // 10% slower: the section still ends before the next red point.
      final b = OsuParser.parse(_src);
      final h = EditHistory(b);
      final red = b.timingPoints.first;
      final before = TimingInfo.of(b);
      final beats = [for (final o in b.hitObjects.take(8)) (o.time - 1000) / red.beatLength];
      final slider = b.hitObjects[2] as SliderObject;
      final sliderBeats = before.sliderSpanDuration(slider, b.sliderMultiplier) / red.beatLength;

      h.execute(TimingOps.retimeSection(b, red, red.copyWith(beatLength: red.beatLength * 1.1))!);
      final after = TimingInfo.of(b);
      final bl = b.timingPoints.first.beatLength;
      // On their beats, at the whole ms osu! stores.
      for (var i = 0; i < 8; i++) {
        final t = b.hitObjects[i].time;
        expect(t, closeTo(1000 + beats[i] * bl, 0.5));
        expect(t, t.roundToDouble());
      }
      expect((b.hitObjects[7] as Spinner).endTime, closeTo(1000 + 7000 * 1.1, 0.5));
      final moved = b.hitObjects[2] as SliderObject;
      expect(after.sliderSpanDuration(moved, b.sliderMultiplier) / bl, closeTo(sliderBeats, 1e-9));
      expect(b.timingPoints[1].time, (1000 + 2666 * 1.1).roundToDouble()); // green: rounded like the objects
      // The next section (red point at 9000) is left alone.
      expect(b.timingPoints.last.time, 9000);
      expect(b.hitObjects.last.time, 10000);
      h.undo();
      expect(OsuWriter.write(b), _src);
    });

    test('a later section moves only from its red point on', () {
      final b = OsuParser.parse(_src);
      final red = b.timingPoints.last;
      EditHistory(b).execute(TimingOps.retimeSection(b, red, red.copyWith(time: 8990))!);
      expect(_times(b), [1000, 1333, 1666, 2333, 3666, 4333, 5000, 6333, 8990, 9490, 9990]);
    });

    test('only red points of the map can be retimed', () {
      final b = OsuParser.parse(_src);
      final green = b.timingPoints[1];
      expect(TimingOps.retimeSection(b, green, green.copyWith(time: 1)), isNull);
      final red = b.timingPoints.first;
      expect(TimingOps.retimeSection(b, red.copyWith(), red.copyWith(time: 1)), isNull);
    });
  });
}
