import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

void main() {
  // 120 BPM, SV 1.4: one 1/4 tick = 125ms, distance snap 1.0× = 0.28 px/ms × 125 = 35 px.
  final b = Beatmap.empty()..insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
  final timing = TimingInfo.of(b);

  List<HitCircle> make({int vertices = 4, int repeats = 1, double distance = 4, double angle = 0, double start = 1000}) =>
      PolygonOps.circles(
        timing: timing,
        sliderMultiplier: 1.4,
        distanceSpacing: 1,
        startTime: start,
        divisor: 4,
        vertices: vertices,
        repeats: repeats,
        distance: distance,
        angleDegrees: angle,
      );

  test('vertices × repeats circles, one tick apart, first is a new combo', () {
    final cs = make(vertices: 5, repeats: 2);
    expect(cs, hasLength(10));
    expect([for (final c in cs) c.time], [for (var i = 0; i < 10; i++) 1000.0 + 125 * i]);
    expect([for (final c in cs) c.newCombo], [true, ...List.filled(9, false)]);
  });

  test('corners around the centre; neighbouring corners are distance × snap apart', () {
    final cs = make(vertices: 4, distance: 4); // side 140 px
    for (final c in cs) {
      expect(c.position.distanceTo(PolygonOps.centre), closeTo(140 / (2 * math.sin(math.pi / 4)), 1));
    }
    expect(cs[0].position.distanceTo(cs[1].position), closeTo(140, 1.5));
    // Repeats retrace the same corners.
    final twice = make(vertices: 4, repeats: 2);
    expect(twice[4].position, twice[0].position);
  });

  test('angle turns the polygon', () {
    final a = make(vertices: 4, angle: 0), b2 = make(vertices: 4, angle: 45);
    expect(a.first.position, isNot(b2.first.position));
    expect(b2.first.position.distanceTo(PolygonOps.centre), closeTo(a.first.position.distanceTo(PolygonOps.centre), 1));
  });

  test('fits', () {
    expect(PolygonOps.fits(make()), isTrue);
    expect(PolygonOps.fits(make(distance: 6, vertices: 3)), isTrue);
    expect(PolygonOps.fits(make(distance: 6, vertices: 10)), isFalse); // radius ~170 px
  });

  test('reset samples and colour skips', () {
    final s = OsuParser.parseHitObject('100,100,1000,2,2,L|200:100,1,100,2|8,1:2|0:3,2:3:1:70:')! as SliderObject;
    final r = ResetOps.withoutSamples(s)! as SliderObject;
    expect(OsuWriter.encodeHitObject(r), '100,100,1000,2,0,L|200:100,1,100,0|0,0:0|0:0,0:0:0:0:');
    expect(ResetOps.withoutSamples(r), isNull);
    final c = HitCircle(position: Vec2.zero, time: 0, newCombo: true, comboSkip: 3);
    final c2 = ResetOps.withoutColourSkip(c)!;
    expect(c2.newCombo, isTrue);
    expect(c2.comboSkip, 0);
    expect(ResetOps.withoutColourSkip(c2), isNull);
  });
}
