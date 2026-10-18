/// Bit flags of the `effects` field.
abstract final class TimingEffects {
  static const kiai = 1;
  static const omitFirstBarLine = 8;
}

/// One line of `[TimingPoints]`.
///
/// Uninherited ("red") points define BPM via [beatLength] (ms per beat).
/// Inherited ("green") points have a negative [beatLength] encoding a slider
/// velocity multiplier: `sv = -100 / beatLength`.
///
/// Immutable with identity equality, same rationale as `HitObject`.
class TimingPoint {
  final double time;
  final double beatLength;
  final int meter;
  final int sampleSet;
  final int sampleIndex;
  final int volume;
  final bool uninherited;
  final int effects;
  final String? sourceLine;

  const TimingPoint({
    required this.time,
    required this.beatLength,
    this.meter = 4,
    this.sampleSet = 0,
    this.sampleIndex = 0,
    this.volume = 100,
    this.uninherited = true,
    this.effects = 0,
    this.sourceLine,
  });

  factory TimingPoint.red({
    required double time,
    required double bpm,
    int meter = 4,
    int sampleSet = 1,
    int volume = 100,
  }) =>
      TimingPoint(
        time: time,
        beatLength: 60000 / bpm,
        meter: meter,
        sampleSet: sampleSet,
        volume: volume,
      );

  factory TimingPoint.green({
    required double time,
    required double sliderVelocity,
    int sampleSet = 1,
    int volume = 100,
  }) =>
      TimingPoint(
        time: time,
        beatLength: -100 / sliderVelocity,
        meter: 4,
        sampleSet: sampleSet,
        volume: volume,
        uninherited: false,
      );

  bool get inherited => !uninherited;
  bool get kiai => effects & TimingEffects.kiai != 0;

  double get bpm => uninherited && beatLength > 0 ? 60000 / beatLength : 0;

  /// Slider velocity multiplier, clamped like osu!stable (0.1x – 10x).
  double get sliderVelocity {
    if (uninherited) return 1;
    if (beatLength.isNaN || beatLength >= 0) return 1;
    return (-100 / beatLength).clamp(0.1, 10.0);
  }

  TimingPoint copyWith({
    double? time,
    double? beatLength,
    int? meter,
    int? sampleSet,
    int? sampleIndex,
    int? volume,
    bool? uninherited,
    int? effects,
  }) =>
      TimingPoint(
        time: time ?? this.time,
        beatLength: beatLength ?? this.beatLength,
        meter: meter ?? this.meter,
        sampleSet: sampleSet ?? this.sampleSet,
        sampleIndex: sampleIndex ?? this.sampleIndex,
        volume: volume ?? this.volume,
        uninherited: uninherited ?? this.uninherited,
        effects: effects ?? this.effects,
      );
}
