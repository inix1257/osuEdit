import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

void main() {
  final b = OsuParser.parse(File('test/fixtures/sample_v14.osu').readAsStringSync());
  final timing = TimingInfo.of(b);
  final plays = HitsoundResolver.resolve(b, timing);

  List<String> at(double t) => [
        for (final p in plays.where((p) => (p.time - t).abs() < 0.5)) '${p.bank}-${p.name}'
      ];
  SamplePlay first(double t) => plays.firstWhere((p) => (p.time - t).abs() < 0.5);

  test('plays are sorted by time', () {
    for (var i = 1; i < plays.length; i++) {
      expect(plays[i].time, greaterThanOrEqualTo(plays[i - 1].time));
    }
  });

  test('normal always plays; additions use the timing point bank and volume', () {
    expect(at(1000), ['soft-hitnormal']);
    expect(first(1000).volume, 60);
    expect(at(1333), ['soft-hitnormal', 'soft-hitwhistle']);
  });

  test('slider edges use edgeSounds / edgeSets', () {
    final s = b.hitObjects[2] as SliderObject;
    final end = s.time + timing.sliderSpanDuration(s, b.sliderMultiplier);
    expect(at(s.time), ['soft-hitnormal', 'soft-hitwhistle']);
    expect(at(end), ['soft-hitnormal']);

    // 3666: edgeSets 1:2 on the head, 0:0 (inherit) on the tail.
    final s2 = b.hitObjects[4] as SliderObject;
    final end2 = s2.time + timing.sliderSpanDuration(s2, b.sliderMultiplier);
    expect(at(s2.time), ['normal-hitnormal']);
    expect(at(end2), ['soft-hitnormal']);
  });

  test('repeat slider sounds on every edge', () {
    final s = b.hitObjects[3] as SliderObject;
    expect(s.slides, 2);
    final span = timing.sliderSpanDuration(s, b.sliderMultiplier);
    for (var i = 0; i <= 2; i++) {
      expect(at(s.time + span * i), isNotEmpty, reason: 'edge $i');
    }
  });

  test('spinner sounds at its end time', () {
    expect(at(6333), isEmpty);
    expect(at(8000), ['soft-hitnormal']);
    expect(first(8000).volume, 70);
  });

  test('object sample overrides sets and volume; point supplies custom index', () {
    // 9000: red point with sampleSet 1 (normal), index 1, volume 50.
    expect(at(9000), ['normal-hitnormal']);
    expect(first(9000).index, 1);
    expect(first(9000).customStem, 'normal-hitnormal');
    // 9500: 1:2:0:80
    expect(at(9500), ['normal-hitnormal']);
    expect(first(9500).volume, 80);
  });

  test('custom index and filename', () {
    expect(const SamplePlay(time: 0, bank: 'soft', name: 'hitclap', index: 3).customStem, 'soft-hitclap3');
    expect(const SamplePlay(time: 0, bank: 'soft', name: 'hitclap').customStem, isNull);

    final m = OsuParser.parse(File('test/fixtures/sample_v14.osu').readAsStringSync());
    final h = m.hitObjects[0];
    m.hitObjects[0] = h.copyWithBase(hitSound: HitSoundFlags.clap, sample: const HitSample(filename: 'boom.wav'));
    final p = HitsoundResolver.resolve(m, TimingInfo.of(m)).where((p) => p.time == h.time).toList();
    expect(p.length, 1);
    expect(p.single.filename, 'boom.wav');
  });
  test('slider ticks play slidertick from the normal bank, in every span', () {
    final m = Beatmap.empty();
    m.insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
    // SM 1.4 at 120 BPM: 0.28 px/ms, so 280 px = 1000 ms per span; one tick at 140 px.
    m.insertHitObject(const SliderObject(
      position: Vec2(0, 0),
      time: 0,
      curveType: CurveType.linear,
      controlPoints: [Vec2(300, 0)],
      length: 280,
      slides: 2,
      sample: HitSample(normalSet: SampleSet.soft),
    ));
    final ticks = HitsoundResolver.resolve(m, TimingInfo.of(m)).where((p) => p.name == 'slidertick').toList();
    expect([for (final p in ticks) p.time], [closeTo(500, 1e-6), closeTo(1500, 1e-6)]);
    expect(ticks.every((p) => p.bank == 'soft'), isTrue);
  });
  test('slider bodies: slide in the normal bank, whistle loop only with a whistle body', () {
    final bodies = HitsoundResolver.resolveBodies(b, timing);
    final sliders = b.hitObjects.whereType<SliderObject>().toList();
    expect(bodies.where((x) => x.sample.name == 'sliderslide'), hasLength(sliders.length));
    expect(bodies.every((x) => x.end > x.start), isTrue);
    final first = bodies.first;
    expect(first.start, sliders.first.time);
    expect(first.end, closeTo(timing.sliderEndTime(sliders.first, b.sliderMultiplier), 1e-6));
    expect('${first.sample.bank}-${first.sample.name}', 'soft-sliderslide');
    expect(first.sample.volume, 60);
    // No slider in the sample map has whistle on its body.
    expect(bodies.where((x) => x.sample.name == 'sliderwhistle'), isEmpty);

    final m = Beatmap.empty();
    m.insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
    m.insertHitObject(const SliderObject(
      position: Vec2(0, 0),
      time: 0,
      curveType: CurveType.linear,
      controlPoints: [Vec2(100, 0)],
      length: 100,
      hitSound: HitSoundFlags.whistle,
      sample: HitSample(normalSet: SampleSet.normal, additionSet: SampleSet.drum),
    ));
    expect([for (final x in HitsoundResolver.resolveBodies(m, TimingInfo.of(m))) '${x.sample.bank}-${x.sample.name}'],
        ['normal-sliderslide', 'drum-sliderwhistle']);
  });
}
