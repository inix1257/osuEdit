import 'dart:math' as math;

import '../storyboard/easing.dart';

/// How osu!lazer's editor animates osu!standard objects over time, so the
/// playfield shows them appearing and disappearing the same way, with
/// lazer's classic skin (the stable look: `Legacy*` pieces).
///
/// Two modes, like lazer's "Show hit markers" setting:
/// * hit markers (lazer's default, `hitAnimations: false`): circles and
///   slider heads/repeats/tails are kept un-hit and fade out white over
///   700 ms after their time (`SuppressHitAnimations`);
/// * hit animations: they play the classic skin's hit animation
///   (`LegacyMainCirclePiece`: circle and overlay grow to 1.4x while fading
///   out over 240 ms, the number fades in 60 ms; repeats also fade out and
///   their arrow grows, `DrawableSliderRepeat` / `LegacyReverseArrow`), and
///   the whole slider fades out over 240 ms after its end.
/// Either way the editor's autoplay drives slider ticks, ball, follow circle
/// and spinners. Sources: lazer `DrawableHitCircle`, `DrawableSlider*`,
/// `DrawableSpinner`, `DrawableOsuHitObject` (dimming, repeat fade-in),
/// `SnakingSliderBody`, `SliderTick` / `SliderEndCircle` (preempts) and the
/// classic skin pieces (`LegacyMainCirclePiece`, `LegacyReverseArrow`,
/// `LegacySliderBall`, `LegacyFollowCircle`).
///
/// Times are in ms; alpha and scale are multipliers (scale relative to the
/// object's normal size). Fade-in durations come from `OsuRules.fadeIn`.
abstract final class ObjectVisuals {
  /// Circles and slider heads/repeats/tails turn white at their time and fade
  /// out linearly over this long.
  static const hitFadeOut = 700.0;

  /// Slider bodies fade out over this long after the slider ends.
  static const sliderBodyFadeOut = 240.0;

  /// Spinners fade out over this long after they end.
  static const spinnerFadeOut = 240.0;

  /// The longest anything stays on screen after its object's end time.
  static const lingerAfterEnd = hitFadeOut;

  /// Classic skin hit animation of circles and slider ends: fade out while
  /// growing to [hitScale] over this long (`legacy_fade_duration`).
  static const hitAnim = 240.0;
  static const hitScale = 1.4;

  /// The number of a hit circle fades out over this long (skins newer than
  /// version 1.0, like the default one).
  static const hitNumberFade = hitAnim / 4;

  /// A repeat arrow pulses (1.3x back to 1x) every this long.
  static const repeatPulse = 300.0;

  static const approachStartScale = 4.0;
  static const approachMaxAlpha = 0.9;

  /// The approach circle fades out over this long from the hit time.
  static const approachFadeOut = 50.0;

  /// Objects are tinted to this brightness until [_undimLead] before their
  /// time, then brighten over [_undimDuration] (lazer `MISS_WINDOW`).
  static const dimBrightness = 195 / 255;
  static const _undimLead = 400.0;
  static const _undimDuration = 100.0;

  /// Slider tick fade in / hit animation length.
  static const tickAnim = 150.0;


  static const _outQuad = 4;
  static const _inQuad = 3;
  static const _outQuint = 13;
  static const _outElasticHalf = 26;

  static double _ease(int easing, double p) => StoryboardEasing.apply(easing, p);

  /// Linear progress of a transform starting at [from] lasting [duration]
  /// (instant when the duration is 0).
  static double _lin(double t, double from, double duration) {
    if (duration <= 0) return t >= from ? 1 : 0;
    return ((t - from) / duration).clamp(0.0, 1.0);
  }

  /// Whether an object from [start] to [end] is on screen at [t].
  static bool isAlive(double t, double start, double end, double preempt, {bool spinner = false}) =>
      t >= start - preempt && t <= end + (spinner ? spinnerFadeOut : hitFadeOut);

  /// Colour multiplier of not-yet-close objects ([time] is the object's
  /// start; slider bodies, repeats and tails use the slider's).
  static double brightness(double t, double time) =>
      dimBrightness + (1 - dimBrightness) * _lin(t, time - _undimLead, _undimDuration);

  /// Hit circle / slider head opacity: fades in from `time - preempt`, then
  /// fades out linearly from [time] (700 ms white with hit markers, the
  /// 240 ms classic hit animation otherwise).
  static double circleAlpha(double t, double time, double preempt, double fadeIn, {bool hitAnimations = false}) {
    if (t < time) return _lin(t, time - preempt, fadeIn);
    return 1 - _lin(t, time, hitAnimations ? hitAnim : hitFadeOut);
  }

  /// Size multiplier of a circle / slider end at [t]: grows to [hitScale]
  /// after [time] in the hit animation, 1 otherwise.
  static double circleScale(double t, double time, {bool hitAnimations = false}) {
    if (!hitAnimations || t < time) return 1;
    return 1 + (hitScale - 1) * _ease(_outQuad, _lin(t, time, hitAnim));
  }

  /// A circle's number: like the circle, except that the hit animation
  /// fades it out over [hitNumberFade].
  static double numberAlpha(double t, double time, double preempt, double fadeIn, {bool hitAnimations = false}) {
    if (!hitAnimations || t < time) return circleAlpha(t, time, preempt, fadeIn);
    return 1 - _lin(t, time, hitNumberFade);
  }

  /// Whether the circle / slider end hit at [time] is drawn white at [t]
  /// (hit markers: lazer sets its accent colour to white).
  static bool shownWhite(double t, double time, {bool hitAnimations = false}) => !hitAnimations && t >= time;

  /// Approach circle scale: 4× shrinking linearly to 1× at [time].
  static double approachScale(double t, double time, double preempt) =>
      approachStartScale - (approachStartScale - 1) * _lin(t, time - preempt, preempt);

  /// Approach circle opacity: up to 0.9 over `min(2 × fadeIn, preempt)`,
  /// gone [approachFadeOut] after [time].
  /// With hit animations it goes as the circle is hit.
  static double approachAlpha(double t, double time, double preempt, double fadeIn, {bool hitAnimations = false}) {
    final duration = math.min(fadeIn * 2, preempt);
    if (t < time) return approachMaxAlpha * _lin(t, time - preempt, duration);
    if (hitAnimations) return 0;
    final atHit = approachMaxAlpha * _lin(time, time - preempt, duration);
    return atHit * (1 - _lin(t, time, approachFadeOut));
  }

  /// Hit markers only (lazer `HitCircleOverlapMarker`, editor blueprint of
  /// circles and slider heads): from [time] a combo-coloured ring
  /// ([hitMarkerThickness] of the radius) takes over from the approach
  /// circle, growing to 1.1x over 350 ms (OutQuint) while fading from 0.9 to
  /// 0 over 700 ms (In). 0 before [time] and with hit animations.
  static double hitMarkerAlpha(double t, double time, {bool hitAnimations = false}) {
    if (hitAnimations || t < time) return 0;
    return approachMaxAlpha * (1 - _ease(_inQuad, _lin(t, time, hitFadeOut)));
  }

  static double hitMarkerScale(double t, double time) =>
      1 + 0.1 * _ease(_outQuint, _lin(t, time, hitFadeOut / 2));

  /// Ring border: 4 of the 128 object units.
  static const hitMarkerThickness = 4 / 64;

  /// Fraction of the slider path drawn (snaking in over the first third of
  /// the preempt).
  static double snakeProgress(double t, double start, double preempt) => _lin(t, start - preempt, preempt / 3);

  /// Slider body opacity.
  static double sliderBodyAlpha(double t, double start, double end, double preempt, double fadeIn) {
    if (t <= end) return _lin(t, start - preempt, fadeIn);
    return 1 - _lin(t, end, sliderBodyFadeOut);
  }

  /// With hit animations the whole slider (its end circles too) fades out
  /// over [sliderBodyFadeOut] after it ends; with hit markers only the body
  /// does (the ends fade on their own).
  static double sliderAlpha(double t, double end, {bool hitAnimations = false}) =>
      hitAnimations ? 1 - _lin(t, end, sliderBodyFadeOut) : 1;

  /// Opacity of a slider end circle: the repeat (or tail) ending span
  /// [spanIndex] at [time]. The first one fades in once the body has
  /// snaked in; later ones pop in when the previous one at the same end is
  /// hit, i.e. two spans before their own time.
  /// After its time it fades like a hit circle; with hit animations a
  /// [repeat] also fades out over `min(300, span)`.
  static double endCircleAlpha(double t, int spanIndex, double time, double sliderStart, double span,
      double preempt, double fadeIn, {bool hitAnimations = false, bool repeat = false}) {
    if (t >= time) {
      if (!hitAnimations) return 1 - _lin(t, time, hitFadeOut);
      final piece = 1 - _lin(t, time, hitAnim);
      if (!repeat) return piece;
      return piece * (1 - _ease(_outQuad, _lin(t, time, math.min(300, span))));
    }
    if (spanIndex == 0) return _lin(t, sliderStart - preempt + preempt / 3, fadeIn);
    return _lin(t, time - 2 * span, 0);
  }

  /// Opacity of a repeat's arrow: hidden once the repeat is hit with hit
  /// markers; with hit animations it fades out with the repeat.
  static double repeatArrowAlpha(double t, int spanIndex, double time, double sliderStart, double span,
      double preempt, {bool hitAnimations = false}) {
    if (t >= time) {
      if (!hitAnimations) return 0;
      return 1 - _ease(_outQuad, _lin(t, time, math.min(300, span)));
    }
    if (spanIndex == 0) return _lin(t, sliderStart - preempt + preempt / 3, 150);
    return _lin(t, time - 2 * span, math.min(span, 150));
  }

  /// Size multiplier of a repeat's arrow (`LegacyReverseArrow`): pulses
  /// from 1.3x back to 1x every [repeatPulse] from when it appears; once
  /// hit (hit animations) grows to 1.4x over `min(300, span)`.
  static double repeatArrowScale(double t, int spanIndex, double time, double sliderStart, double span,
      double preempt, {bool hitAnimations = false}) {
    if (t >= time) {
      if (!hitAnimations) return 1;
      return 1 + 0.4 * _ease(_outQuad, _lin(t, time, math.min(300, span)));
    }
    final appear = spanIndex == 0 ? sliderStart - preempt : time - 2 * span;
    final loop = (t - appear) % repeatPulse;
    return 1.3 - 0.3 * _ease(_outQuad, loop / repeatPulse);
  }

  /// How long before its time a slider tick appears.
  static double tickPreempt(double tickTime, double spanStart, int spanIndex, double preempt) =>
      (tickTime - spanStart) / 2 + (spanIndex > 0 ? 200 : preempt * 0.66);

  /// Slider tick (alpha, scale): fades in with an elastic grow from 0.5×,
  /// and on its time fades out while growing to 1.5×. Null when not shown.
  static (double, double)? tick(double t, double tickTime, double tickPreempt) {
    final appear = tickTime - tickPreempt;
    if (t < appear || t > tickTime + tickAnim) return null;
    double alphaAt(double at) => _lin(at, appear, tickAnim);
    double scaleAt(double at) => 0.5 + 0.5 * _ease(_outElasticHalf, _lin(at, appear, tickAnim * 4));
    if (t < tickTime) return (alphaAt(t), scaleAt(t));
    final p = _lin(t, tickTime, tickAnim);
    final s = scaleAt(tickTime);
    return (alphaAt(tickTime) * (1 - _ease(_outQuint, p)), s + s * 0.5 * _ease(_outQuad, p));
  }

  /// Slider ball opacity: the classic ball shows from the slider's start
  /// to its end, without fading (`LegacySliderBall`).
  static double ballAlpha(double t, double start, double end) => t >= start && t <= end ? 1 : 0;

  /// Follow circle (scale relative to the circle, alpha), or null when not
  /// shown (`LegacyFollowCircle`): from the slider's start it grows from 1x
  /// to 2x over 180 ms while fading in over 60 ms; every tick / repeat
  /// ([lastPulse] = the latest one at or before `min(t, end)`) bumps it to
  /// 2.2x easing back to 2x over 200 ms; at the end it grows to 1.6x and
  /// fades out over 200 ms.
  static (double, double)? followCircle(double t, double start, double end, double? lastPulse) {
    if (t < start || t > end + 200) return null;
    final length = end - start;
    final grow = math.min(180.0, length), appear = math.min(60.0, length);
    double pressed(double at) => 1 + _ease(_outQuad, _lin(at, start, grow));
    double scaleAt(double at) {
      final pulse = lastPulse;
      if (pulse != null && at >= pulse && at < pulse + 200 && pressed(pulse) >= 2) {
        return 2.2 - 0.2 * _lin(at, pulse, 200);
      }
      return pressed(at);
    }

    final alpha = _lin(math.min(t, end), start, appear);
    if (t <= end) return (scaleAt(t), alpha);
    final from = scaleAt(end);
    final p = _lin(t, end, 200);
    final a = alpha * (1 - _ease(_inQuad, p));
    if (a <= 0) return null;
    return (from + (1.6 - from) * _ease(_outQuad, p), a);
  }

  /// Spinner (scale, alpha): grows in two steps (to 0.2× in the second half
  /// of the preempt, to 1× over half a preempt from its start), then on its
  /// end grows to 1.2× while fading out. It fades in over the `fadeIn` that
  /// ends at its start (lazer `LegacyNewStyleSpinner`: `FadeInFromZero(TimeFadeIn)`
  /// at `StartTime - TimeFadeIn`).
  static (double, double) spinner(double t, double start, double end, double preempt, double fadeIn) {
    double grow(double at) {
      if (at < start) return 0.2 * _ease(_outQuint, _lin(at, start - preempt / 2, preempt / 4));
      return 0.2 + 0.8 * _ease(_outQuint, _lin(at, start, preempt / 2));
    }

    if (t <= end) return (grow(t), _lin(t, start - fadeIn, fadeIn));
    final s = grow(end);
    return (s + (1.2 - s) * _ease(_outQuad, _lin(t, end, 320)), 1 - _lin(t, end, spinnerFadeOut));
  }
}
