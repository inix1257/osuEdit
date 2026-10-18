import '../math/vec2.dart';
import '../model/hit_object.dart';

/// osu!standard stacking (the beatmap version ≥ 6 algorithm used by stable
/// and lazer): objects placed on (almost) the same spot within
/// `preempt × StackLeniency` of each other are drawn shifted up-left so they
/// stay readable.
///
/// Returns the stack height of each object in [objects] (sorted by time).
/// Heights are display-only: positions in the file never change. Positive
/// heights move an object up-left, negative ones (objects stacked onto a
/// slider tail) down-right — see [stackOffset].
///
/// [endTime] and [endPosition] supply the slider data this layer can't
/// compute alone (the end position honours repeats).
List<int> computeStackHeights(
  List<HitObject> objects, {
  required double preempt,
  required double stackLeniency,
  required double Function(HitObject h) endTime,
  required Vec2 Function(SliderObject s) endPosition,
}) {
  const stackDistance = 3.0;
  final n = objects.length;
  final heights = List<int>.filled(n, 0);
  final threshold = preempt * stackLeniency;

  Vec2 endPos(HitObject h) => h is SliderObject ? endPosition(h) : h.position;

  for (var i = n - 1; i > 0; i--) {
    var objI = i;
    if (heights[i] != 0 || objects[i] is Spinner) continue;

    if (objects[i] is SliderObject) {
      // A slider only stacks onto earlier objects ending at its head.
      for (var k = i - 1; k >= 0; k--) {
        final objN = objects[k];
        if (objN is Spinner) continue;
        if (objects[objI].time - objN.time > threshold) break;
        if (endPos(objN).distanceTo(objects[objI].position) < stackDistance) {
          heights[k] = heights[objI] + 1;
          objI = k;
        }
      }
      continue;
    }

    for (var k = i - 1; k >= 0; k--) {
      final objN = objects[k];
      if (objN is Spinner) continue;
      if (objects[objI].time - endTime(objN) > threshold) break;

      // Objects stacked onto a slider's end are pushed the other way, so
      // they don't cover the slider's head.
      if (objN is SliderObject && endPosition(objN).distanceTo(objects[objI].position) < stackDistance) {
        final offset = heights[objI] - heights[k] + 1;
        final tail = endPosition(objN);
        for (var j = k + 1; j <= i; j++) {
          if (tail.distanceTo(objects[j].position) < stackDistance) heights[j] -= offset;
        }
        break;
      }

      if (objN.position.distanceTo(objects[objI].position) < stackDistance) {
        heights[k] = heights[objI] + 1;
        objI = k;
      }
    }
  }
  return heights;
}

/// Display offset (osu!pixels) of an object with stack [height] for a circle
/// of [radius]: `-height × radius / 10` on both axes.
Vec2 stackOffset(int height, double radius) {
  final d = -height * radius / 10;
  return Vec2(d, d);
}
