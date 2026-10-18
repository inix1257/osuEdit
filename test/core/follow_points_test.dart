import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

void main() {
  HitCircle circle(double x, double t, {bool nc = false}) =>
      HitCircle(position: Vec2(x, 100), time: t, newCombo: nc);

  List<FollowConnection> connect(List<HitObject> objs, {Set<HitObject> newCombos = const {}}) =>
      FollowPoints.connect(
        objs,
        isNewCombo: newCombos.contains,
        endTime: (h) => h.endTimeIfKnown,
        endPosition: (h) => h.position,
        position: (h) => h.position,
      );

  test('joins consecutive objects of a combo, not across new combos or spinners', () {
    final a = circle(0, 0), b = circle(200, 500), c = circle(400, 1000);
    final sp = Spinner(position: Spinner.center, time: 1500, endTime: 2000);
    final d = circle(100, 2500);
    final cs = connect([a, b, c, sp, d], newCombos: {c});
    expect(cs, hasLength(1));
    expect(cs.single.from, const Vec2(0, 100));
    expect(cs.single.to, const Vec2(200, 100));
    expect(cs.single.startTime, 0);
    expect(cs.single.endTime, 500);
  });

  test('preempt is 800ms, shorter only below a 450ms object preempt', () {
    expect(FollowPoints.preempt(1200), 800);
    expect(FollowPoints.preempt(450), 800);
    expect(FollowPoints.preempt(300), closeTo(533.3, 0.1));
  });

  group('points', () {
    // 200 px, 1000ms: points at d = 48, 80, 112, 144 (< 200 - 32).
    const c = FollowConnection(Vec2(0, 0), 1000, Vec2(200, 0), 2000);

    List<(Vec2, double, double)> at(double t) {
      final out = <(Vec2, double, double)>[];
      FollowPoints.pointsAt(c, t, 800, 400, (p, angle, alpha, scale) {
        expect(angle, 0);
        out.add((p, alpha, scale));
      });
      return out;
    }

    test('none before the first fades in, none after the last fades out', () {
      // First point (f = 0.24) is in place at 1240, fades in from 440.
      expect(at(430), isEmpty);
      expect(at(2400), isEmpty); // last (f = 0.72) fades out 1720..2120
    });

    test('a point at alpha 0 (the very start of its fade-in) is skipped', () {
      expect(at(440), isEmpty);
    });

    test('fully in at its time; fading out after it', () {
      final pts = at(1240);
      expect(pts, hasLength(4));
      final (p, alpha, scale) = pts.first;
      expect(p.x, closeTo(48, 1e-9));
      expect(alpha, 1);
      expect(scale, 1);
      // Half way through its fade-out.
      final later = at(1440).first;
      expect(later.$2, closeTo(0.5, 1e-9));
    });

    test('mid fade-in: eased position and scale', () {
      final (p, alpha, scale) = at(640).first; // 200ms into a 400ms fade
      expect(alpha, closeTo(0.5, 1e-9));
      // Easing.Out at 0.5 = 0.75: 48 - 20 + 20 * 0.75 = 43.
      expect(p.x, closeTo(43, 1e-9));
      expect(scale, closeTo(1.125, 1e-9));
    });

    test('a short connection has no points', () {
      const short = FollowConnection(Vec2(0, 0), 0, Vec2(70, 0), 100);
      var n = 0;
      FollowPoints.pointsAt(short, 50, 800, 400, (_, _, _, _) => n++);
      expect(n, 0);
    });
  });
}
