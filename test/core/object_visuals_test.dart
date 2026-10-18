import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

void main() {
  // AR 9: preempt 600, fade-in 400 (lazer).
  const preempt = 600.0, fadeIn = 400.0;

  test('lazer fade-in: 400ms, shorter only below a 450ms preempt', () {
    expect(OsuRules.fadeIn(9), 400);
    expect(OsuRules.fadeIn(5), 400);
    expect(OsuRules.fadeIn(10), closeTo(400 * 450 / 450, 1e-9));
    expect(OsuRules.fadeIn(11), closeTo(400 * 300 / 450, 1e-9));
  });

  test('hit circle fades in from time - preempt, then out over 700ms', () {
    expect(ObjectVisuals.circleAlpha(400, 1000, preempt, fadeIn), 0);
    expect(ObjectVisuals.circleAlpha(600, 1000, preempt, fadeIn), closeTo(0.5, 1e-9));
    expect(ObjectVisuals.circleAlpha(999, 1000, preempt, fadeIn), 1);
    expect(ObjectVisuals.circleAlpha(1350, 1000, preempt, fadeIn), closeTo(0.5, 1e-9));
    expect(ObjectVisuals.circleAlpha(1700, 1000, preempt, fadeIn), 0);
    expect(ObjectVisuals.isAlive(1700, 1000, 1000, preempt), isTrue);
    expect(ObjectVisuals.isAlive(1701, 1000, 1000, preempt), isFalse);
    expect(ObjectVisuals.isAlive(399, 1000, 1000, preempt), isFalse);
  });

  test('hit marker ring: from the hit time, 1x to 1.1x over 350ms, 0.9 fading out over 700ms', () {
    expect(ObjectVisuals.hitMarkerAlpha(999, 1000), 0);
    expect(ObjectVisuals.hitMarkerAlpha(1000, 1000), closeTo(0.9, 1e-9));
    expect(ObjectVisuals.hitMarkerAlpha(1350, 1000), closeTo(0.9 * 0.75, 1e-9));
    expect(ObjectVisuals.hitMarkerAlpha(1700, 1000), 0);
    expect(ObjectVisuals.hitMarkerAlpha(1100, 1000, hitAnimations: true), 0);
    expect(ObjectVisuals.hitMarkerScale(1000, 1000), 1);
    expect(ObjectVisuals.hitMarkerScale(1175, 1000), closeTo(1 + 0.1 * (1 - 1 / 32), 1e-9));
    expect(ObjectVisuals.hitMarkerScale(1350, 1000), closeTo(1.1, 1e-9));
    expect(ObjectVisuals.hitMarkerScale(1700, 1000), closeTo(1.1, 1e-9));
  });

  test('dimmed until 400ms before, brightening over 100ms', () {
    expect(ObjectVisuals.brightness(500, 1000), closeTo(195 / 255, 1e-9));
    expect(ObjectVisuals.brightness(650, 1000), closeTo((195 / 255 + 1) / 2, 1e-9));
    expect(ObjectVisuals.brightness(700, 1000), 1);
  });

  test('approach circle: 4x to 1x, up to 0.9, gone 50ms after', () {
    expect(ObjectVisuals.approachScale(400, 1000, preempt), 4);
    expect(ObjectVisuals.approachScale(700, 1000, preempt), closeTo(2.5, 1e-9));
    expect(ObjectVisuals.approachScale(1000, 1000, preempt), 1);
    // Fades in over min(2 × fade-in, preempt) = 600ms.
    expect(ObjectVisuals.approachAlpha(700, 1000, preempt, fadeIn), closeTo(0.45, 1e-9));
    expect(ObjectVisuals.approachAlpha(1025, 1000, preempt, fadeIn), closeTo(0.45, 1e-9));
    expect(ObjectVisuals.approachAlpha(1050, 1000, preempt, fadeIn), 0);
  });

  test('slider body snakes in over a third of the preempt, fades 240ms after end', () {
    expect(ObjectVisuals.snakeProgress(500, 1000, preempt), closeTo(0.5, 1e-9));
    expect(ObjectVisuals.snakeProgress(600, 1000, preempt), 1);
    expect(ObjectVisuals.sliderBodyAlpha(2000, 1000, 2000, preempt, fadeIn), 1);
    expect(ObjectVisuals.sliderBodyAlpha(2120, 1000, 2000, preempt, fadeIn), closeTo(0.5, 1e-9));
    expect(ObjectVisuals.sliderBodyAlpha(2240, 1000, 2000, preempt, fadeIn), 0);
  });

  test('end circles: first after snaking, later ones two spans early', () {
    // Slider at 1000, span 500: first repeat at 1500 fades in from 600.
    expect(ObjectVisuals.endCircleAlpha(599, 0, 1500, 1000, 500, preempt, fadeIn), 0);
    expect(ObjectVisuals.endCircleAlpha(800, 0, 1500, 1000, 500, preempt, fadeIn), closeTo(0.5, 1e-9));
    // Second repeat (2000, at the head) pops in at 1000.
    expect(ObjectVisuals.endCircleAlpha(999, 1, 2000, 1000, 500, preempt, fadeIn), 0);
    expect(ObjectVisuals.endCircleAlpha(1000, 1, 2000, 1000, 500, preempt, fadeIn), 1);
    // Hit: linear fade over 700ms, arrow gone.
    expect(ObjectVisuals.endCircleAlpha(2350, 1, 2000, 1000, 500, preempt, fadeIn), closeTo(0.5, 1e-9));
    expect(ObjectVisuals.repeatArrowAlpha(2000, 1, 2000, 1000, 500, preempt), 0);
    expect(ObjectVisuals.repeatArrowAlpha(1075, 1, 2000, 1000, 500, preempt), closeTo(0.5, 1e-9));
  });

  test('slider ticks pop in with their own preempt and burst when passed', () {
    // First span tick 200ms into a slider at 1000: preempt 100 + 396.
    final p = ObjectVisuals.tickPreempt(1200, 1000, 0, preempt);
    expect(p, closeTo(100 + 600 * 0.66, 1e-9));
    expect(ObjectVisuals.tick(1200 - p - 1, 1200, p), isNull);
    final (a0, s0) = ObjectVisuals.tick(1200 - p, 1200, p)!;
    expect((a0, s0), (0, 0.5));
    final (a1, s1) = ObjectVisuals.tick(1199, 1200, p)!;
    expect(a1, 1);
    expect(s1, closeTo(1, 0.01));
    final (a2, s2) = ObjectVisuals.tick(1350, 1200, p)!;
    expect(a2, closeTo(0, 1e-9));
    expect(s2, closeTo(1.5, 0.01));
    // Later spans: half the distance from the span start + 200.
    expect(ObjectVisuals.tickPreempt(1700, 1500, 1, preempt), 300);
  });

  test('follow circle (classic): grows to 2x, bumps on ticks, grows to 1.6x and fades after the end', () {
    expect(ObjectVisuals.followCircle(999, 1000, 2000, null), isNull);
    expect(ObjectVisuals.followCircle(1000, 1000, 2000, null), (1.0, 0.0));
    expect(ObjectVisuals.followCircle(1060, 1000, 2000, null)!.$2, 1);
    final (grown, a) = ObjectVisuals.followCircle(1500, 1000, 2000, null)!;
    expect(grown, closeTo(2, 1e-9));
    expect(a, 1);
    expect(ObjectVisuals.followCircle(1500, 1000, 2000, 1500)!.$1, closeTo(2.2, 1e-9));
    expect(ObjectVisuals.followCircle(1600, 1000, 2000, 1500)!.$1, closeTo(2.1, 1e-9));
    expect(ObjectVisuals.followCircle(1700, 1000, 2000, 1500)!.$1, closeTo(2, 1e-9));
    // A tick before it has fully grown doesn't bump it.
    expect(ObjectVisuals.followCircle(1050, 1000, 2000, 1050)!.$1, lessThan(2));
    final (after, fading) = ObjectVisuals.followCircle(2100, 1000, 2000, null)!;
    expect(after, inExclusiveRange(1.6, 2));
    expect(fading, inExclusiveRange(0, 1));
    expect(ObjectVisuals.followCircle(2200, 1000, 2000, null), isNull);
  });

  test('the classic ball shows exactly from the start to the end', () {
    expect(ObjectVisuals.ballAlpha(999, 1000, 2000), 0);
    expect(ObjectVisuals.ballAlpha(1000, 1000, 2000), 1);
    expect(ObjectVisuals.ballAlpha(2000, 1000, 2000), 1);
    expect(ObjectVisuals.ballAlpha(2001, 1000, 2000), 0);
  });

  group('hit animations (classic skin)', () {
    test('circles grow to 1.4x while fading out over 240 ms; the number goes in 60 ms; no white', () {
      expect(ObjectVisuals.circleAlpha(1120, 1000, preempt, fadeIn, hitAnimations: true), closeTo(0.5, 1e-9));
      expect(ObjectVisuals.circleAlpha(1240, 1000, preempt, fadeIn, hitAnimations: true), 0);
      expect(ObjectVisuals.circleScale(999, 1000, hitAnimations: true), 1);
      expect(ObjectVisuals.circleScale(1240, 1000, hitAnimations: true), closeTo(1.4, 1e-9));
      expect(ObjectVisuals.circleScale(1240, 1000), 1);
      expect(ObjectVisuals.numberAlpha(1030, 1000, preempt, fadeIn, hitAnimations: true), closeTo(0.5, 1e-9));
      expect(ObjectVisuals.numberAlpha(1030, 1000, preempt, fadeIn), closeTo(1 - 30 / 700, 1e-9));
      expect(ObjectVisuals.shownWhite(1001, 1000), isTrue);
      expect(ObjectVisuals.shownWhite(1001, 1000, hitAnimations: true), isFalse);
      expect(ObjectVisuals.approachAlpha(1000, 1000, preempt, fadeIn, hitAnimations: true), 0);
    });

    test('repeats fade and their arrow grows over min(300, span); the slider fades 240 ms after its end', () {
      // Repeat k=0 at 1500 of a slider at 1000 with 500 ms spans.
      expect(ObjectVisuals.repeatArrowAlpha(1500, 0, 1500, 1000, 500, preempt), 0);
      expect(ObjectVisuals.repeatArrowAlpha(1800, 0, 1500, 1000, 500, preempt, hitAnimations: true), 0);
      expect(ObjectVisuals.repeatArrowScale(1800, 0, 1500, 1000, 500, preempt, hitAnimations: true),
          closeTo(1.4, 1e-9));
      expect(ObjectVisuals.endCircleAlpha(1740, 0, 1500, 1000, 500, preempt, fadeIn, hitAnimations: true), 0);
      expect(ObjectVisuals.sliderAlpha(2120, 2000, hitAnimations: true), closeTo(0.5, 1e-9));
      expect(ObjectVisuals.sliderAlpha(2120, 2000), 1);
    });

    test('repeat arrows pulse from 1.3x to 1x every 300 ms', () {
      // Appears with the slider (k = 0): from 1000 − preempt = 400.
      expect(ObjectVisuals.repeatArrowScale(400, 0, 1500, 1000, 500, preempt), closeTo(1.3, 1e-9));
      expect(ObjectVisuals.repeatArrowScale(699, 0, 1500, 1000, 500, preempt), closeTo(1, 1e-3));
      expect(ObjectVisuals.repeatArrowScale(700, 0, 1500, 1000, 500, preempt), closeTo(1.3, 1e-9));
    });
  });

  test('spinner grows in two steps and bursts at the end', () {
    expect(ObjectVisuals.spinner(600, 1000, 3000, preempt, fadeIn), (0.0, 0.0));
    expect(ObjectVisuals.spinner(850, 1000, 3000, preempt, fadeIn).$1, closeTo(0.2, 1e-9));
    expect(ObjectVisuals.spinner(1300, 1000, 3000, preempt, fadeIn).$1, closeTo(1, 1e-9));
    final (s, a) = ObjectVisuals.spinner(3120, 1000, 3000, preempt, fadeIn);
    expect(s, greaterThan(1));
    expect(a, closeTo(0.5, 1e-9));
    expect(ObjectVisuals.spinner(3320, 1000, 3000, preempt, fadeIn).$1, closeTo(1.2, 1e-9));
  });

  test('spinner fades in over fadeIn ending at its start', () {
    expect(ObjectVisuals.spinner(600, 1000, 3000, preempt, fadeIn).$2, 0);
    expect(ObjectVisuals.spinner(800, 1000, 3000, preempt, fadeIn).$2, closeTo(0.5, 1e-9));
    expect(ObjectVisuals.spinner(1000, 1000, 3000, preempt, fadeIn).$2, 1);
  });
}
