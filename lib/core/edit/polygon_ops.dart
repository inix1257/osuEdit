import 'dart:math' as math;

import '../math/vec2.dart';
import '../model/hit_object.dart';
import '../rules/osu_rules.dart';
import '../timing/timing_info.dart';

/// osu!stable's "Create polygon circles" (lazer's `PolygonGenerationPopover`):
/// circles on the corners of a regular polygon around the playfield centre,
/// one per beat-divisor step from a start time.
abstract final class PolygonOps {
  static const minVertices = 3;
  static const maxVertices = 10;
  static const maxRepeats = 10;
  static const centre = Vec2(OsuRules.playfieldWidth / 2, OsuRules.playfieldHeight / 2);

  /// The circles: [vertices] corners, gone round [repeats] times
  /// (vertices × repeats circles), starting at [startTime] and stepping by
  /// one [divisor] tick (each time snapped, like lazer). Neighbouring
  /// corners are [distance] × the distance snap of one tick apart (slider
  /// velocity at [startTime] × [distanceSpacing]); [angleDegrees] turns the
  /// polygon (clockwise on screen). The first circle starts a new combo.
  static List<HitCircle> circles({
    required TimingInfo timing,
    required double sliderMultiplier,
    required double distanceSpacing,
    required double startTime,
    required int divisor,
    required int vertices,
    int repeats = 1,
    double distance = 1,
    double angleDegrees = 0,
  }) {
    vertices = vertices.clamp(minVertices, maxVertices);
    repeats = repeats.clamp(1, maxRepeats);
    final step = timing.beatLengthAt(startTime) / divisor;
    final side = distance * distanceSpacing * timing.sliderVelocityPxPerMs(startTime, sliderMultiplier) * step;
    final radius = side / (2 * math.sin(math.pi / vertices));
    final offset = angleDegrees * math.pi / 180;
    final out = <HitCircle>[];
    var t = startTime;
    for (var i = 1; i <= vertices * repeats; i++) {
      final a = offset + i * 2 * math.pi / vertices;
      final p = centre + Vec2(radius * math.cos(a), radius * math.sin(a));
      out.add(HitCircle(position: p.roundToInt(), time: t.roundToDouble(), newCombo: i == 1));
      t = timing.snap(t + step, divisor);
    }
    return out;
  }

  /// Whether every circle lies on the playfield.
  static bool fits(List<HitCircle> circles) => circles.every((c) =>
      c.position.x >= 0 &&
      c.position.y >= 0 &&
      c.position.x <= OsuRules.playfieldWidth &&
      c.position.y <= OsuRules.playfieldHeight);
}

/// stable's "Reset samples" / "Reset combo colours".
abstract final class ResetOps {
  /// [h] without additions or custom sample sets / index / volume / file
  /// (slider edges too). Null when it has none.
  static HitObject? withoutSamples(HitObject h) {
    final clean = h.hitSound == 0 && h.sample.isDefault;
    if (h is SliderObject) {
      final edgesClean = (h.edgeSounds?.every((s) => s == 0) ?? true) &&
          (h.edgeSets?.every((e) => e.normalSet == 0 && e.additionSet == 0) ?? true);
      if (clean && edgesClean) return null;
      return h.copyWith(
        hitSound: 0,
        sample: HitSample.empty,
        edgeSounds: h.edgeSounds == null ? null : List.filled(h.edgeSounds!.length, 0),
        edgeSets: h.edgeSets == null ? null : List.filled(h.edgeSets!.length, const EdgeSet(0, 0)),
      );
    }
    return clean ? null : h.copyWithBase(hitSound: 0, sample: HitSample.empty);
  }

  /// [h] without a combo colour skip ("colour hax"); null when it has none.
  static HitObject? withoutColourSkip(HitObject h) => h.comboSkip == 0 ? null : h.copyWithBase(comboSkip: 0);
}
