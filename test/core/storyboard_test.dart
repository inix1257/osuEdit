import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

Storyboard parse(String events, [Map<String, String> vars = const {}]) =>
    Storyboard.parse([(events.split('\n'), vars)]);

void main() {
  group('StoryboardEasing', () {
    test('endpoints are exact for every easing', () {
      for (var e = 0; e < StoryboardEasing.count; e++) {
        expect(StoryboardEasing.apply(e, 0), 0, reason: 'easing $e at 0');
        expect(StoryboardEasing.apply(e, 1), 1, reason: 'easing $e at 1');
      }
    });

    test('known midpoints', () {
      expect(StoryboardEasing.apply(0, 0.25), 0.25);
      expect(StoryboardEasing.apply(1, 0.5), 0.75); // Out
      expect(StoryboardEasing.apply(2, 0.5), 0.25); // In
      expect(StoryboardEasing.apply(6, 0.5), 0.125); // InCubic
      expect(StoryboardEasing.apply(17, 0.5), closeTo(0.5, 1e-9)); // InOutSine
      expect(StoryboardEasing.apply(33, 1 / 2.75), closeTo(1, 1e-9)); // OutBounce first landing
    });

    test('in/out pairs mirror each other', () {
      for (final (i, o) in [(3, 4), (6, 7), (9, 10), (12, 13), (15, 16), (21, 22), (32, 33)]) {
        for (final t in [0.1, 0.3, 0.7]) {
          expect(StoryboardEasing.apply(o, t), closeTo(1 - StoryboardEasing.apply(i, 1 - t), 1e-9), reason: '$i/$o at $t');
        }
      }
    });
  });

  group('Storyboard.parse', () {
    test('sprite with fade, move and scale', () {
      final sb = parse('''
//Storyboard Layer 0 (Background)
Sprite,Background,Centre,"sb\\bg.png",320,240
 F,0,1000,2000,0,1
 M,0,1000,2000,100,200,300,400
 S,0,1500,,2
''');
      expect(sb.sprites, hasLength(1));
      final s = sb.sprites.single;
      expect(s.layer, StoryboardLayer.background);
      expect(s.origin, StoryboardOrigin.centre);
      expect(s.path, 'sb/bg.png');
      expect(s.startTime, 1000);
      expect(s.endTime, 2000);

      expect(s.stateAt(999), isNull);
      expect(s.stateAt(1000), isNull); // opacity 0
      final mid = s.stateAt(1500)!;
      expect(mid.opacity, 0.5);
      expect(mid.x, 200);
      expect(mid.y, 300);
      expect(mid.scaleX, 2); // instant scale at 1500
      // Before the scale command starts, its start value applies.
      expect(s.stateAt(1200)!.scaleX, 2);
      final end = s.stateAt(2000)!;
      expect((end.opacity, end.x, end.y), (1, 300, 400));
      expect(s.stateAt(2001), isNull);
    });

    test('without move commands the event position is used', () {
      final s = parse('Sprite,Foreground,TopLeft,a.png,10,20\n F,0,0,100,1').sprites.single;
      final st = s.stateAt(50)!;
      expect((st.x, st.y, st.scaleX, st.rotation), (10, 20, 1, 0));
    });

    test('MX / MY / R / V and easing', () {
      final s = parse('''
Sprite,Pass,0,a.png,0,0
_MX,2,0,100,0,100
_MY,0,0,100,50
_R,0,0,100,0,3.14
_V,0,0,100,1,1,2,3
''').sprites.single;
      final st = s.stateAt(50)!;
      expect(st.x, 25); // In = quad
      expect(st.y, 50);
      expect(st.rotation, closeTo(1.57, 1e-5));
      expect(st.scaleX, 1.5);
      expect(st.scaleY, 2);
    });

    test('later command wins; values held after it ends', () {
      final s = parse('''
Sprite,Background,Centre,a.png,0,0
 F,0,0,1000,1
 F,0,500,600,0.2,0.6
 F,0,2000,3000,0,1
''').sprites.single;
      expect(s.stateAt(400)!.opacity, 1);
      expect(s.stateAt(550)!.opacity, closeTo(0.4, 1e-6));
      expect(s.stateAt(1500)!.opacity, closeTo(0.6, 1e-6)); // float32
      expect(s.stateAt(2500)!.opacity, 0.5);
    });

    test('shorthand value chains become successive commands', () {
      final s = parse('Sprite,Background,Centre,a.png,0,0\n F,0,0,100,0,1,0').sprites.single;
      expect(s.endTime, 200);
      expect(s.stateAt(50)!.opacity, 0.5);
      expect(s.stateAt(150)!.opacity, 0.5);
      expect(s.stateAt(100)!.opacity, 1);
    });

    test('layers are drawn in order; later sources above earlier ones', () {
      final sb = Storyboard.parse([
        (['Sprite,Foreground,Centre,osu_fg.png,0,0', ' F,0,0,1,1', 'Sprite,Background,Centre,osu_bg.png,0,0', ' F,0,0,1,1'], {}),
        (['Sprite,Background,Centre,osb_bg.png,0,0', ' F,0,0,1,1', 'Sprite,Overlay,Centre,osb_ov.png,0,0', ' F,0,0,1,1'], {}),
      ]);
      expect(sb.sprites.map((s) => s.path), ['osu_bg.png', 'osb_bg.png', 'osu_fg.png', 'osb_ov.png']);
    });

    test('skips sprites without commands, broken animations and non-sprite events', () {
      final sb = parse('''
0,0,"bg.jpg",0,0
2,100,200
Sprite,Background,Centre,"none.png",320,240
Animation,Foreground,Centre,"anim.png",320,240
 F,0,0,100,1
Sprite,Background,Centre,"looped.png",320,240
 L,0,4
  F,0,0,100,0,1
 F,0,500,600,1
Sample,0,0,"hit.wav",100
 F,0,0,100,1
''');
      // The animation lacks its frame count / delay.
      expect(sb.sprites.map((s) => s.path), ['looped.png']);
      final s = sb.sprites.single;
      expect(s.startTime, 0); // the loop counts (4 x 0..100 from 0)
      expect(s.endTime, 600);
    });

    test('animation frames: paths, timing from the first command, loop types', () {
      final sb = parse(r'''
Animation,Foreground,Centre,"sb\fx\spark.png",320,240,3,100,LoopForever
 F,0,1000,2000,1
Animation,Foreground,Centre,"sb/once.png",320,240,3,100,LoopOnce
 F,0,1000,2000,1
6,3,1,"noext",0,0,2,50
 F,0,0,1000,1
Sprite,Foreground,Centre,"sb/still.png",0,0
 F,0,0,100,1
''');
      final [forever, once, numeric, still] = sb.sprites;
      expect(forever.framePaths, ['sb/fx/spark0.png', 'sb/fx/spark1.png', 'sb/fx/spark2.png']);
      expect([for (final t in <double>[900, 1000, 1099, 1100, 1250, 1300, 1999]) forever.frameAt(t)], [0, 0, 0, 1, 2, 0, 0]);
      expect([for (final t in <double>[1000, 1100, 1200, 1300, 1999]) once.frameAt(t)], [0, 1, 2, 2, 2]);
      expect(once.imageAt(1150), 'sb/once1.png');
      expect(numeric.framePaths, ['noext0', 'noext1']); // no extension: index appended
      expect(numeric.loopOnce, isFalse); // default LoopForever
      expect(still.framePaths, ['sb/still.png']);
      expect(still.imageAt(50), 'sb/still.png');
      expect(sb.imagePaths, hasLength(3 + 3 + 2 + 1));
    });

    test('a one-frame animation still uses the numbered file', () {
      final s = parse('Animation,Foreground,Centre,"a.png",0,0,1,100\n F,0,0,100,1').sprites.single;
      expect(s.framePaths, ['a0.png']);
    });

    test('variables are substituted, longest name first', () {
      final (events, vars) = Storyboard.splitOsb('''
[Variables]\r
\$p=Sprite,Background,Centre\r
\$pos=320,240\r
\r
[Events]\r
\$p,"a.png",\$pos\r
 F,0,0,100,1\r
''');
      expect(vars, {r'$p': 'Sprite,Background,Centre', r'$pos': '320,240'});
      final s = Storyboard.parse([(events, vars)]).sprites.single;
      expect(s.path, 'a.png');
      expect((s.initialX, s.initialY), (320, 240));
    });

    test('numeric layer/origin and malformed lines', () {
      final sb = parse('''
4,3,1,"x.png",1,2
 F,0,0,100,1
 F,x,y
 Q,0,0,100,1
Sprite,Nowhere,Centre,"bad.png",0,0
 F,0,0,100,1
''');
      final s = sb.sprites.single;
      expect(s.layer, StoryboardLayer.foreground);
      expect(s.origin, StoryboardOrigin.centre);
    });

    test('usesImage and imagePaths ignore case and separators', () {
      final sb = parse('Sprite,Background,Centre,"SB\\BG.jpg",0,0\n F,0,0,1,1\nSprite,Background,Centre,"sb/bg.JPG",0,0\n F,0,0,1,1');
      expect(sb.usesImage('sb\\bg.jpg'), isTrue);
      expect(sb.usesImage('bg.jpg'), isFalse);
      expect(sb.imagePaths, {'SB/BG.jpg'});
    });

    test('beatmapSource reads events and variables of a .osu', () {
      final b = OsuParser.parse('osu file format v14\n\n[General]\nWidescreenStoryboard: 1\n\n[Events]\nSprite,Background,Centre,"a.png",0,0\n F,0,0,1,1\n');
      final src = Storyboard.beatmapSource(b);
      expect(Storyboard.parse([src]).sprites, hasLength(1));
      expect(Storyboard.isWidescreen(b), isTrue);
    });
  });

  group('colour, parameters, loops, samples', () {
    test('C interpolates and chains; untinted sprites are white', () {
      final sb = parse('''
Sprite,Background,Centre,a.png,0,0
 C,0,0,100,255,0,0,0,0,255
 C,0,200,300,0,0,0,255,255,255,0,255,0
Sprite,Background,Centre,b.png,0,0
 F,0,0,100,1
''');
      final s = sb.sprites[0];
      final mid = s.stateAt(50)!.colour;
      expect((mid.r, mid.g, mid.b), (127.5, 0, 127.5));
      final held = s.stateAt(150)!.colour;
      expect((held.r, held.b), (0, 255));
      final chained = s.stateAt(350)!.colour; // second segment 300..400
      expect((chained.r, chained.g, chained.b), (127.5, 255, 127.5));
      expect(s.endTime, 400);
      expect(sb.sprites[1].stateAt(50)!.colour.isWhite, isTrue);
    });

    test('P is on during its span; an instant P lasts the whole life', () {
      final s = parse('''
Sprite,Background,Centre,a.png,0,0
 F,0,0,1000,1
 P,0,100,200,H
 P,0,500,500,A
 P,0,300,400,V
 P,0,0,1000,X
''').sprites.single;
      final at50 = s.stateAt(50)!, at150 = s.stateAt(150)!, at350 = s.stateAt(350)!;
      expect((at50.flipH, at50.flipV, at50.additive), (false, false, true));
      expect((at150.flipH, at150.flipV), (true, false));
      expect(s.stateAt(200)!.flipH, isFalse); // end is exclusive
      expect((at350.flipH, at350.flipV), (false, true));
      expect((s.startTime, s.endTime), (0, 1000));
    });

    test('an instant P does not stretch the lifetime', () {
      final s = parse('Sprite,Background,Centre,a.png,0,0\n P,0,0,0,A\n F,0,500,600,1').sprites.single;
      expect(s.startTime, 500);
      expect(s.stateAt(550)!.additive, isTrue);
    });

    test('L repeats its body; child times count from the loop start', () {
      final s = parse('''
Sprite,Background,Centre,a.png,0,0
 L,1000,3
  F,0,0,100,0,1
  F,0,100,200,1,0
 M,0,0,0,10,20
''').sprites.single;
      // Body spans 0..200 -> iterations at 1000, 1200, 1400.
      expect(s.opacity.starts, [1000, 1100, 1200, 1300, 1400, 1500]);
      expect(s.stateAt(1250)!.opacity, 0.5);
      expect(s.stateAt(1450)!.opacity, 0.5);
      expect(s.stateAt(1550)!.opacity, 0.5);
      expect((s.startTime, s.endTime), (0, 1600));
      expect(s.stateAt(500), isNull); // before the loop: first F's start value 0
    });

    test('loop body starting late keeps its offset; count 0 still runs once', () {
      final s = parse('''
Sprite,Background,Centre,a.png,0,0
 L,1000,0
  F,0,500,600,0,1
''').sprites.single;
      expect(s.opacity.starts, [1500]);
    });

    test('several loops and commands after them', () {
      final s = parse('''
Sprite,Background,Centre,a.png,0,0
 L,0,2
  MX,0,0,100,0,100
 L,1000,2
  MX,0,0,50,0,10
 F,0,0,2000,1
''').sprites.single;
      expect(s.x.starts, [0, 100, 1000, 1050]);
      expect(s.opacity.length, 1);
    });

    test('trigger children stay ignored', () {
      final s = parse('''
Sprite,Background,Centre,a.png,0,0
 T,HitSoundClap,0,1000
  F,0,0,100,1
 F,0,2000,3000,1
''').sprites.single;
      expect(s.startTime, 2000);
    });

    test('samples: sorted, default volume, Fail layer dropped, paths normalised', () {
      final sb = Storyboard.parse([
        (['Sample,500,3,"sb\\b.wav",40', 'Sample,100,0,"a.ogg"', '5,300,Fail,"f.wav",100', 'Sample,x,0,"bad.wav"'], {}),
        (['Sample,200,Pass,"A.ogg",70'], {}),
      ]);
      expect([for (final s in sb.samples) (s.time, s.path, s.volume)],
          [(100, 'a.ogg', 100), (200, 'A.ogg', 70), (500, 'sb/b.wav', 40)]);
      expect(sb.samplePaths, {'a.ogg', 'sb/b.wav'});
      expect(sb.sprites, isEmpty);
      expect(sb.isEmpty, isFalse);
    });
  });

  group('time index', () {
    test('forEachAlive matches a full scan, in draw order', () {
      final rnd = Random(7);
      final lines = <String>[];
      for (var i = 0; i < 600; i++) {
        final start = rnd.nextInt(120000) - 2000;
        // Mostly short sprites, some spanning far more than the bucket limit.
        final len = rnd.nextInt(10) == 0 ? rnd.nextInt(100000) : rnd.nextInt(3000);
        lines
          ..add('Sprite,${StoryboardLayer.values[rnd.nextInt(5)].name},Centre,"s$i.png",0,0')
          ..add(' F,0,$start,${start + len},1');
      }
      final sb = Storyboard.parse([(lines, {})]);
      for (var k = 0; k < 400; k++) {
        final t = rnd.nextDouble() * 130000 - 5000;
        final want = [
          for (var i = 0; i < sb.sprites.length; i++)
            if (t >= sb.sprites[i].startTime && t <= sb.sprites[i].endTime) i,
        ];
        final got = <int>[];
        sb.forEachAlive(t, (i, s) {
          expect(s, same(sb.sprites[i]));
          got.add(i);
        });
        expect(got, want, reason: 't=$t');
      }
      // Exactly on a lifetime boundary.
      final s0 = sb.sprites.first;
      for (final t in [s0.startTime, s0.endTime]) {
        var seen = false;
        sb.forEachAlive(t, (i, s) => seen |= identical(s, s0));
        expect(seen, isTrue);
      }
    });

    test('an empty storyboard visits nothing', () {
      var n = 0;
      Storyboard.empty.forEachAlive(0, (_, _) => n++);
      expect(n, 0);
    });
  });
}
