import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

String _fixture(String name) =>
    File('test/fixtures/$name').readAsStringSync();

void main() {
  group('round trip', () {
    test('unmodified sample is byte-identical', () {
      final src = _fixture('sample_v14.osu');
      final warnings = <String>[];
      final b = OsuParser.parse(src, warnings: warnings);
      expect(warnings, isEmpty);
      expect(OsuWriter.write(b), src);
    });

    test('LF, no trailing newline and BOM are preserved', () {
      const src = '﻿osu file format v14\n\n[General]\nMode: 0\n\n'
          '[HitObjects]\n10,20,30,1,0,0:0:0:0:';
      expect(OsuWriter.write(OsuParser.parse(src)), src);
    });

    test('canonical encoding of every object re-parses to the same values', () {
      final b = OsuParser.parse(_fixture('sample_v14.osu'));
      for (final h in b.hitObjects) {
        final line = OsuWriter.encodeHitObject(h);
        final again = OsuParser.parseHitObject(line)!;
        expect(again.runtimeType, h.runtimeType);
        expect(again.position, h.position);
        expect(again.time, h.time);
        expect(again.encodedType, h.encodedType);
        expect(again.hitSound, h.hitSound);
        expect(again.sample, h.sample);
        if (h is SliderObject) {
          final s = again as SliderObject;
          expect(s.curveType, h.curveType);
          expect(s.controlPoints, h.controlPoints);
          expect(s.slides, h.slides);
          expect(s.length, h.length);
        }
      }
      for (final t in b.timingPoints) {
        final again = OsuParser.parseTimingPoint(OsuWriter.encodeTimingPoint(t))!;
        expect(again.time, t.time);
        expect(again.beatLength, t.beatLength);
        expect(again.uninherited, t.uninherited);
        expect(again.effects, t.effects);
        expect(again.volume, t.volume);
      }
    });
  });

  group('parsing', () {
    late Beatmap b;
    setUp(() => b = OsuParser.parse(_fixture('sample_v14.osu')));

    test('sections and typed values', () {
      expect(b.formatVersion, 14);
      expect(b.audioFilename, 'audio.mp3');
      expect(b.title, 'Sample Map');
      expect(b.getValue(SectionNames.metadata, 'TitleUnicode'), '샘플 맵');
      expect(b.circleSize, 4);
      expect(b.approachRate, 8);
      expect(b.sliderMultiplier, 1.4);
      expect(b.beatDivisor, 4);
      expect(b.bookmarks, [1000, 6333]);
      expect(b.backgroundFilename, 'bg.jpg');
      expect(b.defaultSampleSet, SampleSet.soft);
    });

    test('timing points', () {
      expect(b.timingPoints, hasLength(4));
      final green = b.timingPoints[2];
      expect(green.uninherited, isFalse);
      expect(green.sliderVelocity, closeTo(1.5, 1e-9));
      expect(green.kiai, isTrue);
      expect(b.timingPoints[3].meter, 3);
      expect(b.timingPoints[0].bpm, closeTo(180, 1e-6));
    });

    test('hit objects', () {
      expect(b.hitObjects, hasLength(11));
      expect(b.hitObjects[0], isA<HitCircle>());
      expect(b.hitObjects[0].newCombo, isTrue);
      final slider = b.hitObjects[2] as SliderObject;
      expect(slider.curveType, CurveType.bezier);
      expect(slider.controlPoints, [const Vec2(350, 200), const Vec2(300, 250)]);
      expect(slider.edgeSounds, [2, 0]);
      final circleArc = b.hitObjects[3] as SliderObject;
      expect(circleArc.curveType, CurveType.perfectCircle);
      expect(circleArc.slides, 2);
      expect(circleArc.edgeSounds, isNull); // fields absent in file
      final spinner = b.hitObjects[7] as Spinner;
      expect(spinner.endTime, 8000);
      expect(spinner.newCombo, isTrue);
      expect(b.hitObjects[9].sample,
          const HitSample(normalSet: 1, additionSet: 2, volume: 80));
    });

    test('combo skip bits', () {
      final h = OsuParser.parseHitObject('0,0,0,${1 | 4 | (3 << 4)},0')!;
      expect(h.newCombo, isTrue);
      expect(h.comboSkip, 3);
      expect(h.encodedType, 1 | 4 | (3 << 4));
    });

    test('old-format timing point without uninherited field', () {
      final red = OsuParser.parseTimingPoint('100,500')!;
      expect(red.uninherited, isTrue);
      final green = OsuParser.parseTimingPoint('200,-50')!;
      expect(green.uninherited, isFalse);
      expect(green.sliderVelocity, 2);
    });

    test('malformed lines become warnings, not failures', () {
      final warnings = <String>[];
      final m = OsuParser.parse(
          'osu file format v14\n\n[HitObjects]\ngarbage\n1,2,3,1,0\n',
          warnings: warnings);
      expect(m.hitObjects, hasLength(1));
      expect(warnings, hasLength(1));
    });

    test('rejects non-osu text', () {
      expect(() => OsuParser.parse('hello'), throwsA(isA<OsuFormatException>()));
    });
  });

  group('writing edits', () {
    test('changed value rewrites only that line', () {
      final src = _fixture('sample_v14.osu');
      final b = OsuParser.parse(src);
      b.setValue(SectionNames.metadata, 'Version', 'Hard');
      final out = OsuWriter.write(b);
      expect(out, src.replaceFirst('Version:Normal', 'Version:Hard'));
    });

    test('new key in General uses "Key: Value"', () {
      final b = OsuParser.parse(_fixture('sample_v14.osu'));
      b.setValue(SectionNames.general, 'EpilepsyWarning', '1');
      expect(OsuWriter.write(b), contains('WidescreenStoryboard: 1\r\nEpilepsyWarning: 1\r\n'));
    });

    test('moved object is written canonically, others untouched', () {
      final src = _fixture('sample_v14.osu');
      final b = OsuParser.parse(src);
      final h = b.hitObjects[1];
      b.removeHitObject(h);
      b.insertHitObject(h.translated(const Vec2(10, 0)));
      expect(OsuWriter.write(b),
          src.replaceFirst('200,100,1333,1,2,0:0:0:0:', '210,100,1333,1,2,0:0:0:0:'));
    });

    test('empty beatmap writes a parseable file', () {
      final b = Beatmap.empty();
      b.insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
      b.insertHitObject(const HitCircle(position: Vec2(256, 192), time: 500));
      final again = OsuParser.parse(OsuWriter.write(b));
      expect(again.hitObjects, hasLength(1));
      expect(again.timingPoints.single.bpm, 120);
      expect(again.sliderMultiplier, 1.4);
    });
  });

  group('slider edge sounds the file left out', () {
    // osu! reads missing fields 8/9 as "every edge sounds like the object".
    test('an edited slider without fields 8/9 keeps its additions and sets', () {
      final h = OsuParser.parseHitObject('256,192,1000,6,8,B|356:192,2,100')! as SliderObject;
      expect(h.edgeSounds, isNull);
      final moved = h.translated(const Vec2(1, 0)); // drops the source line
      final p = OsuWriter.encodeHitObject(moved).split(',');
      expect(p[8], '8|8|8', reason: 'the clap stays on head, repeat and tail');
      expect(p[9], '0:0|0:0|0:0');
    });

    test("missing edges take the object's sets", () {
      final h = OsuParser.parseHitObject('256,192,1000,6,2,B|356:192,1,100,0|2,0:0|0:0,2:3:0:0:')! as SliderObject;
      final more = h.copyWith(slides: 2); // one more edge than listed
      final p = OsuWriter.encodeHitObject(more).split(',');
      expect(p[8], '0|2|2');
      expect(p[9], '0:0|0:0|2:3');
    });
  });
}
