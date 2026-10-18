import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

/// Checks the generated sync test map (tool/make_click_test_osz.py) is what
/// it claims to be: every snap the editor offers is used and every object
/// lands exactly on its grid.
void main() {
  final src = File('test/fixtures/sync_test_v14.osu').readAsStringSync();
  final b = OsuParser.parse(src);
  final timing = TimingInfo.of(b);
  final sm = b.sliderMultiplier;
  const divisors = [1, 2, 3, 4, 6, 8];

  /// Smallest divisor whose grid [t] lies on (±1 ms, file times are ints).
  int? divisorOf(double t) {
    for (final d in divisors) {
      if ((timing.snap(t, d) - t).abs() <= 1) return d;
    }
    return null;
  }

  test('round-trips byte-for-byte', () {
    expect(OsuWriter.write(b), src);
  });

  test('about 30 s long, starts at the first beat', () {
    expect(b.hitObjects.first.time, 1000);
    final end = timing.endTimeOf(b.hitObjects.last, sm);
    expect(end, inInclusiveRange(28000, 30000));
  });

  test('every object start, slider edge and spinner end is on a snap; all snaps are used', () {
    final used = <int>{};
    for (final h in b.hitObjects) {
      final times = <double>[h.time];
      if (h is SliderObject) {
        final span = timing.sliderSpanDuration(h, sm);
        for (var i = 1; i <= h.slides; i++) {
          times.add(h.time + span * i);
        }
      } else if (h is Spinner) {
        times.add(h.endTime);
      }
      for (final t in times) {
        final d = divisorOf(t);
        expect(d, isNotNull, reason: 'off-grid at $t (object at ${h.time})');
        used.add(d!);
      }
    }
    expect(used, containsAll(divisors));
  });

  test('has sliders with many repeats under a faster SV', () {
    final many = b.hitObjects.whereType<SliderObject>().where((s) => s.slides >= 6).toList();
    expect(many.length, 2);
    for (final s in many) {
      expect(timing.sliderVelocityAt(s.time), 2.0);
    }
    // 1/4-beat spans ×8 = 2 beats, 1/2-beat spans ×6 = 3 beats.
    expect(timing.sliderEndTime(many[0], sm) - many[0].time, closeTo(2 * 333.333, 1));
    expect(timing.sliderEndTime(many[1], sm) - many[1].time, closeTo(3 * 333.333, 1));
  });

  test('everything stays inside the playfield', () {
    for (final h in b.hitObjects) {
      expect(h.position.x, inInclusiveRange(0, OsuRules.playfieldWidth));
      expect(h.position.y, inInclusiveRange(0, OsuRules.playfieldHeight));
      if (h is SliderObject) {
        for (final v in SliderPath.of(h).vertices) {
          expect(v.x, inInclusiveRange(0, OsuRules.playfieldWidth));
          expect(v.y, inInclusiveRange(0, OsuRules.playfieldHeight));
        }
      }
    }
  });

  test('hitsounds cover every addition and the drum bank; kiai is set', () {
    final plays = HitsoundResolver.resolve(b, timing);
    final names = {for (final p in plays) '${p.bank}-${p.name}'};
    expect(names, containsAll(['soft-hitwhistle', 'soft-hitclap', 'soft-hitfinish', 'drum-hitnormal', 'drum-hitclap']));
    expect(b.timingPoints.any((p) => p.kiai), isTrue);
  });
}
