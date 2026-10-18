import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

void main() {
  // Sliders last 1000ms in these tests.
  double endTime(HitObject h) => h is SliderObject ? h.time + 1000 : h.time;

  HitCircle circle(double t) => HitCircle(time: t, position: const Vec2(100, 100));
  SliderObject slider(double t) => SliderObject(
        time: t,
        position: const Vec2(100, 100),
        curveType: CurveType.linear,
        controlPoints: const [Vec2(200, 100)],
        slides: 1,
        length: 100,
      );

  test('clean pattern has no issues', () {
    final objs = [circle(0), circle(500), slider(1000), circle(2500)];
    expect(findOverlaps(objs, endTime: endTime), isEmpty);
  });

  test('objects at the same time are flagged', () {
    final objs = [circle(0), circle(500), circle(500)];
    final issues = findOverlaps(objs, endTime: endTime);
    expect(issues.map((i) => i.time), [500]);
  });

  test('object starting exactly when a slider ends is flagged', () {
    final objs = [slider(0), circle(1000)];
    expect(findOverlaps(objs, endTime: endTime).map((i) => i.time), [1000]);
  });

  test('object inside a slider and slider/slider overlap are flagged', () {
    final objs = [slider(0), circle(400), slider(800), circle(1000)];
    final issues = findOverlaps(objs, endTime: endTime);
    // circle(1000) clashes with both sliders (one ends there, one runs).
    expect(issues.map((i) => i.time), [400, 800, 1000, 1000]);
  });

  group('unsnapped', () {
    // 120 BPM: 500ms beats.
    final timing = TimingInfo([const TimingPoint(time: 0, beatLength: 500, uninherited: true)]);

    test('objects on any common grid are fine', () {
      final objs = [circle(0), circle(250), circle(500 / 3 * 5), circle(31.25 * 3), circle(1001)];
      expect(findUnsnapped(objs, timing, endTime: endTime), isEmpty);
    });

    test('off-grid objects are flagged', () {
      final objs = [circle(0), circle(1010), circle(1500)];
      final issues = findUnsnapped(objs, timing, endTime: endTime);
      expect(issues.map((i) => i.time), [1010]);
      expect(issues.single.kind, PatternIssueKind.unsnapped);
    });
  });
}
