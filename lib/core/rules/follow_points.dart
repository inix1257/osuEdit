import 'dart:math' as math;

import '../math/vec2.dart';
import '../model/hit_object.dart';
import 'osu_rules.dart';

/// The follow points between two consecutive objects of a combo: from
/// where [from] the earlier one ends ([startTime], its end time) to where
/// the next one starts ([to] at [endTime]). Positions are as displayed
/// (stacked).
class FollowConnection {
  final Vec2 from;
  final double startTime;
  final Vec2 to;
  final double endTime;

  const FollowConnection(this.from, this.startTime, this.to, this.endTime);
}

/// osu!lazer's follow points (`FollowPointConnection` / `FollowPointRenderer`):
/// * objects are joined when the next one is in the same combo and neither
///   is a spinner;
/// * a point every [spacing] osu!pixels, from 1.5 × spacing after the start
///   to at least one spacing before the end;
/// * a point at fraction f of the way is at its place at
///   `startTime + f × (endTime − startTime)`, after fading in over the next
///   object's fade-in (moving the last 10 % of the way and shrinking from
///   1.5×, eased out) starting a "preempt" earlier (800ms, less only for
///   preempts under 450ms); then it fades out over the same fade-in.
abstract final class FollowPoints {
  static const spacing = 32;
  static const _preemptBase = 800.0;
  static const _preemptMin = 450.0;

  /// The follow point preempt for objects with [objectPreempt].
  static double preempt(double objectPreempt) => _preemptBase * math.min(1, objectPreempt / _preemptMin);

  /// The connections of [objects] (sorted by time), in order. [isNewCombo]
  /// tells whether an object starts a combo (as displayed: after spinners
  /// and breaks too); [endTime] / [endPosition] / [position] give displayed
  /// times and stacked positions.
  static List<FollowConnection> connect(
    List<HitObject> objects, {
    required bool Function(HitObject) isNewCombo,
    required double Function(HitObject) endTime,
    required Vec2 Function(HitObject) endPosition,
    required Vec2 Function(HitObject) position,
  }) {
    final out = <FollowConnection>[];
    for (var i = 0; i + 1 < objects.length; i++) {
      final a = objects[i], b = objects[i + 1];
      if (a is Spinner || b is Spinner || a is HoldNote || b is HoldNote || isNewCombo(b)) continue;
      out.add(FollowConnection(endPosition(a), endTime(a), position(b), b.time));
    }
    return out;
  }

  /// When [c]'s points can be visible: from the first one fading in until
  /// the last one has faded out (a superset is fine for culling).
  static (double, double) lifetime(FollowConnection c, double preempt, double fadeIn) =>
      (math.min(c.startTime, c.endTime) - preempt, math.max(c.startTime, c.endTime) + fadeIn);

  /// Calls [visit] for each point of [c] visible at [t]: its position, the
  /// direction it points in (radians), its alpha (0..1] and scale (1 = its
  /// normal size). [preempt] comes from [FollowPoints.preempt], [fadeIn]
  /// is the next object's fade-in.
  static void pointsAt(
    FollowConnection c,
    double t,
    double preempt,
    double fadeIn,
    void Function(Vec2 position, double angle, double alpha, double scale) visit,
  ) {
    final vector = c.to - c.from;
    final distance = vector.length.toInt();
    if (distance <= 0) return;
    final angle = math.atan2(vector.y, vector.x);
    final duration = c.endTime - c.startTime;
    final fade = math.max(1.0, fadeIn);
    for (var d = (spacing * 1.5).toInt(); d < distance - spacing; d += spacing) {
      final fraction = d / distance;
      final fadeOutTime = c.startTime + fraction * duration;
      final fadeInTime = fadeOutTime - preempt;
      if (t < fadeInTime || t >= fadeOutTime + fade) continue;
      final p = ((t - fadeInTime) / fade).clamp(0.0, 1.0);
      final alphaIn = p;
      final alphaOut = t <= fadeOutTime ? 1.0 : 1 - (t - fadeOutTime) / fade;
      final alpha = math.min(alphaIn, alphaOut);
      if (alpha <= 0) continue;
      final eased = 1 - (1 - p) * (1 - p); // osu!framework Easing.Out
      final pos = c.from + vector * (fraction - 0.1 + 0.1 * eased);
      visit(pos, angle, alpha, 1.5 - 0.5 * eased);
    }
  }

  /// Size of a follow point's arrow (half its length) for circles of
  /// radius [circleRadius], in osu!pixels.
  static double arrowSize(double circleRadius) => circleRadius / OsuRules.circleRadius(4) * 7;
}
