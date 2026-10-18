import 'dart:math' as math;

import '../model/hit_object.dart';

/// osu!standard difficulty formulas (stable values).
abstract final class OsuRules {
  static const playfieldWidth = 512.0;
  static const playfieldHeight = 384.0;

  /// Hit circle radius in osu!pixels.
  static double circleRadius(double cs) => 54.4 - 4.48 * cs;

  /// The gameplay screen in osu!pixels (640x480 around the playfield on
  /// 4:3), as lazer's verifier approximates it (`CheckOffscreenObjects`):
  /// an object is offscreen when its circle crosses this box.
  static const screenLeft = -67.0, screenTop = -60.0, screenRight = 579.0, screenBottom = 428.0;

  /// Where a slider's head / path points may go at [cs]: anywhere its circle
  /// stays on screen (the osu! rule), so smaller circles may leave the
  /// playfield further. Whole pixels (rounded inwards), never narrower than
  /// the playfield (circles' bounds).
  static ({double left, double top, double right, double bottom}) sliderBounds(double cs) {
    final r = circleRadius(cs);
    return (
      left: math.min(0.0, (screenLeft + r).ceilToDouble()),
      top: math.min(0.0, (screenTop + r).ceilToDouble()),
      right: math.max(playfieldWidth, (screenRight - r).floorToDouble()),
      bottom: math.max(playfieldHeight, (screenBottom - r).floorToDouble()),
    );
  }

  /// Time before the hit time at which the object appears (ms).
  static double preempt(double ar) {
    if (ar < 5) return 1200 + 600 * (5 - ar) / 5;
    if (ar > 5) return 1200 - 750 * (ar - 5) / 5;
    return 1200;
  }

  /// Fade-in duration (ms), starting at `time - preempt`. lazer's value
  /// (400ms, shorter only when the preempt drops below 450ms), not stable's
  /// AR-scaled one, to match its editor.
  static double fadeIn(double ar) => 400 * math.min(1, preempt(ar) / 450);

  /// Hit window for a 300 (ms, ±).
  static double hitWindow300(double od) => 80 - 6 * od;
}

/// Combo number and colour slot of a hit object.
class ComboInfo {
  /// 1-based number shown on the object (spinners carry one too, unshown).
  final int number;

  /// Index into the combo colour list (`Combo1`, `Combo2`, … in file order),
  /// taken modulo its length. The first combo is 1, i.e. `Combo2`: stable
  /// starts there and `Combo1` comes last in the cycle.
  final int colourIndex;

  const ComboInfo(this.number, this.colourIndex);
}

/// Computes combo numbers / colour indices for objects sorted by time, as
/// osu!stable does (mirrored from lazer's legacy conversion,
/// `ConvertHitObjectParser` + `OsuHitObject.UpdateComboInformation`):
/// * the first object, an object with the new-combo bit and the object after
///   a spinner start a new combo;
/// * spinners never start a combo (their new-combo bit is ignored): they
///   continue the current one;
/// * a new combo advances the colour by one, plus the object's colour skip
///   ("colour hax") only when the object itself has the new-combo bit;
/// * the first non-spinner object after a break ([breakEnds], sorted) starts
///   a new combo too (lazer's `ensureNewComboAfterBreaks`; display only, the
///   bit is not written).
List<ComboInfo> computeCombos(List<HitObject> objects, {List<double> breakEnds = const []}) {
  final out = <ComboInfo>[];
  var number = 0;
  var colour = 0;
  var nextBreak = 0;
  HitObject? prev;
  for (final h in objects) {
    final isSpinner = h is Spinner;
    var afterBreak = false;
    while (nextBreak < breakEnds.length && h.time >= breakEnds[nextBreak]) {
      afterBreak = true;
      nextBreak++;
    }
    final nc = !isSpinner && (prev == null || prev is Spinner || h.newCombo || afterBreak);
    if (nc) {
      number = 1;
      colour += 1 + (h.newCombo ? h.comboSkip : 0);
    } else {
      number = prev == null ? 1 : number + 1;
    }
    out.add(ComboInfo(number, colour));
    prev = h;
  }
  return out;
}
