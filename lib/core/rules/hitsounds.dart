import '../model/beatmap.dart';
import '../model/hit_object.dart';
import '../timing/timing_info.dart';

/// One sample to play at [time] (ms).
class SamplePlay {
  final double time;

  /// `normal`, `soft` or `drum`.
  final String bank;

  /// `hitnormal`, `hitwhistle`, `hitfinish`, `hitclap` or `slidertick`.
  final String name;

  /// Custom sample index: 0 = built-in only, 1 = beatmap file without
  /// suffix, n > 1 = beatmap file with suffix n.
  final int index;

  /// 0–100.
  final int volume;

  /// Explicit file from the hit sample field; replaces all other sounds of
  /// the object when set.
  final String? filename;

  const SamplePlay({
    required this.time,
    required this.bank,
    required this.name,
    this.index = 0,
    this.volume = 100,
    this.filename,
  });

  /// Beatmap-folder file name without extension, e.g. `soft-hitclap2`.
  /// Null when only the built-in sample applies.
  String? get customStem {
    if (filename != null) return null;
    if (index <= 0) return null;
    return '$bank-$name${index == 1 ? '' : index}';
  }

  @override
  String toString() => 'SamplePlay($time, $bank-$name, i$index, v$volume${filename == null ? '' : ', $filename'})';
}

/// A sample looped while a slider's ball rolls: `sliderslide` (normal bank)
/// and, if the slider's body has whistle, `sliderwhistle` (addition bank).
class SliderBodySound {
  final double start;
  final double end;

  /// The looped sample ([SamplePlay.time] == [start]).
  final SamplePlay sample;

  /// Volume changes inside the body, in time order: timing points between
  /// [start] and [end] that give another volume (only when the slider
  /// doesn't set its own). osu! follows them while the ball rolls.
  final List<(double, int)> volumeChanges;

  const SliderBodySound(this.start, this.end, this.sample, [this.volumeChanges = const []]);

  /// The volume (0–100) at time [t] of the body.
  int volumeAt(double t) {
    var v = sample.volume;
    for (final (time, volume) in volumeChanges) {
      if (time > t) break;
      v = volume;
    }
    return v;
  }

  @override
  String toString() => 'SliderBodySound($start–$end, ${sample.bank}-${sample.name})';
}

/// Expands hit objects into the samples osu! would play (osu!standard
/// rules, matching lazer: the normal sound always plays; whistle / finish /
/// clap use the addition bank; slider edges use `edgeSounds` / `edgeSets`;
/// spinners sound at their end).
///
/// Slider ticks play `slidertick` from the slider's normal bank. Slider
/// body loops come from [resolveBodies].
abstract final class HitsoundResolver {
  /// lazer looks the sample point up slightly after the object time so a
  /// green line placed a hair late still applies.
  static const _sampleLeniency = 5.0;

  /// The part of [h]'s own sample (`hitSample` field) osu! uses: all of it,
  /// except for sliders only the sets — a slider's index, volume and file
  /// are ignored, its sounds take the timing point's (lazer
  /// `ConvertHitObjectParser`: `readCustomSampleBanks(…, banksOnly: true)`).
  static HitSample objectSample(HitObject h) {
    final s = h.sample;
    return h is SliderObject ? HitSample(normalSet: s.normalSet, additionSet: s.additionSet) : s;
  }

  /// The sets an edge of [s] sounds with, before falling back to the timing
  /// point: a listed edge set as written (0 = the timing point's set), an
  /// unlisted edge the slider's own sets (lazer: field 9 is read over a copy
  /// of field 10's banks).
  static (int, int) edgeSets(SliderObject s, int edge) {
    final sets = s.edgeSets;
    if (sets != null && edge < sets.length) return (sets[edge].normalSet, sets[edge].additionSet);
    return (s.sample.normalSet, s.sample.additionSet);
  }

  static String bankName(int set) => switch (set) {
        2 => 'soft',
        3 => 'drum',
        _ => 'normal',
      };

  /// Slider body loops, sorted by start time. Sets come from the slider's
  /// sample, index and volume from the timing point at its start (stable
  /// doesn't follow later green lines inside the body either; a slider's own
  /// index / volume / file don't count, [objectSample]).
  static List<SliderBodySound> resolveBodies(Beatmap beatmap, TimingInfo timing) {
    final defaultSet = beatmap.defaultSampleSet == 0 ? 1 : beatmap.defaultSampleSet;
    final sm = beatmap.sliderMultiplier;
    final out = <SliderBodySound>[];
    for (final h in beatmap.hitObjects) {
      if (h is! SliderObject) continue;
      final end = timing.sliderEndTime(h, sm);
      if (end <= h.time) continue;
      final s = objectSample(h);
      final tp = timing.effectivePointAt(h.time + _sampleLeniency);
      final pointSet = tp == null || tp.sampleSet == 0 ? defaultSet : tp.sampleSet;
      final normal = s.normalSet != 0 ? s.normalSet : pointSet;
      final addition = s.additionSet != 0 ? s.additionSet : normal;
      final index = s.index != 0 ? s.index : (tp?.sampleIndex ?? 0);
      final volume = (s.volume != 0 ? s.volume : (tp?.volume ?? 100)).clamp(0, 100);
      SamplePlay loop(int set, String name) =>
          SamplePlay(time: h.time, bank: bankName(set), name: name, index: index, volume: volume);
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
      out.add(SliderBodySound(h.time, end, loop(normal, 'sliderslide'), changes));
      if (h.hitSound & HitSoundFlags.whistle != 0) {
        out.add(SliderBodySound(h.time, end, loop(addition, 'sliderwhistle'), changes));
      }
    }
    return out;
  }

  /// All samples, sorted by time.
  static List<SamplePlay> resolve(Beatmap beatmap, TimingInfo timing) {
    final defaultSet = beatmap.defaultSampleSet == 0 ? 1 : beatmap.defaultSampleSet;
    final out = <SamplePlay>[];

    void emit(double time, int sounds, int normalSet, int additionSet, HitSample s) {
      final tp = timing.effectivePointAt(time + _sampleLeniency);
      final pointSet = tp == null || tp.sampleSet == 0 ? defaultSet : tp.sampleSet;
      final normal = normalSet != 0 ? normalSet : pointSet;
      final addition = additionSet != 0 ? additionSet : normal;
      final index = s.index != 0 ? s.index : (tp?.sampleIndex ?? 0);
      final volume = (s.volume != 0 ? s.volume : (tp?.volume ?? 100)).clamp(0, 100);
      if (s.filename.isNotEmpty) {
        out.add(SamplePlay(
            time: time, bank: bankName(normal), name: 'hitnormal', volume: volume, filename: s.filename));
        return;
      }
      SamplePlay play(int set, String name) =>
          SamplePlay(time: time, bank: bankName(set), name: name, index: index, volume: volume);
      out.add(play(normal, 'hitnormal'));
      if (sounds & HitSoundFlags.whistle != 0) out.add(play(addition, 'hitwhistle'));
      if (sounds & HitSoundFlags.finish != 0) out.add(play(addition, 'hitfinish'));
      if (sounds & HitSoundFlags.clap != 0) out.add(play(addition, 'hitclap'));
    }

    void emitTick(double time, int objectNormalSet, HitSample s) {
      final tp = timing.effectivePointAt(time + _sampleLeniency);
      final pointSet = tp == null || tp.sampleSet == 0 ? defaultSet : tp.sampleSet;
      final normal = objectNormalSet != 0 ? objectNormalSet : pointSet;
      final index = s.index != 0 ? s.index : (tp?.sampleIndex ?? 0);
      final volume = (s.volume != 0 ? s.volume : (tp?.volume ?? 100)).clamp(0, 100);
      out.add(SamplePlay(time: time, bank: bankName(normal), name: 'slidertick', index: index, volume: volume));
    }

    final sm = beatmap.sliderMultiplier;
    final tickRate = beatmap.sliderTickRate;
    for (final h in beatmap.hitObjects) {
      final s = objectSample(h);
      switch (h) {
        case SliderObject():
          final span = timing.sliderSpanDuration(h, sm);
          for (var i = 0; i <= h.slides; i++) {
            final edgeSound = h.edgeSounds != null && i < h.edgeSounds!.length ? h.edgeSounds![i] : h.hitSound;
            final (n, a) = edgeSets(h, i);
            emit(h.time + span * i, edgeSound, n, a, s);
          }
          final ticks = timing.sliderTickDistances(h, sm, tickRate, formatVersion: beatmap.formatVersion);
          final length = TimingInfo.sliderDistance(h);
          if (ticks.isNotEmpty && length > 0) {
            for (var i = 0; i < h.slides; i++) {
              final start = h.time + span * i;
              for (final d in ticks) {
                final along = i.isEven ? d : length - d;
                emitTick(start + span * along / length, s.normalSet, s);
              }
            }
          }
        case Spinner():
          emit(h.endTime, h.hitSound, s.normalSet, s.additionSet, s);
        default:
          emit(h.time, h.hitSound, s.normalSet, s.additionSet, s);
      }
    }
    // Stable sort keeps per-object order (normal before additions).
    final indexed = [for (var i = 0; i < out.length; i++) (i, out[i])];
    indexed.sort((a, b) {
      final c = a.$2.time.compareTo(b.$2.time);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }
}
