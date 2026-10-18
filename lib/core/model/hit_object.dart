import '../math/vec2.dart';

/// Bit flags of the `type` field in `[HitObjects]`.
abstract final class HitObjectType {
  static const circle = 1;
  static const slider = 2;
  static const newCombo = 4;
  static const spinner = 8;
  static const comboSkipMask = 0x70; // bits 4-6
  static const comboSkipShift = 4;
  static const maniaHold = 128;
}

/// Bit flags of the `hitSound` field.
abstract final class HitSoundFlags {
  static const normal = 1;
  static const whistle = 2;
  static const finish = 4;
  static const clap = 8;
}

/// Sample set ids used by hit samples and timing points.
/// 0 = auto/inherit, 1 = normal, 2 = soft, 3 = drum.
abstract final class SampleSet {
  static const auto = 0;
  static const normal = 1;
  static const soft = 2;
  static const drum = 3;

  static String name(int id) => switch (id) {
        normal => 'Normal',
        soft => 'Soft',
        drum => 'Drum',
        _ => 'None',
      };

  static int parse(String s) => switch (s.trim().toLowerCase()) {
        'normal' => normal,
        'soft' => soft,
        'drum' => drum,
        _ => auto,
      };
}

/// The trailing `normalSet:additionSet:index:volume:filename` field.
class HitSample {
  final int normalSet;
  final int additionSet;
  final int index;
  final int volume;
  final String filename;

  const HitSample({
    this.normalSet = 0,
    this.additionSet = 0,
    this.index = 0,
    this.volume = 0,
    this.filename = '',
  });

  static const empty = HitSample();

  bool get isDefault =>
      normalSet == 0 &&
      additionSet == 0 &&
      index == 0 &&
      volume == 0 &&
      filename.isEmpty;

  /// Parses `0:0:0:0:` (missing trailing parts default to 0 / empty).
  factory HitSample.parse(String s) {
    final p = s.split(':');
    int at(int i) => i < p.length ? (int.tryParse(p[i].trim()) ?? 0) : 0;
    return HitSample(
      normalSet: at(0),
      additionSet: at(1),
      index: at(2),
      volume: at(3),
      filename: p.length > 4 ? p.sublist(4).join(':') : '',
    );
  }

  String encode() => '$normalSet:$additionSet:$index:$volume:$filename';

  @override
  bool operator ==(Object other) =>
      other is HitSample &&
      other.normalSet == normalSet &&
      other.additionSet == additionSet &&
      other.index == index &&
      other.volume == volume &&
      other.filename == filename;

  @override
  int get hashCode =>
      Object.hash(normalSet, additionSet, index, volume, filename);
}

/// Base of all hit objects.
///
/// Hit objects are **immutable** and use **identity equality** on purpose:
/// the editor's selection is a `Set<HitObject>` and edits replace instances
/// (see `ReplaceHitObjectsCommand`).
///
/// [sourceLine] holds the exact text the object was parsed from. The writer
/// re-emits it verbatim for untouched objects so that saving a map never
/// introduces diffs in lines the user didn't edit. Every `copyWith` drops it.
sealed class HitObject {
  final Vec2 position;

  /// Start time in ms. Stored as double (snapped times are fractional);
  /// written to file rounded to int, like osu! does.
  final double time;
  final bool newCombo;

  /// Number of combo colours to skip (0-7) when [newCombo] is set.
  final int comboSkip;
  final int hitSound;
  final HitSample sample;
  final String? sourceLine;

  const HitObject({
    required this.position,
    required this.time,
    this.newCombo = false,
    this.comboSkip = 0,
    this.hitSound = 0,
    this.sample = HitSample.empty,
    this.sourceLine,
  });

  /// End time in ms. For sliders this needs timing information, so it is
  /// computed by `BeatmapGeometry`/`SliderInfo`, not here.
  double get endTimeIfKnown => time;

  int get typeBits;

  int get encodedType =>
      typeBits |
      (newCombo ? HitObjectType.newCombo : 0) |
      ((comboSkip & 7) << HitObjectType.comboSkipShift);

  HitObject copyWithBase({
    Vec2? position,
    double? time,
    bool? newCombo,
    int? comboSkip,
    int? hitSound,
    HitSample? sample,
  });

  /// Moves the object (and for sliders, its whole path) by [delta].
  HitObject translated(Vec2 delta) =>
      copyWithBase(position: position + delta);

  HitObject shiftedInTime(double deltaMs) =>
      copyWithBase(time: time + deltaMs);

  /// The object with every position (the head and, for sliders, the whole
  /// path) mapped by [f]: flips, rotations.
  HitObject transformed(Vec2 Function(Vec2) f) =>
      copyWithBase(position: f(position));
}

class HitCircle extends HitObject {
  const HitCircle({
    required super.position,
    required super.time,
    super.newCombo,
    super.comboSkip,
    super.hitSound,
    super.sample,
    super.sourceLine,
  });

  @override
  int get typeBits => HitObjectType.circle;

  @override
  HitCircle copyWithBase({
    Vec2? position,
    double? time,
    bool? newCombo,
    int? comboSkip,
    int? hitSound,
    HitSample? sample,
  }) =>
      HitCircle(
        position: position ?? this.position,
        time: time ?? this.time,
        newCombo: newCombo ?? this.newCombo,
        comboSkip: comboSkip ?? this.comboSkip,
        hitSound: hitSound ?? this.hitSound,
        sample: sample ?? this.sample,
      );
}

/// Curve type letter of a slider path.
enum CurveType {
  bezier('B'),
  catmull('C'),
  linear('L'),
  perfectCircle('P');

  final String letter;
  const CurveType(this.letter);

  static CurveType fromLetter(String s) => switch (s.trim().toUpperCase()) {
        'C' => catmull,
        'L' => linear,
        'P' => perfectCircle,
        _ => bezier,
      };
}

/// The curve type of one segment of a slider path in osu!lazer's model
/// (lazer `PathType`): a [kind], plus a [degree] for lazer's B-splines
/// (`B4` in the file; [kind] is then [CurveType.bezier]). A value type.
class PathType {
  final CurveType kind;

  /// B-spline degree, or null (plain bezier / any other kind).
  final int? degree;

  const PathType(this.kind, [this.degree]);

  static const linear = PathType(CurveType.linear);
  static const bezier = PathType(CurveType.bezier);
  static const perfectCurve = PathType(CurveType.perfectCircle);
  static const catmull = PathType(CurveType.catmull);

  /// lazer's default B-spline (its editor's "B-Spline" choice).
  static const bSpline4 = PathType(CurveType.bezier, 4);

  bool get isBSpline => degree != null;

  /// The token in a slider's curve field: `B`, `B4`, `C`, `L`, `P`.
  String get code => degree != null ? 'B$degree' : kind.letter;

  /// lazer's reading of a type token (first letter; `B<n>` = B-spline of
  /// degree n; unknown letters are catmull, as in lazer).
  static PathType parse(String token) {
    final t = token.trim();
    switch (t.isEmpty ? '' : t[0].toUpperCase()) {
      case 'B':
        final d = t.length > 1 ? int.tryParse(t.substring(1)) : null;
        return d != null && d > 0 ? PathType(CurveType.bezier, d) : bezier;
      case 'L':
        return linear;
      case 'P':
        return perfectCurve;
      default:
        return catmull;
    }
  }

  /// Name as lazer's editor shows it.
  String get label => switch (kind) {
        CurveType.bezier => degree == null ? 'Bezier' : 'B-spline',
        CurveType.catmull => 'Catmull',
        CurveType.linear => 'Linear',
        CurveType.perfectCircle => 'Perfect curve',
      };

  @override
  bool operator ==(Object other) => other is PathType && other.kind == kind && other.degree == degree;

  @override
  int get hashCode => Object.hash(kind, degree);

  @override
  String toString() => code;
}

/// `normalSet:additionSet` pair used by slider edge sets.
class EdgeSet {
  final int normalSet;
  final int additionSet;
  const EdgeSet(this.normalSet, this.additionSet);

  @override
  bool operator ==(Object other) =>
      other is EdgeSet &&
      other.normalSet == normalSet &&
      other.additionSet == additionSet;

  @override
  int get hashCode => Object.hash(normalSet, additionSet);
}

/// A slider. Named `SliderObject` (not `Slider`) to avoid clashing with
/// Flutter's Material `Slider` widget in UI files.
class SliderObject extends HitObject {
  final CurveType curveType;

  /// Control points **after** the head (the head is [position]), in absolute
  /// osu!pixel coordinates, exactly as stored in the file. A point repeated
  /// twice in a row is a "red anchor" (segment boundary) for bezier paths.
  final List<Vec2> controlPoints;

  /// Number of spans (1 = no repeat). The file calls this `slides`.
  final int slides;

  /// Expected visual length in osu!pixels (`length` field).
  final double length;

  /// Per-edge hit sounds (`slides + 1` entries) or null if absent in file.
  final List<int>? edgeSounds;
  final List<EdgeSet>? edgeSets;

  /// osu!lazer path model, for sliders osu!stable can't express (several
  /// curve types in one path, B-splines): one entry per point of
  /// [allPoints]; a non-null entry starts a segment of that type, which runs
  /// to the next typed point (entry 0 is never null). Points are not
  /// doubled here. Null for an ordinary (stable-format) slider, whose path
  /// is [curveType] + [controlPoints] with doubled red anchors.
  final List<PathType?>? pointTypes;

  const SliderObject({
    required super.position,
    required super.time,
    required this.curveType,
    required this.controlPoints,
    this.slides = 1,
    required this.length,
    this.edgeSounds,
    this.edgeSets,
    this.pointTypes,
    super.newCombo,
    super.comboSkip,
    super.hitSound,
    super.sample,
    super.sourceLine,
  });

  @override
  int get typeBits => HitObjectType.slider;

  /// Whether the path is in osu!lazer's model ([pointTypes]).
  bool get isLazerPath => pointTypes != null;

  /// Head followed by all control points.
  List<Vec2> get allPoints => [position, ...controlPoints];

  @override
  SliderObject copyWithBase({
    Vec2? position,
    double? time,
    bool? newCombo,
    int? comboSkip,
    int? hitSound,
    HitSample? sample,
  }) =>
      copyWith(
        position: position,
        time: time,
        newCombo: newCombo,
        comboSkip: comboSkip,
        hitSound: hitSound,
        sample: sample,
      );

  /// [pointTypes] replaces the lazer path types; [stablePath] drops them
  /// (the result is a stable-format slider). Otherwise they are kept while
  /// the number of points stays the same.
  SliderObject copyWith({
    Vec2? position,
    double? time,
    CurveType? curveType,
    List<Vec2>? controlPoints,
    int? slides,
    double? length,
    List<int>? edgeSounds,
    List<EdgeSet>? edgeSets,
    List<PathType?>? pointTypes,
    bool stablePath = false,
    bool? newCombo,
    int? comboSkip,
    int? hitSound,
    HitSample? sample,
  }) =>
      SliderObject(
        position: position ?? this.position,
        time: time ?? this.time,
        curveType: curveType ?? this.curveType,
        controlPoints: controlPoints ?? this.controlPoints,
        slides: slides ?? this.slides,
        length: length ?? this.length,
        edgeSounds: edgeSounds ?? this.edgeSounds,
        edgeSets: edgeSets ?? this.edgeSets,
        pointTypes: stablePath
            ? null
            : pointTypes ??
                (controlPoints == null || controlPoints.length == this.controlPoints.length ? this.pointTypes : null),
        newCombo: newCombo ?? this.newCombo,
        comboSkip: comboSkip ?? this.comboSkip,
        hitSound: hitSound ?? this.hitSound,
        sample: sample ?? this.sample,
      );

  /// Moving a slider moves all of its control points with it.
  @override
  SliderObject translated(Vec2 delta) => copyWith(
        position: position + delta,
        controlPoints: [for (final p in controlPoints) p + delta],
      );

  @override
  SliderObject transformed(Vec2 Function(Vec2) f) => copyWith(
        position: f(position),
        controlPoints: [for (final p in controlPoints) f(p)],
      );
}

class Spinner extends HitObject {
  final double endTime;

  const Spinner({
    required super.position,
    required super.time,
    required this.endTime,
    super.newCombo,
    super.comboSkip,
    super.hitSound,
    super.sample,
    super.sourceLine,
  });

  static const center = Vec2(256, 192);

  @override
  double get endTimeIfKnown => endTime;

  @override
  int get typeBits => HitObjectType.spinner;

  @override
  Spinner copyWithBase({
    Vec2? position,
    double? time,
    bool? newCombo,
    int? comboSkip,
    int? hitSound,
    HitSample? sample,
  }) =>
      copyWith(
        position: position,
        time: time,
        newCombo: newCombo,
        comboSkip: comboSkip,
        hitSound: hitSound,
        sample: sample,
      );

  Spinner copyWith({
    Vec2? position,
    double? time,
    double? endTime,
    bool? newCombo,
    int? comboSkip,
    int? hitSound,
    HitSample? sample,
  }) =>
      Spinner(
        position: position ?? this.position,
        time: time ?? this.time,
        endTime: endTime ?? this.endTime,
        newCombo: newCombo ?? this.newCombo,
        comboSkip: comboSkip ?? this.comboSkip,
        hitSound: hitSound ?? this.hitSound,
        sample: sample ?? this.sample,
      );

  @override
  Spinner shiftedInTime(double deltaMs) =>
      copyWith(time: time + deltaMs, endTime: endTime + deltaMs);
}

/// osu!mania hold note. Only parsed/written so mania maps round-trip; the
/// editor UI currently targets osu!standard.
class HoldNote extends HitObject {
  final double endTime;

  const HoldNote({
    required super.position,
    required super.time,
    required this.endTime,
    super.newCombo,
    super.comboSkip,
    super.hitSound,
    super.sample,
    super.sourceLine,
  });

  @override
  double get endTimeIfKnown => endTime;

  @override
  int get typeBits => HitObjectType.maniaHold;

  @override
  HoldNote copyWithBase({
    Vec2? position,
    double? time,
    bool? newCombo,
    int? comboSkip,
    int? hitSound,
    HitSample? sample,
  }) =>
      HoldNote(
        position: position ?? this.position,
        time: time ?? this.time,
        endTime: endTime,
        newCombo: newCombo ?? this.newCombo,
        comboSkip: comboSkip ?? this.comboSkip,
        hitSound: hitSound ?? this.hitSound,
        sample: sample ?? this.sample,
      );

  @override
  HoldNote shiftedInTime(double deltaMs) => HoldNote(
        position: position,
        time: time + deltaMs,
        endTime: endTime + deltaMs,
        newCombo: newCombo,
        comboSkip: comboSkip,
        hitSound: hitSound,
        sample: sample,
      );
}
