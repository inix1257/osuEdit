import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

/// sample_v14 (General SampleSet: Soft; green lines soft until 9000, then
/// normal): circles at 1000 (no additions) and 1333 (whistle), a slider at
/// 1666 (head whistle, tail none), a slider at 3666 (clap on the object but
/// none on its edges; head sets normal / soft), a spinner ending at 8000,
/// a circle at 9500 with sets normal / soft and volume 80.
void main() {
  final beatmap = OsuParser.parse(File('test/fixtures/sample_v14.osu').readAsStringSync());
  final timing = TimingInfo.of(beatmap);
  final notes = HitsoundLayers.notes(beatmap, timing);
  HitsoundNote at(double t) => notes.firstWhere((n) => (n.time - t).abs() < 1);

  test('one note per sounding point, sorted by time', () {
    final objs = beatmap.hitObjects;
    final edges = objs.fold(0, (n, h) => n + (h is SliderObject ? h.slides + 1 : 1));
    expect(notes, hasLength(edges));
    for (var i = 1; i < notes.length; i++) {
      expect(notes[i].time, greaterThanOrEqualTo(notes[i - 1].time));
    }
    final slider = objs[2] as SliderObject;
    final sliderNotes = notes.where((n) => identical(n.object, slider)).toList();
    expect([for (final n in sliderNotes) n.edge], [for (var i = 0; i <= slider.slides; i++) i]);
    expect(sliderNotes.last.time, closeTo(timing.sliderEndTime(slider, beatmap.sliderMultiplier), 0.01));
  });

  test('sample sets: inherited from the green line, or set on the object / edge', () {
    final plain = at(1000);
    expect(plain.normalSet, SampleSet.soft);
    expect(plain.normalInherited, isTrue);
    expect(plain.hasAdditions, isFalse);

    final whistle = at(1333);
    expect(whistle.whistle, isTrue);
    expect([whistle.finish, whistle.clap], [false, false]);
    expect(whistle.additionSet, SampleSet.soft);
    expect(whistle.additionInherited, isTrue);

    final head = at(3666);
    expect(head.normalSet, SampleSet.normal);
    expect(head.normalInherited, isFalse);
    expect(head.additionSet, SampleSet.soft);
    expect(head.additionInherited, isFalse);
    expect(head.clap, isFalse, reason: 'edge sounds win over the object\'s');

    final custom = at(9500);
    expect(custom.normalSet, SampleSet.normal);
    expect(custom.additionSet, SampleSet.soft);
    expect(custom.volume, 80);
  });

  group('sliders: head, repeats, tail and body', () {
    // Slider A (2000, 3 slides = head + 2 repeats + tail): body whistle,
    // sets soft / drum; edges whistle | clap | finish | none with sets
    // 1:2 | 2:0 | 0:3 | 3:3. A listed 0 means the timing point's set (soft
    // here) for the normal set and the edge's normal set for additions, not
    // the slider's own (lazer reads field 9 over a copy of field 10).
    // Slider B (6000, 2 slides): nothing set, so everything comes from the
    // soft green line at 5000; no body whistle.
    final text = File('test/fixtures/sample_v14.osu').readAsStringSync();
    final map = OsuParser.parse('${text.substring(0, text.indexOf('[HitObjects]'))}[HitObjects]\n'
        '100,100,2000,2,2,L|300:100,3,200,2|8|4|0,1:2|2:0|0:3|3:3,2:3:0:0:\n'
        '300,300,6000,2,0,L|400:300,2,100\n');
    final t = TimingInfo.of(map);
    final ns = HitsoundLayers.notes(map, t);
    final bodies = HitsoundLayers.bodies(map, t);
    final a = map.hitObjects[0] as SliderObject, b = map.hitObjects[1] as SliderObject;
    List<HitsoundNote> of(SliderObject s) => ns.where((n) => identical(n.object, s)).toList();

    test('one note per edge, at the head, each repeat and the tail', () {
      final span = t.sliderSpanDuration(a, map.sliderMultiplier);
      final edges = of(a);
      expect([for (final n in edges) n.edge], [0, 1, 2, 3]);
      for (var i = 0; i < 4; i++) {
        expect(edges[i].time, closeTo(a.time + span * i, 1e-6));
      }
      expect(edges.last.time, closeTo(t.sliderEndTime(a, map.sliderMultiplier), 1e-6), reason: 'tail');
      expect(of(b), hasLength(3));
    });

    test('each edge keeps its own sounds and sets', () {
      final e = of(a);
      expect([for (final n in e) n.additions],
          [HitSoundFlags.whistle, HitSoundFlags.clap, HitSoundFlags.finish, 0]);
      expect([for (final n in e) n.normalSet], [SampleSet.normal, SampleSet.soft, SampleSet.soft, SampleSet.drum]);
      expect([for (final n in e) n.additionSet], [SampleSet.soft, SampleSet.soft, SampleSet.drum, SampleSet.drum]);
      expect([for (final n in e) n.normalInherited], [false, false, true, false]);
      // B: all from the green line.
      for (final n in of(b)) {
        expect(n.normalSet, SampleSet.soft);
        expect(n.normalInherited, isTrue);
        expect(n.hasAdditions, isFalse);
      }
    });

    test('body: sliderslide set, and sliderwhistle only with body whistle', () {
      final ba = bodies.singleWhere((x) => identical(x.slider, a));
      expect([ba.start, ba.end], [a.time, t.sliderEndTime(a, map.sliderMultiplier)]);
      expect([ba.normalSet, ba.additionSet, ba.whistle], [SampleSet.soft, SampleSet.drum, true]);
      expect([ba.normalInherited, ba.additionInherited], [false, false]);
      final bb = bodies.singleWhere((x) => identical(x.slider, b));
      expect([bb.normalSet, bb.normalInherited, bb.whistle], [SampleSet.soft, true, false]);
    });

    test('the same as what plays', () {
      final plays = HitsoundResolver.resolve(map, t).where((p) => p.name != 'slidertick').toList();
      // Every note's sounds, in the same banks, and nothing else.
      final fromNotes = <String>[];
      for (final n in ns) {
        String at(String bank, String name) => '${n.time.toStringAsFixed(1)} $bank-$name';
        fromNotes.add(at(HitsoundResolver.bankName(n.normalSet), 'hitnormal'));
        final add = HitsoundResolver.bankName(n.additionSet);
        if (n.whistle) fromNotes.add(at(add, 'hitwhistle'));
        if (n.finish) fromNotes.add(at(add, 'hitfinish'));
        if (n.clap) fromNotes.add(at(add, 'hitclap'));
      }
      expect(fromNotes, [for (final p in plays) '${p.time.toStringAsFixed(1)} ${p.bank}-${p.name}']);
      final loops = HitsoundResolver.resolveBodies(map, t);
      final fromBodies = [
        for (final x in bodies) ...[
          '${x.start} ${HitsoundResolver.bankName(x.normalSet)}-sliderslide',
          if (x.whistle) '${x.start} ${HitsoundResolver.bankName(x.additionSet)}-sliderwhistle',
        ],
      ];
      expect(fromBodies, [for (final l in loops) '${l.start} ${l.sample.bank}-${l.sample.name}']);
    });
  });

  test('every fixture map: what the screen shows is exactly what plays', () {
    final files = Directory('test/fixtures').listSync().whereType<File>().where((f) => f.path.endsWith('.osu'));
    expect(files, isNotEmpty);
    for (final f in files) {
      _expectMatchesPlayback(OsuParser.parse(f.readAsStringSync()), f.path);
    }
  });

  group('index, volume, own file, ticks', () {
    // Green lines: 1000 soft index 0 vol 60 (red), 3666 soft vol 60, 5000
    // soft vol 70 (from the fixture), plus 2500 index 2 vol 30 and 3000
    // vol 90 added here. Objects: a circle with index 3 / volume 40, a
    // circle with its own file, a slider over the 2500 / 3000 lines (no own
    // volume: the body steps 60 -> 30 -> 90), a slider with its own volume.
    final text = File('test/fixtures/sample_v14.osu').readAsStringSync();
    final head = text.substring(0, text.indexOf('[HitObjects]'));
    final lines = head.replaceFirst(
        '3666,-100,4,2,0,60,0,0', '2500,-100,4,2,2,30,0,0\n3000,-100,4,2,2,90,0,0\n3666,-100,4,2,0,60,0,0');
    final map = OsuParser.parse('$lines[HitObjects]\n'
        '100,100,1000,1,2,0:0:3:40:\n'
        '200,100,1333,1,8,2:0:0:0:clap.wav\n'
        '100,300,2000,2,0,L|400:300,1,600\n'
        '300,300,4000,2,0,L|400:300,1,100,0|0,0:0|0:0,0:0:0:25:\n');
    final t = TimingInfo.of(map);
    final ns = HitsoundLayers.notes(map, t);

    test('index and volume: own or inherited', () {
      final own = ns.first;
      expect([own.index, own.indexInherited, own.volume, own.volumeInherited], [3, false, 40, false]);
      final slider = ns.firstWhere((n) => n.time == 2000);
      expect([slider.index, slider.indexInherited, slider.volume, slider.volumeInherited], [0, true, 60, true]);
      final tail = ns.firstWhere((n) => identical(n.object, map.hitObjects[2]) && n.edge == 1);
      expect([tail.index, tail.volume], [2, 90], reason: 'the green line at the tail');
    });

    test('own file: only the file plays', () {
      final f = ns.firstWhere((n) => n.time == 1333);
      expect(f.filename, 'clap.wav');
      expect(f.clap, isTrue, reason: 'still set on the object (shown faded)');
    });

    test("body volume steps with the green lines; a slider's own volume doesn't count", () {
      final bodies = HitsoundLayers.bodies(map, t);
      final b = bodies.firstWhere((b) => b.start == 2000);
      expect([b.volume, b.volumeInherited], [60, true]);
      expect(b.volumeChanges, [(2500.0, 30), (3000.0, 90)]);
      expect([b.volumeAt(2400), b.volumeAt(2600), b.volumeAt(3100)], [60, 30, 90]);
      // Its own 25 is ignored (osu! reads only a slider's sets): the 3666 line's 60.
      final own = bodies.firstWhere((b) => b.start == 4000);
      expect([own.volume, own.volumeInherited, own.volumeChanges], [60, true, isEmpty]);
    });

    test('ticks', () {
      final ticks = HitsoundLayers.ticks(map, t);
      expect(ticks, isNotEmpty);
      expect(ticks.every((k) => identical(k.slider, map.hitObjects[2]) || identical(k.slider, map.hitObjects[3])), isTrue);
    });

    test('the same as what plays', () => _expectMatchesPlayback(map, 'crafted'));
  });

  test('a spinner sounds at its end', () {
    final spinner = beatmap.hitObjects.whereType<Spinner>().single;
    final n = notes.singleWhere((n) => identical(n.object, spinner));
    expect(n.time, closeTo(timing.endTimeOf(spinner, beatmap.sliderMultiplier), 0.01));
  });

  test('matches the hitsounds that play', () {
    // Every hitwhistle / hitfinish / hitclap the resolver plays is a note
    // with that addition, in the same bank.
    final plays = HitsoundResolver.resolve(beatmap, timing).where((p) => p.name != 'slidertick');
    for (final p in plays) {
      final n = notes.firstWhere((n) => (n.time - p.time).abs() < 0.01);
      switch (p.name) {
        case 'hitnormal':
          expect(HitsoundResolver.bankName(n.normalSet), p.bank);
        case 'hitwhistle':
          expect(n.whistle, isTrue);
          expect(HitsoundResolver.bankName(n.additionSet), p.bank);
        case 'hitfinish':
          expect(n.finish, isTrue);
        case 'hitclap':
          expect(n.clap, isTrue);
      }
    }
  });
}

/// Every sound the Hitsound screen shows for [map] (notes with their banks,
/// index and volume; own files; bodies with their volume; ticks) is
/// exactly what [HitsoundResolver] plays.
void _expectMatchesPlayback(Beatmap map, String reason) {
  final t = TimingInfo.of(map);
  final shown = <String>[];
  for (final n in HitsoundLayers.notes(map, t)) {
    String at(String bank, String name) => '${n.time.toStringAsFixed(1)} $bank-$name i${n.index} v${n.volume}';
    final normal = HitsoundResolver.bankName(n.normalSet), add = HitsoundResolver.bankName(n.additionSet);
    if (n.filename.isNotEmpty) {
      shown.add('${n.time.toStringAsFixed(1)} file ${n.filename} v${n.volume}');
      continue;
    }
    shown.add(at(normal, 'hitnormal'));
    if (n.whistle) shown.add(at(add, 'hitwhistle'));
    if (n.finish) shown.add(at(add, 'hitfinish'));
    if (n.clap) shown.add(at(add, 'hitclap'));
  }
  final plays = HitsoundResolver.resolve(map, t);
  expect(shown, [
    for (final p in plays)
      if (p.name != 'slidertick')
        p.filename != null
            ? '${p.time.toStringAsFixed(1)} file ${p.filename} v${p.volume}'
            : '${p.time.toStringAsFixed(1)} ${p.bank}-${p.name} i${p.index} v${p.volume}',
  ], reason: reason);

  final ticks = [
    for (final k in HitsoundLayers.ticks(map, t))
      '${k.time.toStringAsFixed(1)} ${HitsoundResolver.bankName(k.set)} v${k.volume}',
  ]..sort();
  expect(ticks, [
    for (final p in plays)
      if (p.name == 'slidertick') '${p.time.toStringAsFixed(1)} ${p.bank} v${p.volume}',
  ]..sort(), reason: reason);

  final bodies = [
    for (final x in HitsoundLayers.bodies(map, t)) ...[
      '${x.start} ${HitsoundResolver.bankName(x.normalSet)}-sliderslide v${x.volume} ${x.volumeChanges}',
      if (x.whistle) '${x.start} ${HitsoundResolver.bankName(x.additionSet)}-sliderwhistle v${x.volume} ${x.volumeChanges}',
    ],
  ];
  expect(bodies, [
    for (final l in HitsoundResolver.resolveBodies(map, t))
      '${l.start} ${l.sample.bank}-${l.sample.name} v${l.sample.volume} ${l.volumeChanges}',
  ], reason: reason);
}
