import '../model/beatmap.dart';
import '../model/hit_object.dart';
import '../timing/timing_info.dart';
import 'hitsounds.dart';

/// One point where an object sounds (a circle, each slider edge — head,
/// repeats, tail — or a spinner's end), resolved for the Hitsound screen's
/// layers: which sample sets play, whether each came from the object or
/// was inherited (timing point / map default), and the additions.
class HitsoundNote {
  final double time;
  final HitObject object;

  /// The slider edge (0 = head, then repeats, last = tail); 0 otherwise.
  final int edge;

  /// Sample set of the normal sound (1 normal, 2 soft, 3 drum).
  final int normalSet;

  /// Whether [normalSet] comes from the timing point / map default rather
  /// than the object (or the slider edge).
  final bool normalInherited;

  /// Sample set of the additions (whistle / finish / clap).
  final int additionSet;

  /// Whether [additionSet] follows [normalSet] (not set on the object).
  final bool additionInherited;

  /// [HitSoundFlags] whistle / finish / clap bits (the normal bit is ignored:
  /// the normal sound always plays).
  final int additions;

  /// 0–100, from the object or the timing point.
  final int volume;

  /// Whether [volume] comes from the timing point (the object sets none).
  final bool volumeInherited;

  /// Custom sample index: 0 = built-in samples, 1 = the beatmap's files
  /// without a number, n = files numbered n (`soft-hitclap2.wav`).
  final int index;

  /// Whether [index] comes from the timing point.
  final bool indexInherited;

  /// A custom sample file replaces every sound of the object: only it
  /// plays (no additions).
  final String filename;

  const HitsoundNote({
    required this.time,
    required this.object,
    this.edge = 0,
    required this.normalSet,
    required this.normalInherited,
    required this.additionSet,
    required this.additionInherited,
    required this.additions,
    required this.volume,
    this.volumeInherited = false,
    this.index = 0,
    this.indexInherited = false,
    this.filename = '',
  });

  bool get whistle => additions & HitSoundFlags.whistle != 0;
  bool get finish => additions & HitSoundFlags.finish != 0;
  bool get clap => additions & HitSoundFlags.clap != 0;
  bool get hasAdditions => additions & _additionBits != 0;

  static const _additionBits = HitSoundFlags.whistle | HitSoundFlags.finish | HitSoundFlags.clap;
}

/// A slider's body sound on the Hitsound screen: `sliderslide` in
/// [normalSet] while the ball rolls, plus `sliderwhistle` in [additionSet]
/// when the slider has whistle (its own hitsound, not an edge's).
class HitsoundBody {
  final SliderObject slider;
  final double start;
  final double end;
  final int normalSet;
  final bool normalInherited;
  final int additionSet;
  final bool additionInherited;
  final bool whistle;

  /// The volume at the head (object or timing point) and, when the slider
  /// sets none, the timing points inside the body that change it.
  final int volume;
  final bool volumeInherited;
  final List<(double, int)> volumeChanges;

  const HitsoundBody({
    required this.slider,
    required this.start,
    required this.end,
    required this.normalSet,
    required this.normalInherited,
    required this.additionSet,
    required this.additionInherited,
    required this.whistle,
    this.volume = 100,
    this.volumeInherited = false,
    this.volumeChanges = const [],
  });

  /// The volume at [t] inside the body.
  int volumeAt(double t) {
    var v = volume;
    for (final (time, volume) in volumeChanges) {
      if (time > t) break;
      v = volume;
    }
    return v;
  }
}

/// A slider tick (`slidertick` in the slider's normal set, or the timing
/// point's at the tick).
class HitsoundTick {
  final double time;
  final SliderObject slider;
  final int set;
  final bool setInherited;
  final int volume;

  const HitsoundTick({
    required this.time,
    required this.slider,
    required this.set,
    required this.setInherited,
    required this.volume,
  });
}

/// The notes of the Hitsound screen, resolved like [HitsoundResolver] (same
/// timing point lookup and inheritance) but one entry per sounding point.
abstract final class HitsoundLayers {
  /// lazer looks the sample point up slightly after the object time.
  static const _sampleLeniency = 5.0;

  /// All notes, sorted by time (objects in map order at the same time).
  static List<HitsoundNote> notes(Beatmap beatmap, TimingInfo timing) {
    final defaultSet = beatmap.defaultSampleSet == 0 ? SampleSet.normal : beatmap.defaultSampleSet;
    final sm = beatmap.sliderMultiplier;
    final out = <HitsoundNote>[];

    void add(HitObject h, double time, int edge, int sounds, int normalSet, int additionSet) {
      final s = HitsoundResolver.objectSample(h);
      final tp = timing.effectivePointAt(time + _sampleLeniency);
      final pointSet = tp == null || tp.sampleSet == 0 ? defaultSet : tp.sampleSet;
      final normal = normalSet != 0 ? normalSet : pointSet;
      out.add(HitsoundNote(
        time: time,
        object: h,
        edge: edge,
        normalSet: normal,
        normalInherited: normalSet == 0,
        additionSet: additionSet != 0 ? additionSet : normal,
        additionInherited: additionSet == 0,
        additions: sounds & HitsoundNote._additionBits,
        volume: (s.volume != 0 ? s.volume : (tp?.volume ?? 100)).clamp(0, 100),
        volumeInherited: s.volume == 0,
        index: s.index != 0 ? s.index : (tp?.sampleIndex ?? 0),
        indexInherited: s.index == 0,
        filename: s.filename,
      ));
    }

    for (final h in beatmap.hitObjects) {
      final s = h.sample;
      switch (h) {
        case SliderObject():
          final span = timing.sliderSpanDuration(h, sm);
          for (var i = 0; i <= h.slides; i++) {
            final sound = h.edgeSounds != null && i < h.edgeSounds!.length ? h.edgeSounds![i] : h.hitSound;
            final (n, a) = HitsoundResolver.edgeSets(h, i);
            add(h, h.time + span * i, i, sound, n, a);
          }
        case Spinner():
          add(h, timing.endTimeOf(h, sm), 0, h.hitSound, s.normalSet, s.additionSet);
        default:
          add(h, h.time, 0, h.hitSound, s.normalSet, s.additionSet);
      }
    }
    // Stable sort: same-time notes keep map order.
    final indexed = [for (var i = 0; i < out.length; i++) (i, out[i])];
    indexed.sort((a, b) {
      final c = a.$2.time.compareTo(b.$2.time);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  /// Slider body sounds, in map order, resolved like
  /// [HitsoundResolver.resolveBodies] (sets from the slider, index and
  /// volume from the timing point at its head).
  static List<HitsoundBody> bodies(Beatmap beatmap, TimingInfo timing) {
    final defaultSet = beatmap.defaultSampleSet == 0 ? SampleSet.normal : beatmap.defaultSampleSet;
    final sm = beatmap.sliderMultiplier;
    final out = <HitsoundBody>[];
    for (final h in beatmap.hitObjects) {
      if (h is! SliderObject) continue;
      final end = timing.sliderEndTime(h, sm);
      final s = HitsoundResolver.objectSample(h);
      if (end <= h.time) continue;
      final tp = timing.effectivePointAt(h.time + _sampleLeniency);
      final pointSet = tp == null || tp.sampleSet == 0 ? defaultSet : tp.sampleSet;
      final normal = s.normalSet != 0 ? s.normalSet : pointSet;
      final volume = (s.volume != 0 ? s.volume : (tp?.volume ?? 100)).clamp(0, 100);
      final changes = <(double, int)>[];
      if (s.volume == 0) {
        var last = volume;
        for (final p in timing.points) {
          if (p.time <= h.time + _sampleLeniency) continue;
          if (p.time >= end) break;
          final v = (timing.effectivePointAt(p.time)?.volume ?? 100).clamp(0, 100);
          if (v != last) changes.add((p.time, last = v));
        }
      }
      out.add(HitsoundBody(
        slider: h,
        start: h.time,
        end: end,
        normalSet: normal,
        normalInherited: s.normalSet == 0,
        additionSet: s.additionSet != 0 ? s.additionSet : normal,
        additionInherited: s.additionSet == 0,
        whistle: h.hitSound & HitSoundFlags.whistle != 0,
        volume: volume,
        volumeInherited: s.volume == 0,
        volumeChanges: changes,
      ));
    }
    return out;
  }

  /// Slider ticks, sorted by time, as [HitsoundResolver.resolve] plays them.
  static List<HitsoundTick> ticks(Beatmap beatmap, TimingInfo timing) {
    final defaultSet = beatmap.defaultSampleSet == 0 ? SampleSet.normal : beatmap.defaultSampleSet;
    final sm = beatmap.sliderMultiplier;
    final out = <HitsoundTick>[];
    for (final h in beatmap.hitObjects) {
      if (h is! SliderObject) continue;
      final length = TimingInfo.sliderDistance(h);
      if (length <= 0) continue;
      final s = HitsoundResolver.objectSample(h);
      final distances = timing.sliderTickDistances(h, sm, beatmap.sliderTickRate, formatVersion: beatmap.formatVersion);
      if (distances.isEmpty) continue;
      final span = timing.sliderSpanDuration(h, sm);
      for (var i = 0; i < h.slides; i++) {
        final start = h.time + span * i;
        for (final d in distances) {
          final along = i.isEven ? d : length - d;
          final time = start + span * along / length;
          final tp = timing.effectivePointAt(time + _sampleLeniency);
          final pointSet = tp == null || tp.sampleSet == 0 ? defaultSet : tp.sampleSet;
          out.add(HitsoundTick(
            time: time,
            slider: h,
            set: s.normalSet != 0 ? s.normalSet : pointSet,
            setInherited: s.normalSet == 0,
            volume: (s.volume != 0 ? s.volume : (tp?.volume ?? 100)).clamp(0, 100),
          ));
        }
      }
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }
}
