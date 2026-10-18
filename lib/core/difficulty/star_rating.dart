import 'dart:math' as math;
import 'dart:typed_data';

import '../geometry/slider_path.dart';
import '../math/vec2.dart';
import '../model/beatmap.dart';
import '../model/hit_object.dart';

/// osu!standard star rating (no mods), ported from osu!lazer's
/// `OsuDifficultyCalculator` (ppy/osu, MIT licence) at commit `6c8220e08e`
/// (2026-10-08), difficulty calculator version [calculatorVersion] — the
/// 2026 Q2 SR & PP release the osu! website shows.
///
/// lazer's beatmap conversion is reproduced where it changes the result:
/// whole-pixel positions before format v128, float CS/AR/OD/stack
/// leniency, integer preempt, floored hit windows, slider velocity with
/// stable's precision-adjusted beat length, slider ticks / repeats / tail
/// (`SliderEventGenerator`) and both stacking algorithms
/// (`OsuBeatmapProcessor`, including the pre-v6 one). Flashlight and the
/// performance-only attributes are left out: they don't affect the
/// no-mod star rating.
abstract final class StarRating {
  /// lazer's `OsuDifficultyCalculator.Version` this port matches. Cached
  /// ratings from another version must be recomputed.
  static const calculatorVersion = 20260706;

  /// The star rating of [beatmap], or null when it isn't an osu!standard
  /// map (taiko/catch/mania have their own calculators).
  static double? of(Beatmap beatmap) => analyse(beatmap)?.stars;

  /// The star rating of [beatmap] with its parts and the strain at each
  /// object (for a difficulty graph), or null when it isn't an osu!standard
  /// map.
  static StarAnalysis? analyse(Beatmap beatmap) {
    if (beatmap.mode != 0) return null;
    final ctx = _Context(beatmap);
    final objects = ctx.convert(beatmap);
    if (objects.length < 2) return StarAnalysis.empty;

    final diffObjects = <_DiffObject>[];
    for (var i = 1; i < objects.length; i++) {
      diffObjects.add(_DiffObject(ctx, objects[i], objects[i - 1], diffObjects, diffObjects.length));
    }

    final aim = _Aim();
    final speed = _Speed();
    final reading = _Reading();
    for (final o in diffObjects) {
      aim.process(o);
      speed.process(o);
      reading.process(o);
    }

    final aimRating = _pow(aim.difficultyValue(), 0.63) * 0.02275;
    final speedRating = math.sqrt(speed.difficultyValue()) * 0.0675;
    final readingRating = math.sqrt(reading.difficultyValue()) * 0.0675;

    // Each object's strains as the skill ratings of a map that hard all the
    // way through (lazer's own conversions: `CountTopWeightedStrains` takes
    // a consistent strain to be the value × (1 − DecayWeight), HarmonicSkill
    // a consistent object difficulty the value / ObjectWeightSum), combined
    // like the star rating.
    final strains = Float64List(diffObjects.length);
    for (var i = 0; i < strains.length; i++) {
      strains[i] = _combine(
        _pow(aim.objectStrains[i] / (1 - _Aim._decayWeight), 0.63) * 0.02275,
        math.sqrt(speed.objectDifficulties[i] * speed.objectWeightSum) * 0.0675,
        math.sqrt(reading.objectDifficulties[i] * reading.objectWeightSum) * 0.0675,
      );
    }

    return StarAnalysis(
      stars: _combine(aimRating, speedRating, readingRating),
      aim: aimRating,
      speed: speedRating,
      reading: readingRating,
      times: Float64List.fromList([for (final o in diffObjects) o.startTime]),
      strains: strains,
    );
  }

  /// lazer `OsuDifficultyCalculator.CreateDifficultyAttributes`: the skill
  /// ratings → performance → star rating.
  static double _combine(double aimRating, double speedRating, double readingRating) {
    final aimPerformance = 4.0 * _pow(aimRating, 3);
    final speedPerformance = 4.0 * _pow(speedRating, 3);
    // SumCognitionDifficulty(reading, flashlight = 0).
    final cognitionPerformance = readingRating > 0 ? 4.0 * _pow(readingRating, 3) : 0.0;
    final basePerformance = _norm(1.1, [aimPerformance, speedPerformance, cognitionPerformance]);
    return _cbrt(basePerformance * 1.12);
  }
}

/// A map's star rating ([StarRating.analyse]) with what it is made of.
class StarAnalysis {
  final double stars;

  /// The skill ratings combined into [stars] (lazer's `AimDifficulty`,
  /// `SpeedDifficulty`, `ReadingDifficulty`).
  final double aim;
  final double speed;
  final double reading;

  /// Per object from the second one on (lazer rates each object against
  /// the one before it): its start time and the difficulty there, in
  /// stars — the star rating the map would have if it were that hard all
  /// the way through (aim, speed and reading strains combined like
  /// [stars]).
  final Float64List times;
  final Float64List strains;

  const StarAnalysis({
    required this.stars,
    required this.aim,
    required this.speed,
    required this.reading,
    required this.times,
    required this.strains,
  });

  static final empty = StarAnalysis(
    stars: 0,
    aim: 0,
    speed: 0,
    reading: 0,
    times: Float64List(0),
    strains: Float64List(0),
  );
}

// -----------------------------------------------------------------------------
// Numeric helpers (DiffUtils)

final _f32 = Float32List(1);

/// Rounds to single precision, for values lazer keeps as `float`.
double _f(double x) {
  _f32[0] = x;
  return _f32[0];
}

double _pow(double x, num e) => switch (e) {
      2 => x * x,
      3 => x * x * x,
      _ => math.pow(x, e).toDouble(),
    };

double _cbrt(double x) => x < 0 ? -math.pow(-x, 1 / 3).toDouble() : math.pow(x, 1 / 3).toDouble();

double _clamp(double x, double lo, double hi) => x < lo ? lo : (x > hi ? hi : x);

double _lerp(double a, double b, double t) => a + (b - a) * t;

double _log10(double x) => math.log(x) / math.ln10;

double _degToRad(double d) => d * math.pi / 180;

double _norm(double p, List<double> values) {
  var sum = 0.0;
  for (final x in values) {
    sum += _pow(x, p);
  }
  return _pow(sum, 1 / p);
}

/// `maxValue / (1 + e^(multiplier × (midpointOffset − x)))`.
double _logistic(double x, double midpointOffset, double multiplier, [double maxValue = 1]) =>
    maxValue / (1 + math.exp(multiplier * (midpointOffset - x)));

/// `1 / (1 + e^exponent)`.
double _logisticExp(double exponent) => 1 / (1 + math.exp(exponent));

double _smoothstep(double x, double start, double end) {
  x = _clamp((x - start) / (end - start), 0, 1);
  return x * x * (3 - 2 * x);
}

double _smootherstep(double x, double start, double end) {
  x = _clamp((x - start) / (end - start), 0, 1);
  return x * x * x * (x * (6 * x - 15) + 10);
}

double _smoothstepBellCurve(double x) {
  x = 0.5 - (x - 0.5).abs();
  x = _clamp(x * 2, 0, 1);
  return x * x * (3 - 2 * x);
}

double _reverseLerp(double x, double start, double end) => _clamp((x - start) / (end - start), 0, 1);

double _millisecondsToBpm(double ms, [int delimiter = 4]) => 60000 / (ms * delimiter);

double _bpmToMilliseconds(double bpm, [int delimiter = 4]) => 60000 / delimiter / bpm;

/// .NET `Math.Round` (banker's rounding).
double _roundHalfEven(double x) {
  final r = x.roundToDouble();
  if ((r - x).abs() == 0.5) return 2 * (x / 2).roundToDouble();
  return r;
}

/// lazer `IBeatmapDifficultyInfo.DifficultyRange(difficulty, min, mid, max)`.
double _difficultyRange(double d, double min, double mid, double max) {
  if (d > 5) return mid + (max - mid) * (d - 5) / 5;
  if (d < 5) return mid + (mid - min) * (d - 5) / 5;
  return mid;
}

// -----------------------------------------------------------------------------
// Beatmap conversion (lazer decoder, OsuBeatmapConverter, Slider, stacking)

const _normalisedRadius = 50.0;
const _normalisedDiameter = 100.0;
const _minDeltaTime = 25.0;
const _assumedSliderRadius = _normalisedRadius * 1.8;
const _tailLeniency = -36.0;
const _stackDistance = 3.0;

enum _Kind { circle, slider, spinner }

enum _NestedKind { head, tick, repeat, tail }

class _Nested {
  final _NestedKind kind;
  final double time;
  final Vec2 position;
  const _Nested(this.kind, this.time, this.position);
}

class _Obj {
  final _Kind kind;
  final double startTime;
  final double endTime;
  final Vec2 position;
  final Vec2 endPosition;
  int stackHeight = 0;

  // Sliders only.
  final SliderPath? path;
  final int repeatCount;
  final double spanDuration;
  final List<_Nested> nested;

  _Obj.circle(this.startTime, this.position)
      : kind = _Kind.circle,
        endTime = startTime,
        endPosition = position,
        path = null,
        repeatCount = 0,
        spanDuration = 0,
        nested = const [];

  _Obj.spinner(this.startTime, this.endTime)
      : kind = _Kind.spinner,
        position = Spinner.center,
        endPosition = Spinner.center,
        path = null,
        repeatCount = 0,
        spanDuration = 0,
        nested = const [];

  _Obj.slider(this.startTime, this.endTime, this.position, this.endPosition, this.path, this.repeatCount,
      this.spanDuration, this.nested)
      : kind = _Kind.slider;

  bool get isSlider => kind == _Kind.slider;
  bool get isSpinner => kind == _Kind.spinner;
}

class _Context {
  late final double circleSize, approachRate, overallDifficulty, stackLeniency;
  late final double scale, radius;

  /// `TimePreempt` (lazer floors it to an integer).
  late final double preempt;

  /// Half the 300 window (`OsuHitWindows`, floored − 0.5).
  late final double great;

  late final List<(double, double)> _redPoints; // (time, beatLength)
  late final List<(double, double, bool)> _svPoints; // (time, sv, generateTicks)

  _Context(Beatmap b) {
    circleSize = _f(b.circleSize);
    approachRate = _f(b.approachRate);
    overallDifficulty = _f(b.overallDifficulty);
    stackLeniency = _f(b.stackLeniency);
    scale = _f(_f(_f(1.0 - _f(0.7) * ((circleSize - 5) / 5)) / 2) * _f(1.00041));
    radius = 64 * scale;
    preempt = _difficultyRange(approachRate, 1800, 1200, 450).truncateToDouble();
    great = _difficultyRange(overallDifficulty, 80, 50, 20).floorToDouble() - 0.5;
    _buildControlPoints(b);
  }

  /// lazer's decoder: points at the same time form one group; the first red
  /// line of a group sets the beat length, a red line resets SV to 1 and a
  /// green line in the same group overrides it (the last one wins).
  void _buildControlPoints(Beatmap b) {
    final points = List.of(b.timingPoints);
    _stableSort(points, (p) => p.time);
    final reds = <(double, double)>[];
    final svs = <(double, double, bool)>[];
    var i = 0;
    while (i < points.length) {
      final t = points[i].time;
      double? red;
      (double, bool)? green;
      var hasRed = false;
      for (; i < points.length && points[i].time == t; i++) {
        final p = points[i];
        if (p.uninherited) {
          if (!hasRed && !p.beatLength.isNaN) red = p.beatLength;
          hasRed = true;
        } else {
          final bl = p.beatLength;
          green = (bl < 0 ? _clamp(100 / -bl, 0.1, 10) : 1.0, !bl.isNaN);
        }
      }
      if (red != null) reds.add((t, _clamp(red, 6, 60000)));
      if (green != null) {
        svs.add((t, green.$1, green.$2));
      } else if (hasRed) {
        svs.add((t, 1, true));
      }
    }
    _redPoints = reds;
    _svPoints = svs;
  }

  double beatLengthAt(double time) {
    if (_redPoints.isEmpty) return 1000;
    final i = _lastAtOrBefore(_redPoints, time, (p) => p.$1);
    return _redPoints[i < 0 ? 0 : i].$2;
  }

  (double, bool) svAt(double time) {
    final i = _lastAtOrBefore(_svPoints, time, (p) => p.$1);
    if (i < 0) return (1, true);
    final p = _svPoints[i];
    return (p.$2, p.$3);
  }

  static int _lastAtOrBefore<T>(List<T> list, double time, double Function(T) timeOf) {
    var lo = 0, hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (timeOf(list[mid]) <= time) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo - 1;
  }

  List<_Obj> convert(Beatmap b) {
    final lazerCoords = b.formatVersion >= 128;
    final sorted = List.of(b.hitObjects);
    _stableSort(sorted, (h) => h.time);
    final out = <_Obj>[];
    for (final h in sorted) {
      switch (h) {
        case HitCircle():
          out.add(_Obj.circle(h.time, _position(h.position, lazerCoords)));
        case Spinner():
          out.add(_Obj.spinner(h.time, math.max(h.time, h.endTime)));
        case SliderObject():
          out.add(_slider(h, b, lazerCoords));
        default:
          break; // mania hold notes can't appear in an osu! map.
      }
    }
    _applyStacking(out, b.formatVersion);
    return out;
  }

  static Vec2 _position(Vec2 p, bool lazerCoords) {
    final x = _clamp(p.x, 0, 512), y = _clamp(p.y, 0, 512);
    return lazerCoords ? Vec2(x, y) : Vec2(x.truncateToDouble(), y.truncateToDouble());
  }

  _Obj _slider(SliderObject s, Beatmap b, bool lazerCoords) {
    final position = _position(s.position, lazerCoords);
    if (!lazerCoords) {
      final cps = [for (final p in s.controlPoints) Vec2(p.x.truncateToDouble(), p.y.truncateToDouble())];
      var changed = position != s.position;
      for (var i = 0; i < cps.length && !changed; i++) {
        changed = cps[i] != s.controlPoints[i];
      }
      if (changed) s = s.copyWith(position: position, controlPoints: cps);
    }
    final path = SliderPath.of(s);
    final distance = path.distance;
    final repeatCount = distance.abs() < 1e-7 ? 0 : math.max(0, s.slides - 1);
    final spanCount = repeatCount + 1;

    final beatLength = beatLengthAt(s.time);
    final (sv, generateTicks) = svAt(s.time);
    final bpmMultiplier = _clamp(_f(100 / sv), 10, 1000) / 100.0;
    final velocity = 100 * b.sliderMultiplier / (beatLength * bpmMultiplier);
    final scoringDistance = velocity * beatLength;
    final tickDistanceMultiplier = b.formatVersion < 8 ? 1 / sv : 1.0;
    var tickDistance =
        generateTicks ? scoringDistance / b.sliderTickRate * tickDistanceMultiplier : double.infinity;

    final duration = spanCount * distance / velocity;
    final spanDuration = duration / spanCount;
    final endTime = s.time + duration;
    Vec2 at(double progress) => path.positionAt(progress);
    final endPosition = spanCount.isOdd ? at(1) : at(0);

    // SliderEventGenerator (the legacy last tick isn't a nested object).
    final nested = <_Nested>[_Nested(_NestedKind.head, s.time, position)];
    final length = math.min(100000.0, distance);
    tickDistance = _clamp(tickDistance, 0, length);
    final minDistanceFromEnd = velocity * 10;
    for (var span = 0; span < spanCount; span++) {
      final spanStartTime = s.time + span * spanDuration;
      final reversed = span.isOdd;
      if (tickDistance != 0) {
        final ticks = <_Nested>[];
        for (var d = tickDistance; d <= length; d += tickDistance) {
          if (d >= length - minDistanceFromEnd) break;
          final pathProgress = d / length;
          final timeProgress = reversed ? 1 - pathProgress : pathProgress;
          ticks.add(_Nested(_NestedKind.tick, spanStartTime + timeProgress * spanDuration, at(pathProgress)));
        }
        nested.addAll(reversed ? ticks.reversed : ticks);
      }
      if (span < spanCount - 1) {
        nested.add(_Nested(
            _NestedKind.repeat, s.time + (span + 1) * spanDuration, at(((span + 1) % 2).toDouble())));
      }
    }
    nested.add(_Nested(_NestedKind.tail, s.time + duration, endPosition));
    _stableSort(nested, (n) => n.time);

    return _Obj.slider(s.time, endTime, position, endPosition, path, repeatCount, spanDuration, nested);
  }

  /// Display offset of an object with [height] (`StackHeight × Scale × −6.4`).
  Vec2 stackOffset(int height) {
    final d = _f(_f(height * scale) * _f(-6.4));
    return Vec2(d, d);
  }

  // OsuBeatmapProcessor.ApplyStacking

  void _applyStacking(List<_Obj> objs, int formatVersion) {
    if (objs.isEmpty) return;
    final threshold = _f(preempt * stackLeniency);
    if (formatVersion >= 6) {
      _stackingNew(objs, threshold);
    } else {
      _stackingOld(objs, threshold);
    }
  }

  static void _stackingNew(List<_Obj> objs, double threshold) {
    for (var i = objs.length - 1; i > 0; i--) {
      var n = i;
      var objectI = objs[i];
      if (objectI.stackHeight != 0 || objectI.isSpinner) continue;

      if (objectI.kind == _Kind.circle) {
        while (--n >= 0) {
          final objectN = objs[n];
          if (objectN.isSpinner) continue;
          if (objectI.startTime.truncate() - objectN.endTime.truncate() > threshold) break;

          if (objectN.isSlider && objectN.endPosition.distanceTo(objectI.position) < _stackDistance) {
            final offset = objectI.stackHeight - objectN.stackHeight + 1;
            for (var j = n + 1; j <= i; j++) {
              final objectJ = objs[j];
              if (objectN.endPosition.distanceTo(objectJ.position) < _stackDistance) {
                objectJ.stackHeight -= offset;
              }
            }
            break;
          }

          if (objectN.position.distanceTo(objectI.position) < _stackDistance) {
            objectN.stackHeight = objectI.stackHeight + 1;
            objectI = objectN;
          }
        }
      } else if (objectI.isSlider) {
        while (--n >= 0) {
          final objectN = objs[n];
          if (objectN.isSpinner) continue;
          if (objectI.startTime - objectN.startTime > threshold) break;
          if (objectN.endPosition.distanceTo(objectI.position) < _stackDistance) {
            objectN.stackHeight = objectI.stackHeight + 1;
            objectI = objectN;
          }
        }
      }
    }
  }

  static void _stackingOld(List<_Obj> objs, double threshold) {
    for (var i = 0; i < objs.length; i++) {
      final curr = objs[i];
      if (curr.stackHeight != 0 && !curr.isSlider) continue;
      var startTime = curr.endTime;
      var sliderStack = 0;
      final position2 = curr.isSlider ? curr.path!.positionAt(1) : curr.position;
      for (var j = i + 1; j < objs.length; j++) {
        if (objs[j].startTime - threshold > startTime) break;
        if (objs[j].position.distanceTo(curr.position) < _stackDistance) {
          curr.stackHeight++;
          startTime = objs[j].startTime;
        } else if (objs[j].position.distanceTo(position2) < _stackDistance) {
          sliderStack++;
          objs[j].stackHeight -= sliderStack;
          startTime = objs[j].startTime;
        }
      }
    }
  }
}

void _stableSort<T>(List<T> list, double Function(T) key) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final c = key(a.$2).compareTo(key(b.$2));
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = indexed[i].$2;
  }
}

// -----------------------------------------------------------------------------
// OsuDifficultyHitObject

class _DiffObject {
  final _Context ctx;
  final _Obj base;
  final _Obj last;
  final List<_DiffObject> _all;
  final int index;

  late final double deltaTime = base.startTime - last.startTime;
  double get startTime => base.startTime;
  double get endTime => base.endTime;

  /// The full 300 window (both sides); spinners have none.
  late final double hitWindowGreat = base.isSpinner ? 0 : 2 * ctx.great;
  late final double adjustedDeltaTime = math.max(deltaTime, _minDeltaTime);
  late final double lastObjectEndDeltaTime;
  double get preempt => ctx.preempt;

  double jumpDistance = 0;
  double lazyJumpDistance = 0;
  double minimumJumpTime = 0;
  double travelDistance = 0;
  double travelTime = 0;
  double lazyTravelDistance = 0;
  double lazyTravelTime = 0;
  Vec2? lazyEndPosition;
  double? angle;
  double? normalisedVectorAngle;

  _DiffObject(this.ctx, this.base, this.last, this._all, this.index) {
    final p = previous();
    lastObjectEndDeltaTime = p != null ? math.max(startTime - p.endTime, _minDeltaTime) : adjustedDeltaTime;
    _computeSliderCursorPosition();
    _setDistances();
  }

  _DiffObject? previous([int skip = 0]) {
    final i = index - (skip + 1);
    return i >= 0 && i < _all.length ? _all[i] : null;
  }

  _DiffObject? next([int skip = 0]) {
    final i = index + (skip + 1);
    return i >= 0 && i < _all.length ? _all[i] : null;
  }

  double get smallCircleBonus => math.max(1.0, 1.0 + (30 - ctx.radius) / 70);

  double get overallDifficulty => (79.5 - hitWindowGreat / 2) / 6;

  Vec2 stacked(_Obj o) => o.position + ctx.stackOffset(o.stackHeight);

  Vec2 get stackedPosition => stacked(base);

  double opacityAt(double time) {
    if (time > base.startTime) return 0;
    final fadeInStartTime = base.startTime - ctx.preempt;
    final fadeInDuration = 400 * math.min(1, ctx.preempt / 450);
    return _clamp((time - fadeInStartTime) / fadeInDuration, 0, 1);
  }

  double calculateDoubleTapFeasibility(_DiffObject? nextObj) {
    if (nextObj == null) return 0;
    final currDeltaTime = math.max(1.0, deltaTime);
    final nextDeltaTime = math.max(1.0, nextObj.deltaTime);
    final deltaDifference = (nextDeltaTime - currDeltaTime).abs();
    final speedRatio = currDeltaTime / math.max(currDeltaTime, deltaDifference);
    final windowRatio = _pow(math.min(1.0, currDeltaTime / hitWindowGreat), 5);
    final distanceFactor = _pow(_reverseLerp(lazyJumpDistance, _normalisedDiameter, _normalisedRadius), 2);
    return 1.0 - _pow(speedRatio, distanceFactor * (1 - windowRatio));
  }

  Vec2 _endCursorPosition(_DiffObject o) => o.lazyEndPosition ?? o.stackedPosition;

  void _setDistances() {
    if (base.isSlider) {
      travelDistance = lazyTravelDistance * math.max(1.0, _pow(base.repeatCount.toDouble(), 0.3));
      travelTime = math.max(lazyTravelTime, _minDeltaTime);
    }

    minimumJumpTime = adjustedDeltaTime;

    if (base.isSpinner || last.isSpinner) return;

    final scalingFactor = _f(_normalisedRadius / _f(ctx.radius));
    final lastDiff = previous();
    final lastLastDiff = previous(1);

    var lastCursorPosition = lastDiff != null ? _endCursorPosition(lastDiff) : stacked(last);

    jumpDistance = (stacked(last) - stackedPosition).length * scalingFactor;
    lazyJumpDistance = (stackedPosition - lastCursorPosition).length * scalingFactor;

    if (last.isSlider && lastDiff != null) {
      final lastTravelTime = math.max(lastDiff.lazyTravelTime, _minDeltaTime);
      minimumJumpTime = math.max(adjustedDeltaTime - lastTravelTime, _minDeltaTime);
    }

    if (lastLastDiff != null && !lastLastDiff.base.isSpinner) {
      if (lastDiff!.base.isSlider && lastDiff.travelDistance > 0) {
        lastCursorPosition = lastDiff.stackedPosition; // the head circle
      }
      final lastLastCursorPosition = _endCursorPosition(lastLastDiff);

      final a = _angle(stackedPosition, lastCursorPosition, lastLastCursorPosition);
      final sliderAngle = _sliderAngle(lastDiff, lastLastCursorPosition);

      final v = stackedPosition - lastCursorPosition;
      normalisedVectorAngle = math.atan2(v.y.abs(), v.x.abs());
      angle = math.min(a, sliderAngle);
    }
  }

  void _computeSliderCursorPosition() {
    if (!base.isSlider) return;
    final slider = base;
    final duration = slider.endTime - slider.startTime;
    var trackingEndTime =
        math.max(slider.startTime + duration + _tailLeniency, slider.startTime + duration / 2);

    var nested = slider.nested;
    _Nested? lastRealTick;
    for (final n in nested) {
      if (n.kind == _NestedKind.tick) lastRealTick = n;
    }
    if (lastRealTick != null && lastRealTick.time > trackingEndTime) {
      trackingEndTime = lastRealTick.time;
      // lazer moves the last tick to the end (kept for a zero diff with
      // its known output, not because it is right).
      nested = [...nested]
        ..remove(lastRealTick)
        ..add(lastRealTick);
    }

    lazyTravelTime = trackingEndTime - slider.startTime;

    var endTimeMin = lazyTravelTime / slider.spanDuration;
    if (endTimeMin % 2 >= 1) {
      endTimeMin = 1 - endTimeMin % 1;
    } else {
      endTimeMin %= 1;
    }

    final offset = ctx.stackOffset(slider.stackHeight);
    var lazyEnd = slider.path!.positionAt(endTimeMin) + offset;
    var currCursorPosition = slider.position + offset;
    final scalingFactor = _normalisedRadius / ctx.radius;

    for (var i = 1; i < nested.length; i++) {
      final currMovementObj = nested[i];
      var currMovement = currMovementObj.position + offset - currCursorPosition;
      var currMovementLength = scalingFactor * currMovement.length;
      var requiredMovement = _assumedSliderRadius;

      if (i == nested.length - 1) {
        final lazyMovement = lazyEnd - currCursorPosition;
        if (lazyMovement.length < currMovement.length) currMovement = lazyMovement;
        currMovementLength = scalingFactor * currMovement.length;
      } else if (currMovementObj.kind == _NestedKind.repeat) {
        requiredMovement = _normalisedRadius;
      }

      if (currMovementLength > requiredMovement) {
        currCursorPosition =
            currCursorPosition + currMovement * _f((currMovementLength - requiredMovement) / currMovementLength);
        currMovementLength *= (currMovementLength - requiredMovement) / currMovementLength;
        lazyTravelDistance += currMovementLength;
      }

      if (i == nested.length - 1) lazyEnd = currCursorPosition;
    }
    lazyEndPosition = lazyEnd;
  }

  double _sliderAngle(_DiffObject lastDiff, Vec2 lastLastCursorPosition) {
    final lastCursorPosition = _endCursorPosition(lastDiff);
    if (lastDiff.base.isSlider && lastDiff.travelDistance > 0) {
      final nested = lastDiff.base.nested;
      lastLastCursorPosition = nested[nested.length - 2].position + ctx.stackOffset(lastDiff.base.stackHeight);
    }
    return _angle(stackedPosition, lastCursorPosition, lastLastCursorPosition);
  }

  static double _angle(Vec2 current, Vec2 last, Vec2 lastLast) {
    final v1 = lastLast - last;
    final v2 = current - last;
    final dot = v1.x * v2.x + v1.y * v2.y;
    final det = v1.x * v2.y - v1.y * v2.x;
    return math.atan2(det, dot).abs();
  }
}

// -----------------------------------------------------------------------------
// Evaluators

abstract final class _SnapAimEvaluator {
  static double evaluate(_DiffObject curr, bool withSliders) {
    final lastObj = curr.previous();
    if (curr.base.isSpinner || curr.index <= 1 || lastObj!.base.isSpinner) return 0;

    const wideAngleMultiplier = 9.67;
    const acuteAngleMultiplier = 2.41;
    const sliderMultiplier = 1.5;
    const velocityChangeMultiplier = 0.9;
    const wiggleMultiplier = 1.02;
    const radius = _normalisedRadius;
    const diameter = _normalisedDiameter;

    final last2Obj = curr.previous(2);

    final currDistance = withSliders ? curr.lazyJumpDistance : curr.jumpDistance;
    var currVelocity = currDistance / curr.adjustedDeltaTime;

    if (lastObj.base.isSlider && withSliders) {
      final sliderDistance = lastObj.lazyTravelDistance + curr.lazyJumpDistance;
      currVelocity = math.max(currVelocity, sliderDistance / curr.adjustedDeltaTime);
    }

    final prevDistance = withSliders ? lastObj.lazyJumpDistance : lastObj.jumpDistance;
    final prevVelocity = prevDistance / lastObj.adjustedDeltaTime;

    var snapDifficulty = currVelocity;
    snapDifficulty *= _vectorAngleRepetition(curr, lastObj);

    if (curr.angle != null && lastObj.angle != null) {
      final currAngle = curr.angle!;
      final lastAngle = lastObj.angle!;
      final velocityInfluence = math.min(currVelocity, prevVelocity);

      var acuteAngleBonus = 0.0;
      if (math.max(curr.adjustedDeltaTime, lastObj.adjustedDeltaTime) <
          1.25 * math.min(curr.adjustedDeltaTime, lastObj.adjustedDeltaTime)) {
        acuteAngleBonus = calcAngleAcuteness(currAngle);
        acuteAngleBonus *= 0.08 + 0.92 * (1 - math.min(acuteAngleBonus, _pow(calcAngleAcuteness(lastAngle), 3)));
        acuteAngleBonus *= velocityInfluence *
            _smootherstep(_millisecondsToBpm(curr.adjustedDeltaTime, 2), 300, 400) *
            _smootherstep(currDistance, 0, diameter * 2);
      }

      var wideAngleBonus = _calcAngleWideness(currAngle);
      wideAngleBonus *= 0.25 + 0.75 * (1 - math.min(wideAngleBonus, _pow(_calcAngleWideness(lastAngle), 3)));

      const wideAngleTimeScale = 1.45;
      var wideAngleCurrVelocity = currDistance / _pow(curr.adjustedDeltaTime, wideAngleTimeScale);
      final wideAnglePrevVelocity = prevDistance / _pow(lastObj.adjustedDeltaTime, wideAngleTimeScale);

      if (lastObj.base.isSlider && withSliders) {
        final sliderDistance = lastObj.lazyTravelDistance + curr.lazyJumpDistance;
        wideAngleCurrVelocity =
            math.max(wideAngleCurrVelocity, sliderDistance / _pow(curr.adjustedDeltaTime, wideAngleTimeScale));
      }

      wideAngleBonus *= math.min(wideAngleCurrVelocity, wideAnglePrevVelocity);

      if (last2Obj != null) {
        final distance = _f(lastObj.stackedPosition.distanceTo(last2Obj.stackedPosition));
        if (distance < 1) wideAngleBonus *= 1 - 0.55 * (1 - distance);
      }

      snapDifficulty += math.max(acuteAngleBonus * acuteAngleMultiplier, wideAngleBonus * wideAngleMultiplier);

      final wiggleBonus = velocityInfluence *
          _smootherstep(currDistance, radius, diameter) *
          _pow(_reverseLerp(currDistance, diameter * 3, diameter), 1.8) *
          _smootherstep(currAngle, _degToRad(110), _degToRad(60)) *
          _smootherstep(prevDistance, radius, diameter) *
          _pow(_reverseLerp(prevDistance, diameter * 3, diameter), 1.8) *
          _smootherstep(lastAngle, _degToRad(110), _degToRad(60));

      snapDifficulty += wiggleBonus * wiggleMultiplier;
    }

    if (math.max(prevVelocity, currVelocity) != 0) {
      if (withSliders) currVelocity = currDistance / curr.adjustedDeltaTime;

      final distRatio =
          _smoothstep((prevVelocity - currVelocity).abs() / math.max(prevVelocity, currVelocity), 0, 1);
      final overlapVelocityBuff = math.min(diameter * 1.25 / math.min(curr.adjustedDeltaTime, lastObj.adjustedDeltaTime),
          (prevVelocity - currVelocity).abs());
      var velocityChangeBonus = overlapVelocityBuff * distRatio;
      velocityChangeBonus *= _pow(
          math.min(curr.adjustedDeltaTime, lastObj.adjustedDeltaTime) /
              math.max(curr.adjustedDeltaTime, lastObj.adjustedDeltaTime),
          2);
      snapDifficulty += velocityChangeBonus * velocityChangeMultiplier;
    }

    if (curr.base.isSlider && withSliders) {
      final sliderBonus = curr.travelDistance / curr.travelTime;
      snapDifficulty += (sliderBonus < 1 ? sliderBonus : _pow(sliderBonus, 0.75)) * sliderMultiplier;
    }

    snapDifficulty *= curr.smallCircleBonus;
    snapDifficulty *= _highBpmBonus(curr.adjustedDeltaTime);
    return snapDifficulty;
  }

  static double _highBpmBonus(double ms) => 1 / (1 - _pow(0.03, _pow(ms / 1000, 0.65)));

  static double _vectorAngleRepetition(_DiffObject current, _DiffObject previous) {
    if (current.angle == null || previous.angle == null) return 1;

    const noteLimit = 6;
    const maximumRepetitionNerf = 0.15;
    const maximumVectorInfluence = 0.5;

    var constantAngleCount = 0.0;
    for (var index = 0; index < noteLimit; index++) {
      final prevObj = current.previous(index);
      if (prevObj == null) break;
      if (math.max(current.adjustedDeltaTime, prevObj.adjustedDeltaTime) >
          1.1 * math.min(current.adjustedDeltaTime, prevObj.adjustedDeltaTime)) {
        break;
      }
      if (prevObj.normalisedVectorAngle != null && current.normalisedVectorAngle != null) {
        final angleDifference = (current.normalisedVectorAngle! - prevObj.normalisedVectorAngle!).abs();
        constantAngleCount += math.cos(8 * math.min(_degToRad(11.25), angleDifference));
      }
    }

    final vectorRepetition = _pow(math.min(0.5 / constantAngleCount, 1.0), 2);
    final stackFactor = _smootherstep(current.lazyJumpDistance, 0, _normalisedDiameter);
    final currAngle = current.angle!;
    final lastAngle = previous.angle!;
    final angleDifferenceAdjusted = math.cos(2 * math.min(_degToRad(45), (currAngle - lastAngle).abs() * stackFactor));
    final baseNerf = 1 - maximumRepetitionNerf * calcAngleAcuteness(lastAngle) * angleDifferenceAdjusted;
    return _pow(baseNerf + (1 - baseNerf) * vectorRepetition * maximumVectorInfluence * stackFactor, 2);
  }

  static double _calcAngleWideness(double angle) => _smoothstep(angle, _degToRad(40), _degToRad(140));

  static double calcAngleAcuteness(double angle) => _smoothstep(angle, _degToRad(140), _degToRad(40));
}

abstract final class _AgilityEvaluator {
  static double evaluate(_DiffObject curr) {
    if (curr.base.isSpinner) return 0;
    const distanceCap = _normalisedDiameter * 1.2;
    final prev = curr.index > 0 ? curr.previous() : null;
    final travelDistance = prev?.lazyTravelDistance ?? 0;
    final distance = travelDistance + curr.lazyJumpDistance;
    final distanceScaled = math.min(distance, distanceCap) / distanceCap;
    var agilityDifficulty = distanceScaled * 1000 / curr.adjustedDeltaTime;
    agilityDifficulty *= _pow(curr.smallCircleBonus, 1.5);
    agilityDifficulty *= 1 / (1 - _pow(0.2, curr.adjustedDeltaTime / 1000));
    return agilityDifficulty;
  }
}

abstract final class _FlowAimEvaluator {
  static double evaluate(_DiffObject curr, bool withSliders) {
    final lastObj = curr.previous();
    if (curr.base.isSpinner || curr.index <= 1 || lastObj!.base.isSpinner) return 0;

    const velocityChangeMultiplier = 0.52;
    final lastLastObj = curr.previous(1)!;

    final currDistance = withSliders ? curr.lazyJumpDistance : curr.jumpDistance;
    final prevDistance = withSliders ? lastObj.lazyJumpDistance : lastObj.jumpDistance;

    var currVelocity = currDistance / curr.adjustedDeltaTime;
    if (lastObj.base.isSlider && withSliders) {
      final sliderDistance = lastObj.lazyTravelDistance + curr.lazyJumpDistance;
      currVelocity = math.max(currVelocity, sliderDistance / curr.adjustedDeltaTime);
    }
    final prevVelocity = prevDistance / lastObj.adjustedDeltaTime;

    var flowDifficulty = currVelocity;
    flowDifficulty *= math.sqrt(curr.smallCircleBonus);
    flowDifficulty *= 1 +
        math.min(
            0.25,
            _pow(
                (math.max(curr.adjustedDeltaTime, lastObj.adjustedDeltaTime) -
                        math.min(curr.adjustedDeltaTime, lastObj.adjustedDeltaTime)) /
                    50,
                4));

    if (curr.angle != null && lastObj.angle != null) {
      final angleDifference = (curr.angle! - lastObj.angle!).abs();
      final angleDifferenceAdjusted = math.sin(angleDifference / 2) * 180.0;
      final angularVelocity = angleDifferenceAdjusted / (curr.adjustedDeltaTime * 0.1);
      flowDifficulty *= 0.8 + math.sqrt(angularVelocity / 270.0);
    }

    var overlappedNotesWeight = 1.0;
    if (curr.index > 2) {
      final o1 = _overlapFactor(curr, lastObj);
      final o2 = _overlapFactor(curr, lastLastObj);
      final o3 = _overlapFactor(lastObj, lastLastObj);
      overlappedNotesWeight = 1 - o1 * o2 * o3;
    }

    if (curr.angle != null) {
      flowDifficulty += currVelocity * _SnapAimEvaluator.calcAngleAcuteness(curr.angle!) * overlappedNotesWeight;
    }

    if (math.max(prevVelocity, currVelocity) != 0) {
      if (withSliders) currVelocity = currDistance / curr.adjustedDeltaTime;
      final distRatio =
          _smoothstep((prevVelocity - currVelocity).abs() / math.max(prevVelocity, currVelocity), 0, 1);
      final overlapVelocityBuff = math.min(
          _normalisedDiameter * 1.25 / math.min(curr.adjustedDeltaTime, lastObj.adjustedDeltaTime),
          (prevVelocity - currVelocity).abs());
      flowDifficulty += overlapVelocityBuff * distRatio * overlappedNotesWeight * velocityChangeMultiplier;
    }

    if (curr.base.isSlider && withSliders) {
      flowDifficulty += curr.travelDistance / curr.travelTime;
    }

    flowDifficulty = _pow(flowDifficulty, 1.45);
    return flowDifficulty * _smootherstep(currDistance, 0, _normalisedRadius);
  }

  static double _overlapFactor(_DiffObject first, _DiffObject second) {
    final objectRadius = first.ctx.radius;
    final distance = first.stackedPosition.distanceTo(second.stackedPosition);
    return _clamp(1 - _pow(math.max(distance - objectRadius, 0) / objectRadius, 2), 0, 1);
  }
}

abstract final class _SpeedEvaluator {
  static double evaluate(_DiffObject curr) {
    if (curr.base.isSpinner) return 0;
    const minSpeedBonus = 200.0;
    const speedBalancingFactor = 40.0;

    var strainTime = curr.adjustedDeltaTime;
    final doubleTapFeasibility = 1.0 - curr.calculateDoubleTapFeasibility(curr.next());

    strainTime /= _clamp((strainTime / curr.hitWindowGreat) / 0.93, 0.92, 1);

    var speedBonus = 0.0;
    if (_millisecondsToBpm(strainTime) > minSpeedBonus) {
      speedBonus = 0.75 * _pow((_bpmToMilliseconds(minSpeedBonus) - strainTime) / speedBalancingFactor, 2);
    }

    var speedDifficulty = (1 + speedBonus) * 1000 / strainTime;
    speedDifficulty *= 1 / (1 - _pow(0.3, curr.adjustedDeltaTime / 1000));
    return speedDifficulty * doubleTapFeasibility;
  }
}

class _Island {
  static const _unset = 2147483647; // int.MaxValue

  int delta;
  int deltaCount = 1;
  int occurrences = 1;

  _Island(int delta) : delta = math.max(delta, _minDeltaTime.toInt());

  void addDelta(int d) {
    if (delta == _unset) delta = math.max(d, _minDeltaTime.toInt());
    deltaCount++;
  }

  bool isSimilarPolarity(_Island other, double epsilon) {
    if (deltaCount <= 1 || other.deltaCount <= 1) return false;
    return (delta - other.delta).abs() < epsilon && deltaCount % 2 == other.deltaCount % 2;
  }

  bool almostEquals(_Island other, double epsilon) =>
      (delta - other.delta).abs() < epsilon && deltaCount == other.deltaCount;
}

abstract final class _RhythmEvaluator {
  static double evaluate(_DiffObject current) {
    if (current.base.isSpinner) return 0;

    const historyTimeMax = 5 * 1000;
    const historyObjectsMax = 32;
    const rhythmOverallMultiplier = 0.95;
    const deltaMinValue = 1e-7;

    var rhythmComplexitySum = 0.0;
    final deltaDifferenceEpsilon = current.hitWindowGreat * 0.3;

    var island = _Island(_Island._unset);
    var previousIsland = _Island(_Island._unset);
    final islands = <_Island>[];

    var startDifficulty = 0.0;
    var firstDeltaSwitch = false;

    final historicalNoteCount = math.min(current.index, historyObjectsMax);

    var rhythmStart = 0;
    while (rhythmStart < historicalNoteCount - 2 &&
        current.startTime - current.previous(rhythmStart)!.startTime < historyTimeMax) {
      rhythmStart++;
    }

    var prevObj = current.previous(rhythmStart);
    var prevPrevObj = current.previous(rhythmStart + 1);

    for (var i = rhythmStart; i > 0; i--) {
      final currObj = current.previous(i - 1)!;
      if (currObj.base.isSpinner) continue;

      final timeDecay = (historyTimeMax - (current.startTime - currObj.startTime)) / historyTimeMax;
      final noteDecay = (historicalNoteCount - i) / historicalNoteCount;
      final currHistoricalDecay = math.min(noteDecay, timeDecay);

      final currDelta = math.max(currObj.deltaTime, deltaMinValue);
      final prevDelta = math.max(prevObj!.deltaTime, deltaMinValue);
      final deltaDifference = (prevDelta - currDelta).abs();

      if (island.delta == _Island._unset) island = _Island(currDelta.toInt());

      final deltaDifferenceRatio = math.max(prevDelta, currDelta) / math.min(prevDelta, currDelta);
      final differenceMultiplier = _clamp(2.0 - deltaDifferenceRatio / 8.0, 0, 1);
      final windowPenalty = _clamp((deltaDifference - deltaDifferenceEpsilon) / deltaDifferenceEpsilon, 0, 1);

      var effectiveDifficulty = _effectiveDifficulty(deltaDifferenceRatio) * windowPenalty * differenceMultiplier;

      if (prevObj.base.isSlider) {
        final sliderLazyEndDelta = currObj.minimumJumpTime;
        final sliderLazyRatio =
            math.max(sliderLazyEndDelta, currDelta) / math.min(sliderLazyEndDelta, currDelta);
        final sliderRealEndDelta = currObj.lastObjectEndDeltaTime;
        final sliderRealRatio =
            math.max(sliderRealEndDelta, currDelta) / math.min(sliderRealEndDelta, currDelta);
        final sliderEffectiveDifficulty =
            math.min(_effectiveDifficulty(sliderLazyRatio), _effectiveDifficulty(sliderRealRatio));
        effectiveDifficulty = math.min(sliderEffectiveDifficulty, effectiveDifficulty);
      }

      if (deltaDifference < deltaDifferenceEpsilon) island.addDelta(currDelta.toInt());

      if (firstDeltaSwitch) {
        if (deltaDifference > deltaDifferenceEpsilon) {
          if (currObj.base.isSlider) effectiveDifficulty *= 0.5;
          if (island.isSimilarPolarity(previousIsland, deltaDifferenceEpsilon)) effectiveDifficulty *= 0.5;
          if (math.max(prevPrevObj!.deltaTime, deltaMinValue) > prevDelta + deltaDifferenceEpsilon &&
              prevDelta > currDelta + deltaDifferenceEpsilon) {
            effectiveDifficulty *= 0.125;
          }
          if (previousIsland.deltaCount == island.deltaCount) effectiveDifficulty *= 0.5;

          final isSpeedingUp = prevDelta > currDelta + deltaDifferenceEpsilon;
          if (isSpeedingUp) effectiveDifficulty *= 0.65;

          var found = false;
          for (final existingIsland in islands) {
            if (existingIsland.almostEquals(island, deltaDifferenceEpsilon)) {
              if (previousIsland.almostEquals(island, deltaDifferenceEpsilon)) existingIsland.occurrences++;
              final power = _logistic(island.delta.toDouble(), 58.33, 0.24, 2.75);
              effectiveDifficulty *=
                  math.min(3.0 / existingIsland.occurrences, _pow(1.0 / existingIsland.occurrences, power));
              found = true;
              break;
            }
          }
          if (!found && island.deltaCount > 0) islands.add(island);

          effectiveDifficulty *= 1 - prevObj.calculateDoubleTapFeasibility(currObj) * 0.75;

          if (island.deltaCount > 1) {
            rhythmComplexitySum += math.sqrt(effectiveDifficulty * startDifficulty) * currHistoricalDecay;
          } else {
            rhythmComplexitySum += 0.7 * currHistoricalDecay;
          }

          startDifficulty = effectiveDifficulty;
          if (prevDelta + deltaDifferenceEpsilon < currDelta) firstDeltaSwitch = false;

          previousIsland = island;
          island = _Island(currDelta.toInt());
        }
      } else if (prevDelta > currDelta + deltaDifferenceEpsilon) {
        firstDeltaSwitch = true;
        if (currObj.base.isSlider) effectiveDifficulty *= 0.6;
        if (prevObj.base.isSlider) effectiveDifficulty *= 0.6;
        startDifficulty = effectiveDifficulty;
        island = _Island(currDelta.toInt());
      }

      prevPrevObj = prevObj;
      prevObj = currObj;
    }

    rhythmComplexitySum *= _reverseLerp(island.deltaCount.toDouble(), 22, 3);
    return math.sqrt(4 + rhythmComplexitySum * rhythmOverallMultiplier) / 2.0;
  }

  static double _effectiveDifficulty(double deltaDifferenceRatio) {
    final fraction = deltaDifferenceRatio - deltaDifferenceRatio.truncateToDouble();
    return 1.0 + 26.0 * math.min(0.5, _smoothstepBellCurve(fraction));
  }
}

abstract final class _ReadingEvaluator {
  static const _readingWindowSize = 3000.0;
  static const _distanceInfluenceThreshold = _normalisedDiameter * 1.5;

  static double evaluate(_DiffObject curr) {
    if (curr.base.isSpinner || curr.index == 0) return 0;
    final nextObj = curr.next();

    final velocity = math.max(1.0, curr.lazyJumpDistance / curr.adjustedDeltaTime);
    final currentVisibleObjectDensity = _currentVisibleObjectDensity(curr);
    final pastObjectDifficultyInfluence = _pastObjectDifficultyInfluence(curr);
    final constantAngleNerfFactor = _constantAngleNerfFactor(curr);

    final noteDensityDifficulty = _densityDifficulty(
        nextObj, velocity, constantAngleNerfFactor, pastObjectDifficultyInfluence, currentVisibleObjectDensity);
    final preemptDifficulty = _preemptDifficulty(velocity, constantAngleNerfFactor, curr.preempt);

    var readingDifficulty = _norm(1.5, [preemptDifficulty, 0, noteDensityDifficulty]);
    readingDifficulty *= 1 / (1 - _pow(0.8, curr.adjustedDeltaTime / 1000));
    return readingDifficulty;
  }

  static double _densityDifficulty(_DiffObject? nextObj, double velocity, double constantAngleNerfFactor,
      double pastObjectDifficultyInfluence, double currentVisibleObjectDensity) {
    const densityMultiplier = 2.4;
    const densityDifficultyBase = 2.5;

    var futureObjectDifficultyInfluence = math.sqrt(currentVisibleObjectDensity);
    if (nextObj != null) {
      futureObjectDifficultyInfluence *= _smootherstep(nextObj.lazyJumpDistance, 15, _distanceInfluenceThreshold);
    }

    var noteDensityDifficulty = _pow(pastObjectDifficultyInfluence + futureObjectDifficultyInfluence, 1.7) *
        0.4 *
        constantAngleNerfFactor *
        velocity;
    noteDensityDifficulty = math.max(0, noteDensityDifficulty - densityDifficultyBase);
    return _pow(noteDensityDifficulty, 0.45) * densityMultiplier;
  }

  static double _preemptDifficulty(double velocity, double constantAngleNerfFactor, double preempt) {
    const preemptBalancingFactor = 140000.0;
    const preemptStartingPoint = 500.0;
    var preemptDifficulty =
        _pow((preemptStartingPoint - preempt + (preempt - preemptStartingPoint).abs()) / 2, 2.5) /
            preemptBalancingFactor;
    return preemptDifficulty * constantAngleNerfFactor * velocity;
  }

  static double _pastObjectDifficultyInfluence(_DiffObject curr) {
    var influence = 0.0;
    for (var i = 0; i < curr.index; i++) {
      final loopObj = curr.previous(i);
      if (loopObj == null ||
          curr.startTime - loopObj.startTime > _readingWindowSize ||
          loopObj.startTime < curr.startTime - curr.preempt) {
        break;
      }
      var loopDifficulty = curr.opacityAt(loopObj.base.startTime);
      loopDifficulty *= _smootherstep(loopObj.lazyJumpDistance, 15, _distanceInfluenceThreshold);
      loopDifficulty *= _timeNerfFactor(curr.startTime - loopObj.startTime);
      influence += loopDifficulty;
    }
    return influence;
  }

  static double _currentVisibleObjectDensity(_DiffObject curr) {
    var visibleObjectCount = 0.0;
    var o = curr.next();
    while (o != null) {
      if (o.startTime - curr.startTime > _readingWindowSize || curr.startTime < o.startTime - o.preempt) break;
      visibleObjectCount += o.opacityAt(curr.base.startTime) * _timeNerfFactor(o.startTime - curr.startTime);
      o = o.next();
    }
    return visibleObjectCount;
  }

  static double _constantAngleNerfFactor(_DiffObject current) {
    const minimumAngleRelevancyTime = 2000.0;
    const maximumAngleRelevancyTime = 200.0;

    var constantAngleCount = 0.0;
    var index = 0;
    var currentTimeGap = 0.0;

    var loopObjPrev0 = current;
    _DiffObject? loopObjPrev1;
    _DiffObject? loopObjPrev2;

    while (currentTimeGap < minimumAngleRelevancyTime) {
      final loopObj = current.previous(index);
      if (loopObj == null) break;

      final longIntervalFactor =
          1 - _reverseLerp(loopObj.adjustedDeltaTime, maximumAngleRelevancyTime, minimumAngleRelevancyTime);

      if (loopObj.angle != null && current.angle != null) {
        final angleDifference = (current.angle! - loopObj.angle!).abs();
        var angleDifferenceAlternating = math.pi;

        if (loopObjPrev0.angle != null && loopObjPrev1?.angle != null && loopObjPrev2?.angle != null) {
          angleDifferenceAlternating = (loopObjPrev1!.angle! - loopObj.angle!).abs();
          angleDifferenceAlternating += (loopObjPrev2!.angle! - loopObjPrev0.angle!).abs();

          var weight = 1.0;
          weight *= _reverseLerp(math.min(loopObj.angle!, loopObjPrev0.angle!) * 180 / math.pi, 20, 5);
          weight *= _reverseLerp(math.max(loopObj.angle!, loopObjPrev0.angle!) * 180 / math.pi, 60, 120);
          angleDifferenceAlternating = _lerp(math.pi, 0.1 * angleDifferenceAlternating, weight);
        }

        final stackFactor = _smootherstep(loopObj.lazyJumpDistance, 0, _normalisedRadius);
        constantAngleCount += math.cos(
                3 * math.min(_degToRad(30), math.min(angleDifference, angleDifferenceAlternating) * stackFactor)) *
            longIntervalFactor;
      }

      currentTimeGap = current.startTime - loopObj.startTime;
      index++;

      loopObjPrev2 = loopObjPrev1;
      loopObjPrev1 = loopObjPrev0;
      loopObjPrev0 = loopObj;
    }

    return _clamp(2 / constantAngleCount, 0.2, 1);
  }

  static double _timeNerfFactor(double deltaTime) => _clamp(2 - deltaTime / (_readingWindowSize / 2), 0, 1);
}

// -----------------------------------------------------------------------------
// Skills

/// One strain section (lazer `StrainPeak`), compared highest first.
class _StrainPeak {
  final double value;
  final double sectionLength;
  _StrainPeak(this.value, double sectionLength) : sectionLength = _roundHalfEven(sectionLength);
}

/// lazer `VariableLengthStrainSkill` + `Aim` (with sliders).
class _Aim {
  static const _decayWeight = 0.9;
  static const _maxSectionLength = 400;
  static const _maxStoredLength = 11 / (1 - _decayWeight);

  double _currentStrain = 0;
  double _currentSectionPeak = 0;
  double _currentSectionBegin = 0;
  double _currentSectionEnd = 0;
  double _totalLength = 0;
  final List<_StrainPeak> _strainPeaks = []; // highest first
  final List<(double, double)> _queuedStrains = []; // (strain, startTime)

  /// The strain after each processed object.
  final List<double> objectStrains = [];

  double _strainDecay(double ms) => _pow(0.2, ms / 1000);

  double _initialStrain(double time, _DiffObject current) =>
      _currentStrain * _strainDecay(time - current.previous()!.startTime);

  double _strainValueAt(_DiffObject current) {
    final decay = _strainDecay(current.adjustedDeltaTime);
    _currentStrain *= decay;
    _currentStrain += _adjustedDifficulty(current) * (1 - decay);
    return _currentStrain;
  }

  static double _adjustedDifficulty(_DiffObject current) {
    const skillMultiplierSnap = 70.9;
    const skillMultiplierAgility = 2.35;
    const skillMultiplierFlow = 242.0;
    final snap = _SnapAimEvaluator.evaluate(current, true) * skillMultiplierSnap;
    final agility = _AgilityEvaluator.evaluate(current) * skillMultiplierAgility;
    final flow = _FlowAimEvaluator.evaluate(current, true) * skillMultiplierFlow;
    var total = _totalValue(snap, agility, flow);
    total *= 0.985 + _pow(math.max(0.0, current.overallDifficulty), 2) / 4000;
    return total;
  }

  static double _totalValue(double snap, double agility, double flow) {
    const skillMultiplierTotal = 1.12;
    const combinedSnapNormExponent = 1.2;
    final combinedSnap = _norm(combinedSnapNormExponent, [snap, agility]);
    final pSnap = _snapFlowProbability(flow / combinedSnap);
    final pFlow = 1 - pSnap;
    return (combinedSnap * pSnap + flow * pFlow) * skillMultiplierTotal;
  }

  static double _snapFlowProbability(double ratio) {
    const k = 7.27;
    if (ratio == 0) return 0;
    if (ratio.isNaN) return 1;
    return _logisticExp(-k * math.log(ratio));
  }

  void process(_DiffObject current) {
    if (current.index == 0) {
      _currentSectionBegin = current.startTime;
      _currentSectionEnd = _currentSectionBegin + _maxSectionLength;
      _currentSectionPeak = _strainValueAt(current);
      objectStrains.add(_currentSectionPeak);
      return;
    }

    _backfillPeaks(current);
    final currentStrain = _strainValueAt(current);
    objectStrains.add(currentStrain);

    if (currentStrain > _currentSectionPeak) {
      _queuedStrains.clear();
      _saveCurrentPeak(current.startTime - _currentSectionBegin);
      _currentSectionBegin = current.startTime;
      _currentSectionEnd = _currentSectionBegin + _maxSectionLength;
      _currentSectionPeak = currentStrain;
    } else {
      while (_queuedStrains.isNotEmpty && _queuedStrains.last.$1 < currentStrain) {
        _queuedStrains.removeLast();
      }
      _queuedStrains.add((currentStrain, current.startTime));
    }
  }

  void _backfillPeaks(_DiffObject current) {
    while (current.startTime > _currentSectionEnd) {
      _saveCurrentPeak(_currentSectionEnd - _currentSectionBegin);
      _currentSectionBegin = _currentSectionEnd;

      if (_queuedStrains.isNotEmpty) {
        final (strain, startTime) = _queuedStrains.removeAt(0);
        _currentSectionEnd = startTime + _maxSectionLength;
        _currentSectionPeak = _initialStrain(_currentSectionBegin, current);
        _currentSectionPeak = math.max(_currentSectionPeak, strain);
      } else {
        _currentSectionEnd = _currentSectionBegin + _maxSectionLength;
        _currentSectionPeak = _initialStrain(_currentSectionBegin, current);
      }
    }
  }

  void _saveCurrentPeak(double sectionLength) {
    _insertPeak(_StrainPeak(_currentSectionPeak, sectionLength));
    _totalLength += sectionLength;
    while (_totalLength > _maxStoredLength * _maxSectionLength) {
      _totalLength -= _strainPeaks.removeLast().sectionLength;
    }
  }

  void _insertPeak(_StrainPeak peak) {
    var lo = 0, hi = _strainPeaks.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_strainPeaks[mid].value >= peak.value) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    _strainPeaks.insert(lo, peak);
  }

  double difficultyValue() {
    _insertPeak(_StrainPeak(_currentSectionPeak, _currentSectionEnd - _currentSectionBegin));

    var difficulty = 0.0;
    var time = 0.0;
    for (final strain in _reducedStrainPeaks()) {
      final startTime = time;
      final endTime = time + strain.sectionLength / _maxSectionLength;
      final weight = _pow(_decayWeight, startTime) - _pow(_decayWeight, endTime);
      difficulty += strain.value * weight;
      time = endTime;
    }
    return difficulty / (1 - _decayWeight);
  }

  List<_StrainPeak> _reducedStrainPeaks() {
    const reducedSectionTime = 4000.0;
    const reducedStrainBaseline = 0.727;
    const chunkSize = 20.0;

    final strains = [for (final p in _strainPeaks) if (p.value > 0) p];
    var time = 0.0;
    var skipCount = 0;

    while (strains.length > skipCount && time < reducedSectionTime) {
      final strain = strains[skipCount];
      for (var addedTime = 0.0; addedTime < strain.sectionLength; addedTime += chunkSize) {
        final scale = _log10(_lerp(1, 10, _clamp((time + addedTime) / reducedSectionTime, 0, 1)));
        strains.add(_StrainPeak(strain.value * _lerp(reducedStrainBaseline, 1.0, scale),
            math.min(chunkSize, strain.sectionLength - addedTime)));
      }
      time += strain.sectionLength;
      skipCount++;
    }

    final rest = strains.sublist(skipCount);
    _stableSort(rest, (p) => -p.value);
    return rest;
  }
}

/// lazer `HarmonicSkill`: a weighted sum of the per-object difficulties.
abstract class _HarmonicSkill {
  final List<double> objectDifficulties = [];

  /// Sum of the weights used by [difficultyValue] (lazer `ObjectWeightSum`).
  double objectWeightSum = 0;

  double get harmonicScale => 1.0;
  double get decayExponent => 0.9;

  double objectDifficultyOf(_DiffObject current);

  void process(_DiffObject current) => objectDifficulties.add(objectDifficultyOf(current));

  List<double> transformedDifficulties(List<double> difficulties) => difficulties;

  double difficultyValue() {
    objectWeightSum = 0;
    if (objectDifficulties.isEmpty) return 0;
    final sorted = [for (final d in transformedDifficulties(objectDifficulties)) if (d > 0) d]
      ..sort((a, b) => b.compareTo(a));
    var difficulty = 0.0;
    for (var index = 0; index < sorted.length; index++) {
      final h = harmonicScale / (1 + index);
      final weight = (1 + h) / (_pow(index.toDouble(), decayExponent) + 1 + h);
      difficulty += sorted[index] * weight;
      objectWeightSum += weight;
    }
    return difficulty;
  }
}

class _Speed extends _HarmonicSkill {
  double _currentStrain = 0;

  @override
  double get harmonicScale => 20;

  @override
  double objectDifficultyOf(_DiffObject current) {
    const skillMultiplier = 1.16;
    final decay = _pow(0.3, current.adjustedDeltaTime / 1000);
    _currentStrain *= decay;
    _currentStrain += _SpeedEvaluator.evaluate(current) * (1 - decay) * skillMultiplier;
    return _currentStrain * _RhythmEvaluator.evaluate(current);
  }
}

class _Reading extends _HarmonicSkill {
  double _currentStrain = 0;
  double _reducedNoteCount = 0;
  double? _reducedDuration;

  @override
  double objectDifficultyOf(_DiffObject current) {
    const skillMultiplier = 2.5;
    const reducedDifficultyDuration = 60 * 1000;
    final decay = _pow(0.8, current.deltaTime / 1000);
    _currentStrain *= decay;
    _currentStrain += _adjustedDifficulty(current) * (1 - decay) * skillMultiplier;

    _reducedDuration ??= current.startTime + reducedDifficultyDuration;
    if (current.startTime <= _reducedDuration!) _reducedNoteCount++;
    return _currentStrain;
  }

  static double _adjustedDifficulty(_DiffObject current) {
    var difficulty = _ReadingEvaluator.evaluate(current);
    difficulty *= 0.825 + _pow(math.max(0.0, current.overallDifficulty), 2.2) / 1125.0;
    return difficulty;
  }

  @override
  List<double> transformedDifficulties(List<double> difficulties) {
    final out = [for (final d in difficulties) if (d > 0) d];
    for (var i = 0; i < math.min(out.length, _reducedNoteCount); i++) {
      final scale = _log10(_lerp(1, 10, _clamp(i / _reducedNoteCount, 0, 1)));
      out[i] *= _lerp(0.0, 1.0, scale);
    }
    return out;
  }
}
