import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// `.osu` stores object times as whole ms. Objects are placed / moved at the
/// stored time, so the control point an object gets (SV, samples, kiai) is
/// the same in the session and after saving and reopening.
void main() {
  group('TimingInfo.storedTime', () {
    final timing = TimingInfo([
      TimingPoint.red(time: 0, bpm: 120),
      const TimingPoint(time: 1000.4, beatLength: -50, uninherited: false), // fractional green (from a file)
    ]);

    test('rounds to the nearest whole ms', () {
      expect(timing.storedTime(1500.4), 1500);
      expect(timing.storedTime(1500.6), 1501);
    });

    test('never moves an object across a control point', () {
      expect(timing.storedTime(1000.4), 1001, reason: 'on the green line: 1000 would be before it');
      expect(timing.storedTime(1000.3), 1000, reason: 'before the green line: stays before');
      expect(timing.storedTime(999.6), 1000);
    });
  });

  test('a green line added where an object was placed applies to it before and after saving', () {
    final src = File('test/fixtures/sample_v14.osu').readAsStringSync();
    final c = EditorController(beatmap: OsuParser.parse(src), document: const BeatmapDocument(fileName: 's.osu'));
    addTearDown(c.dispose);
    // 180 BPM from 1000, 1/4: the snap is 1166.67 — it used to be placed
    // there while the line went to 1167 (applied only after a reload).
    c.seek(1170);
    c.placeCircle(const Vec2(100, 100));
    final placed = c.selection.single;
    expect(placed.time, 1167);
    final green = c.addTimingPoint(red: false);
    expect(green.time, placed.time);
    expect(identical(c.timing.effectivePointAt(placed.time), green), isTrue, reason: 'in the session');

    final again = OsuParser.parse(c.serialize());
    final h = again.hitObjects.firstWhere((o) => o.time == 1167);
    final p = TimingInfo.of(again).effectivePointAt(h.time)!;
    expect(p.inherited, isTrue, reason: 'after saving and reopening');
    expect(p.time, 1167);
  });

  test('moving objects with timing keeps a green line and its object together', () {
    final b = Beatmap.empty()
      ..insertTimingPoint(TimingPoint.red(time: 0, bpm: 120))
      ..insertTimingPoint(const TimingPoint(time: 1000, beatLength: -50, uninherited: false))
      ..insertHitObject(const HitCircle(position: Vec2(100, 100), time: 1000));
    final red = b.timingPoints.first;
    // A tiny BPM change: the section scales to 1000.3 ms.
    final cmd = TimingOps.retimeSection(b, red, red.copyWith(beatLength: 500 * 1.0003))!;
    EditHistory(b).execute(cmd);
    expect(b.hitObjects.single.time, 1000);
    expect(b.timingPoints[1].time, 1000);
  });
}
