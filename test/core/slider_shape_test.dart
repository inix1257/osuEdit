import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

void main() {
  const a = Vec2(0, 0), b = Vec2(100, 0), c = Vec2(100, 100), d = Vec2(0, 100);

  test('decode collapses doubled points into red anchors; encode restores them', () {
    final stored = [a, b, b, c, d];
    final pts = SliderShape.decode(stored);
    expect([for (final p in pts) p.position], [a, b, c, d]);
    expect([for (final p in pts) p.red], [false, true, false, false]);
    expect(SliderShape.encode(pts), stored);
  });

  test('head / tail duplicates are not anchors and encode once', () {
    final pts = SliderShape.decode([a, a, b, c, c]);
    expect([for (final p in pts) p.red], [false, false, false]);
    expect(SliderShape.encode([const PathPoint(a, red: true), const PathPoint(b), const PathPoint(c, red: true)]),
        [a, b, c]);
  });

  test('autoType follows stable: 2 → linear, 3 → circle, collinear or more → bezier', () {
    List<PathPoint> p(List<Vec2> v) => [for (final x in v) PathPoint(x)];
    expect(SliderShape.autoType(p([a, b])), CurveType.linear);
    expect(SliderShape.autoType(p([a, b, c])), CurveType.perfectCircle);
    expect(SliderShape.autoType(p([a, const Vec2(50, 0), b])), CurveType.bezier);
    expect(SliderShape.autoType(p([a, b, c, d])), CurveType.bezier);
    expect(SliderShape.autoType([const PathPoint(a), const PathPoint(b, red: true), const PathPoint(c)]),
        CurveType.bezier);
  });

  test('fullLength measures the untrimmed path', () {
    expect(SliderShape.fullLength(CurveType.linear, [a, b, c]), closeTo(200, 1e-9));
  });

  test('resizeEdges keeps head edges and the tail, fills new repeats', () {
    expect(SliderShape.resizeEdges([1, 2, 3], 4, 0), [1, 2, 0, 0, 3]);
    expect(SliderShape.resizeEdges([1, 2, 3, 4], 1, 0), [1, 4]);
    expect(SliderShape.resizeEdges<int>(null, 3, 0), isNull);
  });

  test('snapSliderLength rounds down to whole beat snaps (at least one)', () {
    // 120 BPM, SV 1, SM 1.4: one beat = 140 px, 1/4 = 35 px.
    final timing = TimingInfo([TimingPoint.red(time: 0, bpm: 120)]);
    expect(timing.sliderLengthStep(0, 1.4, 4), closeTo(35, 1e-9));
    expect(timing.snapSliderLength(139.9, 0, 1.4, 4), closeTo(105, 1e-9));
    expect(timing.snapSliderLength(140, 0, 1.4, 4), closeTo(140, 1e-9));
    expect(timing.snapSliderLength(10, 0, 1.4, 4), closeTo(35, 1e-9));
    expect(timing.snapSliderLength(139.9, 0, 1.4, 1), closeTo(140, 1e-9)); // min one step
  });
}
