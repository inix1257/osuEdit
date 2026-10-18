import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

void main() {
  // 120 BPM (500ms) from 1000, then 3/4 at 150 BPM (400ms) from 5000,
  // with a 2x green line at 3000.
  final red1 = TimingPoint.red(time: 1000, bpm: 120);
  final green = TimingPoint.green(time: 3000, sliderVelocity: 2);
  final red2 = TimingPoint.red(time: 5000, bpm: 150, meter: 3);
  final timing = TimingInfo([red1, green, red2]);

  test('point lookup', () {
    expect(timing.redPointAt(0), same(red1)); // extends backwards
    expect(timing.redPointAt(4999), same(red1));
    expect(timing.redPointAt(5000), same(red2));
    expect(timing.sliderVelocityAt(2999), 1);
    expect(timing.sliderVelocityAt(3000), 2);
    expect(timing.sliderVelocityAt(5000), 1); // red point resets SV
  });

  test('green point at the same time as a red one wins', () {
    final r = TimingPoint.red(time: 0, bpm: 100);
    final g = TimingPoint.green(time: 0, sliderVelocity: 0.5);
    expect(TimingInfo([r, g]).sliderVelocityAt(0), 0.5);
  });

  test('kiai starts', () {
    TimingPoint k(TimingPoint p) => p.copyWith(effects: TimingEffects.kiai);
    final t = TimingInfo([
      TimingPoint.red(time: 0, bpm: 120),
      k(TimingPoint.green(time: 1000, sliderVelocity: 1)),
      k(TimingPoint.green(time: 1500, sliderVelocity: 2)), // still on
      TimingPoint.green(time: 2000, sliderVelocity: 1),
      // Same time: the later (kiai) point wins.
      TimingPoint.red(time: 3000, bpm: 120),
      k(TimingPoint.green(time: 3000, sliderVelocity: 1)),
    ]);
    expect(t.kiaiStarts, [1000, 3000]);
    expect(t.lastKiaiStartAt(999), isNull);
    expect(t.lastKiaiStartAt(1000), 1000);
    expect(t.lastKiaiStartAt(2999), 1000);
    expect(t.lastKiaiStartAt(5000), 3000);
  });

  test('snap to divisor', () {
    expect(timing.snap(1130, 4), 1125);
    expect(timing.snap(1130, 1), 1000);
    expect(timing.snap(1170, 3), 1167); // 1166.67, stored as a whole ms
    expect(timing.snap(800, 1), 1000 - 500 * 0); // nearest of 500/1000
    expect(timing.snap(700, 1), 500);
    // Doesn't snap past the next red point.
    expect(timing.snap(4990, 1), 5000);
  });

  test('step snap', () {
    expect(timing.stepSnap(1000, 4, forward: true), 1125);
    expect(timing.stepSnap(1125, 4, forward: false), 1000);
    expect(timing.stepSnap(1124.9, 4, forward: true), 1250);
    expect(timing.stepSnap(4900, 1, forward: true), 5000);
  });

  test('ticks', () {
    final ticks = timing.ticks(1000, 2000, 2);
    expect(ticks.map((t) => t.time), [1000, 1250, 1500, 1750]);
    expect(ticks.map((t) => t.denominator), [1, 2, 1, 2]);
    expect(ticks.first.isMeasureStart, isTrue);
    expect(ticks[2].isMeasureStart, isFalse);

    final t4 = timing.ticks(1000, 1500, 4);
    expect(t4.map((t) => t.denominator), [1, 4, 2, 4]);

    // Measure starts every 3 beats after the 3/4 red point.
    final m = timing.ticks(5000, 6300, 1).where((t) => t.isMeasureStart);
    expect(m.map((t) => t.time), [5000, 6200]);

    // Ticks before the first red point.
    expect(timing.ticks(0, 1000, 1).map((t) => t.time), [0, 500]);
  });

  test('slider duration', () {
    // SliderMultiplier 1.4 → 140 px per beat at SV 1.
    final s = SliderObject(
      position: Vec2.zero,
      time: 1000,
      curveType: CurveType.linear,
      controlPoints: const [Vec2(140, 0)],
      length: 140,
      slides: 2,
    );
    expect(timing.sliderSpanDuration(s, 1.4), closeTo(500, 1e-9));
    expect(timing.sliderEndTime(s, 1.4), closeTo(2000, 1e-9));
    final fast = s.copyWith(time: 3000);
    expect(timing.sliderSpanDuration(fast, 1.4), closeTo(250, 1e-9));
  });

  test('rules', () {
    expect(OsuRules.circleRadius(4), closeTo(36.48, 1e-9));
    expect(OsuRules.preempt(9), 600);
    expect(OsuRules.preempt(5), 1200);
    expect(OsuRules.preempt(0), 1800);
  });

  group('combos (osu!stable rules)', () {
    HitCircle c(double t, {bool nc = false, int skip = 0}) =>
        HitCircle(position: Vec2.zero, time: t, newCombo: nc, comboSkip: skip);
    Spinner sp(double t, {bool nc = false, int skip = 0}) =>
        Spinner(position: Vec2.zero, time: t, endTime: t + 1, newCombo: nc, comboSkip: skip);
    /// "numbers / colour slots", e.g. "1 2 / 1 1".
    String run(List<HitObject> objs) {
      final r = computeCombos(objs);
      return '${r.map((e) => e.number).join(' ')} / ${r.map((e) => e.colourIndex).join(' ')}';
    }

    test('the first combo uses colour slot 1 (Combo2); skips apply with NC', () {
      expect(run([c(0), c(1), c(2, nc: true, skip: 1), c(3)]), '1 2 1 2 / 1 1 3 3');
      // A skip without the new-combo bit does nothing.
      expect(run([c(0), c(1, skip: 3)]), '1 2 / 1 1');
      // The first object's own skip counts.
      expect(run([c(0, nc: true, skip: 2)]), '1 / 3');
    });

    test('spinners continue the combo; the next object starts a new one', () {
      expect(run([c(0), c(1), sp(2, nc: true, skip: 2), c(4)]), '1 2 3 1 / 1 1 1 2');
      // The object after a spinner only skips colours with its own NC bit.
      expect(run([c(0), sp(2), c(4, skip: 1)]), '1 2 1 / 1 1 2');
      expect(run([c(0), sp(2), c(4, nc: true, skip: 1)]), '1 2 1 / 1 1 3');
    });

    test('a map starting with spinners', () {
      expect(run([sp(0, nc: true), sp(2), c(4), c(5)]), '1 2 1 2 / 0 0 1 1');
    });
  });
  test('slider tick distances (lazer rules)', () {
    SliderObject s(double t, double len) => SliderObject(
        position: const Vec2(0, 0), time: t, curveType: CurveType.linear, controlPoints: const [Vec2(500, 0)], length: len);
    // 120 BPM, SM 1: a tick every 100 px; none within 10 ms (2 px) of the end.
    expect(timing.sliderTickDistances(s(1000, 250), 1, 1), [100, 200]);
    expect(timing.sliderTickDistances(s(1000, 200), 1, 1), [100]);
    expect(timing.sliderTickDistances(s(1000, 200), 1, 2), [50, 100, 150]);
    // SV 2 doubles the spacing, except before format v8.
    expect(timing.sliderTickDistances(s(3000, 450), 1, 1), [200, 400]);
    expect(timing.sliderTickDistances(s(3000, 450), 1, 1, formatVersion: 7), [100, 200, 300, 400]);
    expect(timing.sliderTickDistances(s(1000, 250), 1, 0), isEmpty);
  });
}
