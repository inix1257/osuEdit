import 'dart:math' as math;

/// Immutable 2D vector in osu!pixel space (playfield is 512x384).
///
/// The core layer deliberately avoids `dart:ui` (Offset) so it can be tested
/// and reused without Flutter.
class Vec2 {
  final double x;
  final double y;

  const Vec2(this.x, this.y);

  static const zero = Vec2(0, 0);

  Vec2 operator +(Vec2 o) => Vec2(x + o.x, y + o.y);
  Vec2 operator -(Vec2 o) => Vec2(x - o.x, y - o.y);
  Vec2 operator *(double s) => Vec2(x * s, y * s);
  Vec2 operator /(double s) => Vec2(x / s, y / s);
  Vec2 operator -() => Vec2(-x, -y);

  double dot(Vec2 o) => x * o.x + y * o.y;
  double get lengthSquared => x * x + y * y;
  double get length => math.sqrt(lengthSquared);

  double distanceTo(Vec2 o) => (this - o).length;
  double distanceSquaredTo(Vec2 o) => (this - o).lengthSquared;

  Vec2 normalized() {
    final len = length;
    return len == 0 ? Vec2.zero : this / len;
  }

  /// Rounded to whole osu!pixels (the file stores integer positions).
  Vec2 roundToInt() => Vec2(x.roundToDouble(), y.roundToDouble());

  static Vec2 lerp(Vec2 a, Vec2 b, double t) =>
      Vec2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);

  @override
  bool operator ==(Object other) =>
      other is Vec2 && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Vec2($x, $y)';
}
