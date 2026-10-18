import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

void main() {
  HitCircle circle(double t, double x, double y) => HitCircle(position: Vec2(x, y), time: t);

  SliderObject slider(double t, double x, double y, double toX) => SliderObject(
        position: Vec2(x, y),
        time: t,
        curveType: CurveType.linear,
        controlPoints: [Vec2(toX, y)],
        length: (toX - x).abs(),
      );

  // A slider lasts 200 ms in these tests; its end is its tail.
  List<int> stack(List<HitObject> objs, {double preempt = 1000, double leniency = 0.7}) =>
      computeStackHeights(
        objs,
        preempt: preempt,
        stackLeniency: leniency,
        endTime: (h) => h is SliderObject ? h.time + 200 : h.time,
        endPosition: (s) => SliderPath.of(s).tail,
      );

  test('circles on the same spot stack, earliest highest', () {
    expect(stack([circle(0, 100, 100), circle(100, 100, 100), circle(200, 100, 100)]), [2, 1, 0]);
  });

  test('nearly the same spot (< 3 px) still stacks; 3 px does not', () {
    expect(stack([circle(0, 100, 100), circle(100, 102, 100)]), [1, 0]);
    expect(stack([circle(0, 100, 100), circle(100, 103, 100)]), [0, 0]);
  });

  test('objects further apart in time than preempt × leniency do not stack', () {
    expect(stack([circle(0, 100, 100), circle(700, 100, 100)]), [1, 0]);
    expect(stack([circle(0, 100, 100), circle(701, 100, 100)]), [0, 0]);
    expect(stack([circle(0, 100, 100), circle(300, 100, 100)], leniency: 0.2), [0, 0]);
  });

  test('a chain is followed even when the first and last are far apart in time', () {
    final objs = [for (var i = 0; i < 5; i++) circle(i * 600.0, 50, 50)];
    expect(stack(objs), [4, 3, 2, 1, 0]);
  });

  test('circles on a slider tail are pushed down-right', () {
    expect(stack([slider(0, 100, 100, 200), circle(300, 200, 100), circle(400, 200, 100)]), [0, -1, -2]);
  });

  test('a slider starting on the previous object stacks it', () {
    expect(stack([circle(0, 100, 100), slider(100, 100, 100, 200)]), [1, 0]);
  });

  test('spinners neither stack nor break a chain', () {
    final sp = Spinner(position: Spinner.center, time: 50, endTime: 60);
    expect(stack([circle(0, 100, 100), sp, circle(100, 100, 100)]), [1, 0, 0]);
  });

  test('stack offset moves up-left by radius / 10 per level', () {
    expect(stackOffset(2, 30), const Vec2(-6, -6));
    expect(stackOffset(-1, 30), const Vec2(3, 3));
  });
}
