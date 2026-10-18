import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

/// Background rules matched to osu!lazer's decoder.
Beatmap _map(String timing, String objects) => OsuParser.parse('osu file format v14\n\n'
    '[General]\nSampleSet: Normal\n\n[Difficulty]\nSliderMultiplier:1\nSliderTickRate:1\n\n'
    '[TimingPoints]\n$timing\n\n[HitObjects]\n$objects\n');

void main() {
  group("3: a slider's own index / volume / file don't count", () {
    // Red at 0: normal set, index 2, volume 40.
    final map = _map('0,500,4,1,2,40,1,0',
        '100,100,1000,2,8,L|300:100,1,200,8|8,0:0|0:0,2:0:7:90:boom.wav\n'
        '100,100,3000,1,8,0:0:7:90:\n');
    final plays = HitsoundResolver.resolve(map, TimingInfo.of(map));

    test('slider edges: sets from the slider, index / volume from the point, no file', () {
      final edges = plays.where((p) => p.time < 2500 && p.name == 'hitclap').toList();
      expect(edges, hasLength(2));
      for (final p in edges) {
        expect([p.bank, p.index, p.volume, p.filename], ['normal', 2, 40, null],
            reason: 'edge set 0 = the point set; own index 7 / volume 90 / boom.wav ignored');
      }
      final head = plays.firstWhere((p) => p.time == 1000 && p.name == 'hitnormal');
      expect(head.bank, 'normal');
    });

    test('slider body takes the point index / volume too', () {
      final body = HitsoundResolver.resolveBodies(map, TimingInfo.of(map)).single;
      expect([body.sample.bank, body.sample.index, body.sample.volume], ['soft', 2, 40]);
    });

    test('circles keep their own index and volume', () {
      final circle = plays.firstWhere((p) => p.time == 3000 && p.name == 'hitnormal');
      expect([circle.index, circle.volume], [7, 90]);
    });
  });

  group('4: slider duration follows the path distance', () {
    // 120 BPM, SM 1: 100 px per beat = 500 ms.
    double end(String slider) {
      final map = _map('0,500,4,1,0,100,1,0', slider);
      final s = map.hitObjects.single as SliderObject;
      return TimingInfo.of(map).sliderEndTime(s, map.sliderMultiplier);
    }

    test('the length field when the path can reach it', () {
      expect(end('100,100,1000,2,0,L|200:100,1,150'), 1750, reason: 'extended in a straight line');
      expect(end('100,100,1000,2,0,L|300:100,1,150'), 1750, reason: 'trimmed');
    });

    test("a path ending in a repeated point isn't extended", () {
      expect(end('100,100,1000,2,0,L|200:100|200:100,1,150'), 1500);
    });

    test('length 0 or missing: the computed path', () {
      expect(end('100,100,1000,2,0,L|200:100,1,0'), 1500);
      expect(end('100,100,1000,2,0,L|200:100,1'), 1500);
    });

    test('a slider line without length keeps its line on save', () {
      const line = '100,100,1000,2,0,L|200:100,1';
      final map = _map('0,500,4,1,0,100,1,0', line);
      expect(map.hitObjects.single, isA<SliderObject>());
      expect(OsuWriter.write(map), contains(line));
    });
  });

  group('5: several points at one time', () {
    test('a green line beats a red one whatever their order', () {
      final map = _map('1000,-50,4,2,0,70,0,1\n1000,500,4,1,0,100,1,0', '');
      final t = TimingInfo.of(map);
      final p = t.effectivePointAt(1000)!;
      expect([p.inherited, p.sliderVelocity, p.kiai, p.volume], [true, 2, true, 70]);
      expect(t.beatLengthAt(1000), 500);
    });

    test('the first red line wins, and only it snaps', () {
      final map = _map('0,500,4,1,0,100,1,0\n1000,400,4,1,0,100,1,0\n1000,250,3,2,0,50,1,0', '');
      final t = TimingInfo.of(map);
      expect(t.beatLengthAt(1000), 400);
      expect(t.effectivePointAt(1500)!.beatLength, 400);
      expect([for (final p in t.redPoints) p.time], [0, 1000]);
      expect(t.snap(1390, 1), 1400, reason: 'the 400 ms grid from 1000');
      expect(t.points, hasLength(3), reason: 'every point is still listed');
    });

    test('before the first point: the one in effect at it', () {
      final map = _map('1000,500,4,1,0,100,1,0\n1000,-50,4,2,0,70,0,0', '');
      expect(TimingInfo.of(map).effectivePointAt(0)!.inherited, isTrue);
    });
  });

  group('6: a listed edge set of 0 is the point set', () {
    // Point: soft. Slider sets drum:normal; edges 0:0 | (unlisted).
    final map = _map('0,500,4,2,0,100,1,0', '100,100,1000,2,8,L|300:100,1,200,8,0:0,3:1:0:0:');
    final plays = HitsoundResolver.resolve(map, TimingInfo.of(map));

    test("listed 0:0 takes the timing point's set, not the slider's", () {
      final head = plays.where((p) => p.time == 1000).map((p) => '${p.bank}-${p.name}');
      expect(head, ['soft-hitnormal', 'soft-hitclap']);
    });

    test("an unlisted edge takes the slider's sets", () {
      final tail = plays.where((p) => p.time > 1000 && !p.name.startsWith('slider')).map((p) => '${p.bank}-${p.name}');
      expect(tail, ['drum-hitnormal', 'normal-hitclap']);
    });
  });
}
