import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

/// Points every [step] px along a path (for shape comparisons).
List<Vec2> _samples(SliderPath p, {double step = 4}) => [
      for (var d = 0.0; d <= p.distance; d += step) p.positionAtDistance(d),
      p.tail,
    ];

/// Largest distance from a sample of [a] to the nearest sample of [b].
double _maxGap(SliderPath a, SliderPath b) {
  final sb = _samples(b, step: 0.5);
  var worst = 0.0;
  for (final p in _samples(a)) {
    var best = double.infinity;
    for (final q in sb) {
      final d = p.distanceTo(q);
      if (d < best) best = d;
    }
    if (best > worst) worst = best;
  }
  return worst;
}

SliderObject _slider(String line, {int version = 128}) =>
    OsuParser.parseHitObject(line, formatVersion: version)! as SliderObject;

void main() {
  group('isLazerCurve', () {
    test('stable syntax is not lazer', () {
      expect(LazerPath.isLazerCurve('B|1:2|3:4|3:4|5:6'), isFalse);
      expect(LazerPath.isLazerCurve('P|1:2|3:4'), isFalse);
      expect(LazerPath.isLazerCurve('C|1:2'), isFalse);
    });
    test('mid-path types and B-spline degrees are lazer', () {
      expect(LazerPath.isLazerCurve('B|1:2|3:4|L|5:6|7:8'), isTrue);
      expect(LazerPath.isLazerCurve('B|1:2|B|3:4|5:6'), isTrue);
      expect(LazerPath.isLazerCurve('B4|1:2|3:4|5:6'), isTrue);
    });
  });

  group('decode (lazer ConvertHitObjectParser)', () {
    test('explicit segments: the type sits on the segment start', () {
      final (pts, types) = LazerPath.decode(const Vec2(100, 100), 'B|200:100|300:200|P|350:250|400:100|450:200');
      expect(pts, const [Vec2(100, 100), Vec2(200, 100), Vec2(300, 200), Vec2(350, 250), Vec2(400, 100), Vec2(450, 200)]);
      expect(types, [PathType.bezier, null, null, PathType.perfectCurve, null, null]);
    });

    test('a doubled point splits a segment and is not kept twice', () {
      final (pts, types) = LazerPath.decode(const Vec2(0, 0), 'B|10:0|20:10|20:10|30:0|L|40:0|50:0');
      expect(pts, const [Vec2(0, 0), Vec2(10, 0), Vec2(20, 10), Vec2(30, 0), Vec2(40, 0), Vec2(50, 0)]);
      expect(types, [PathType.bezier, null, PathType.bezier, null, PathType.linear, null]);
    });

    test('B-spline degree', () {
      final (_, types) = LazerPath.decode(Vec2.zero, 'B4|10:0|20:10|30:0|40:10|50:0');
      expect(types.first, PathType.bSpline4);
      expect(types.first!.code, 'B4');
    });

    test('old files: a perfect curve of other than three points is bezier, a collinear one linear', () {
      expect(LazerPath.decode(Vec2.zero, 'L|10:0|P|20:10|30:0|40:10|50:0', formatVersion: 14).$2[2], PathType.bezier);
      expect(LazerPath.decode(Vec2.zero, 'P|10:0|20:0', formatVersion: 14).$2.first, PathType.linear);
      // lazer's own format keeps them.
      expect(LazerPath.decode(Vec2.zero, 'P|10:0|20:0', formatVersion: 128).$2.first, PathType.perfectCurve);
    });
  });

  group('parse / write', () {
    const line = '100,100,1000,2,0,B|200:100|300:200|P|350:250|400:100|450:200,1,500';

    test('a lazer path is read into pointTypes; the untouched line is kept', () {
      final s = _slider(line);
      expect(s.isLazerPath, isTrue);
      expect(s.curveType, CurveType.bezier);
      expect(s.pointTypes, [PathType.bezier, null, null, PathType.perfectCurve, null, null]);
      expect(s.sourceLine, line);
      final file = 'osu file format v128\r\n\r\n[HitObjects]\r\n$line\r\n';
      expect(OsuWriter.write(OsuParser.parse(file)), file);
    });

    test('an edited lazer slider is written in lazer syntax and reads back the same', () {
      final s = _slider(line).translated(const Vec2(5, 5));
      final out = OsuWriter.encodeHitObject(s);
      expect(out, startsWith('105,105,1000,2,0,B|205:105|305:205|P|355:255|405:105|455:205,1,500'));
      final again = _slider(out);
      expect(again.allPoints, s.allPoints);
      expect(again.pointTypes, s.pointTypes);
    });

    test('a lazer path stable can express is written in stable syntax', () {
      // Bezier segments joined by bezier-typed points = stable red anchors.
      final s = _slider('0,0,0,2,0,B|10:0|B|20:10|30:0,1,40').translated(Vec2.zero);
      expect(OsuWriter.encodeCurve(s), 'B|10:0|20:10|20:10|30:0');
      // Linear segments are one linear path.
      final l = _slider('0,0,0,2,0,L|10:0|L|20:10|30:0,1,40');
      expect(OsuWriter.encodeCurve(l), 'L|10:0|20:10|30:0');
    });

    test('stable files are unaffected', () {
      final s = OsuParser.parseHitObject('0,0,0,2,0,B|10:0|20:10|20:10|30:0,1,40')! as SliderObject;
      expect(s.isLazerPath, isFalse);
      expect(s.controlPoints.length, 4);
    });
  });

  group('shape', () {
    test('a lazer path draws each segment with its own type', () {
      // In lazer's syntax a type letter comes right before its segment's first point.
      final s = _slider('100,100,0,2,0,L|P|200:100|250:150|300:100,1,0');
      final p = SliderPath.of(s);
      // Linear to (200,100), then a half circle of radius 50 down to (300,100).
      expect(p.distance, closeTo(100 + 50 * 3.14159265, 0.5));
      expect(p.positionAtDistance(50), const Vec2(150, 100));
    });

    test('B-spline of degree 1 is the control polygon', () {
      final s = _slider('0,0,0,2,0,B1|100:0|100:100,1,0');
      expect(SliderPath.of(s).distance, closeTo(200, 1e-6));
    });
  });

  group('convert to stable (lazer BezierConverter)', () {
    for (final (name, line) in const [
      ('linear + perfect', '100,100,0,2,0,L|P|200:100|250:150|300:100,1,0'),
      ('bezier + catmull', '100,100,0,2,0,B|150:50|200:100|C|250:150|300:100|350:150,1,0'),
      ('B-spline', '50,50,0,2,0,B4|100:200|200:0|300:200|400:0|450:150,1,0'),
      ('two perfect curves', '50,200,0,2,0,P|100:150|P|150:200|200:250|250:200,1,0'),
    ]) {
      test('$name keeps its shape', () {
        final s = _slider(line);
        final c = SliderFormatOps.toStable(s);
        expect(c.isLazerPath, isFalse);
        expect(c.curveType, CurveType.bezier);
        expect(LazerPath.isLazerCurve(OsuWriter.encodeCurve(c)), isFalse);
        final full = SliderPath.of(s).distance;
        final a = SliderPath.of(s.copyWith(length: full)), b = SliderPath.of(c.copyWith(length: full));
        expect(_maxGap(a, b), lessThan(1.5), reason: 'shape');
        expect(_maxGap(b, a), lessThan(1.5), reason: 'shape (reverse check)');
      });
    }

    test('a path stable can express keeps its type', () {
      final c = SliderFormatOps.toStable(_slider('0,0,0,2,0,L|10:0|L|20:10|30:0,1,40'));
      expect(c.curveType, CurveType.linear);
      expect(c.controlPoints, const [Vec2(10, 0), Vec2(20, 10), Vec2(30, 0)]);
    });

    test('convertText only changes the lazer sliders', () {
      const text = 'osu file format v128\r\n\r\n[HitObjects]\r\n'
          '0,0,0,1,0,0:0:0:0:\r\n'
          '100,100,500,2,0,L|200:100|P|250:150|300:100,1,250\r\n'
          '0,0,900,2,0,B|10:0|20:10|20:10|30:0,1,40\r\n';
      final out = SliderFormatOps.convertText(text)!;
      final a = text.split('\r\n'), b = out.split('\r\n');
      expect(b.length, a.length);
      for (var i = 0; i < a.length; i++) {
        if (i == 4) {
          expect(b[i], isNot(a[i]));
          expect(b[i], startsWith('100,100,500,2,0,B|'));
          expect(b[i], contains(',1,250,'));
        } else {
          expect(b[i], a[i]);
        }
      }
      expect(SliderFormatOps.convertText(out), isNull);
    });
  });

  group('lazer editing rules', () {
    test('ensureValid: a perfect curve of four points becomes bezier', () {
      const pts = [Vec2(0, 0), Vec2(10, 10), Vec2(20, 0), Vec2(30, 10)];
      expect(LazerPath.ensureValid(pts, [PathType.perfectCurve, null, null, null]).first, PathType.bezier);
      expect(LazerPath.ensureValid(pts.sublist(0, 3), [PathType.perfectCurve, null, null]).first, PathType.perfectCurve);
    });

    test('typedOf reads a stable slider the way lazer does', () {
      final s = OsuParser.parseHitObject('0,0,0,2,0,B|10:0|20:10|20:10|30:0,1,40')! as SliderObject;
      final pts = SliderShape.typedOf(s);
      expect([for (final p in pts) p.position], const [Vec2(0, 0), Vec2(10, 0), Vec2(20, 10), Vec2(30, 0)]);
      expect([for (final p in pts) p.type], [PathType.bezier, null, PathType.bezier, null]);
    });
  });

  group('reverse', () {
    for (final (name, line) in const [
      ('linear + perfect, cut in the arc', '100,100,0,2,0,L|P|200:100|250:150|300:100,1,180'),
      ('bezier + linear, extended', '100,100,0,2,0,B|150:50|200:100|L|260:100,1,250'),
      ('B-spline, cut', '50,50,0,2,0,B4|100:200|200:0|300:200|400:0|450:150,1,300'),
    ]) {
      test('$name: same shape backwards', () {
        final s = _slider(line);
        final path = SliderPath.of(s);
        final r = PatternOps.reversedPath(s, path);
        expect(r.isLazerPath, isTrue);
        expect(r.pointTypes!.first, isNotNull);
        final rp = SliderPath.of(r);
        expect(rp.head.distanceTo(path.tail), lessThan(1));
        expect(rp.tail.distanceTo(path.head), lessThan(1));
        expect(_maxGap(path, rp), lessThan(2));
        expect(_maxGap(rp, path), lessThan(2));
      });
    }
  });
}
