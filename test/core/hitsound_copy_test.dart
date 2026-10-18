import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

Beatmap _load(String name) => OsuParser.parse(File('test/fixtures/$name').readAsStringSync());

/// What the map sounds like: every sample osu! would play.
List<String> _sounds(Beatmap b) => [
      for (final s in HitsoundResolver.resolve(b, TimingInfo.of(b)))
        '${s.time.round()} ${s.bank}-${s.name} i${s.index} v${s.volume}',
    ];

/// [b] with no hitsounds at all: objects reset, timing points on normal,
/// index 0, volume 100.
Beatmap _stripped(Beatmap b) {
  final objs = b.hitObjects.toList();
  final reset = [for (final h in objs) ResetOps.withoutSamples(h) ?? h];
  ReplaceHitObjectsCommand(objs, reset).apply(b);
  for (final p in b.timingPoints.toList()) {
    ReplaceTimingPointCommand(
      p,
      TimingPoint(
        time: p.time,
        beatLength: p.beatLength,
        meter: p.meter,
        sampleSet: 1,
        uninherited: p.uninherited,
        effects: p.effects,
      ),
    ).apply(b);
  }
  return b;
}

void main() {
  for (final fixture in ['sample_v14.osu', 'sync_test_v14.osu']) {
    test('$fixture: a copy with no hitsounds sounds exactly like the source afterwards', () {
      final source = _load(fixture);
      final target = _stripped(_load(fixture));
      expect(_sounds(target), isNot(_sounds(source)), reason: 'the fixture has hitsounds to copy');
      HitsoundCopyOps.copy(source: source, target: target)!.apply(target);
      expect(_sounds(target), _sounds(source));
      // Timing, slider velocity and kiai are untouched.
      final timing = TimingInfo.of(target), src = TimingInfo.of(source);
      for (final h in target.hitObjects) {
        expect(timing.sliderVelocityAt(h.time), src.sliderVelocityAt(h.time));
        expect(timing.beatLengthAt(h.time), src.beatLengthAt(h.time));
        expect(timing.kiaiAt(h.time), src.kiaiAt(h.time));
      }
      expect(HitsoundCopyOps.copy(source: source, target: target), isNull, reason: 'nothing left to change');
    });
  }

  test('matching uses the leniency; unmatched objects are kept unless clearing', () {
    final source = Beatmap.empty()
      ..hitObjects.addAll([
        const HitCircle(position: Vec2(100, 100), time: 1000, hitSound: HitSoundFlags.whistle),
        const HitCircle(position: Vec2(200, 100), time: 2000, hitSound: HitSoundFlags.clap),
      ]);
    Beatmap target() => Beatmap.empty()
      ..hitObjects.addAll([
        const HitCircle(position: Vec2(300, 300), time: 1003), // 3 ms off: matched
        const HitCircle(position: Vec2(300, 300), time: 1500, hitSound: HitSoundFlags.finish), // no source
        const HitCircle(position: Vec2(300, 300), time: 2010), // 10 ms off: not matched
      ]);

    final kept = target();
    HitsoundCopyOps.copy(source: source, target: kept, samplePoints: false)!.apply(kept);
    expect([for (final h in kept.hitObjects) h.hitSound], [HitSoundFlags.whistle, HitSoundFlags.finish, 0]);
    expect(kept.hitObjects.first.position, const Vec2(300, 300), reason: 'only sounds change');

    final cleared = target();
    HitsoundCopyOps.copy(source: source, target: cleared, samplePoints: false, clearUnmatched: true)!.apply(cleared);
    expect([for (final h in cleared.hitObjects) h.hitSound], [HitSoundFlags.whistle, 0, 0]);

    final wide = target();
    HitsoundCopyOps.copy(source: source, target: wide, samplePoints: false, leniency: 15)!.apply(wide);
    expect([for (final h in wide.hitObjects) h.hitSound], [HitSoundFlags.whistle, HitSoundFlags.finish, HitSoundFlags.clap]);
  });

  test('a different difficulty (other slider shapes) takes the sounds at its own edge times', () {
    final source = _load('sample_v14.osu');
    final target = _stripped(_load('sample_v14.osu'));
    // The target turns the slider at 1666 into a circle: it takes the head's sound.
    final slider = target.hitObjects.firstWhere((h) => h is SliderObject && h.time == 1666);
    ReplaceHitObjectsCommand([slider], [HitCircle(position: slider.position, time: slider.time)]).apply(target);
    HitsoundCopyOps.copy(source: source, target: target, samplePoints: false)!.apply(target);
    final srcSlider = source.hitObjects.firstWhere((h) => h is SliderObject && h.time == 1666) as SliderObject;
    final circle = target.hitObjects.firstWhere((h) => h.time == 1666);
    expect(circle.hitSound, srcSlider.edgeSounds?.first ?? srcSlider.hitSound);
  });
}
