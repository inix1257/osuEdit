import '../model/beatmap.dart';
import '../model/hit_object.dart';
import '../model/timing_point.dart';
import '../timing/timing_info.dart';
import 'commands.dart';

/// Copying hitsounds from one difficulty to another of the same set, like
/// Mapping Tools' "Hitsound copier": every sounding moment of the target
/// (a circle, a slider's head / repeats / tail, a spinner's end) takes the
/// additions and sample sets of the source's sound at the same time (within
/// a leniency), and the timing points are given the source's sample set,
/// custom index and volume so both difficulties sound the same.
abstract final class HitsoundCopyOps {
  static const defaultLeniency = 5.0;

  /// The command that makes [target] sound like [source] (both parsed
  /// maps of one set), or null if nothing would change.
  ///
  /// * Objects: each target sound takes the nearest source sound within
  ///   [leniency] ms: its additions and sample sets, and for circles and
  ///   spinners the custom index, volume and file too (a slider's own index
  ///   / volume / file aren't used by osu!: its edges take the timing
  ///   point's). A slider starting with a source slider also takes its
  ///   body sound (sliderwhistle and body sample sets). With
  ///   [clearUnmatched], target sounds with no source sound are reset to
  ///   no additions and automatic sets; otherwise they are left alone.
  /// * With [samplePoints], every target timing point takes the source's
  ///   sample set, custom index and volume in effect at its time, and an
  ///   inherited point (same slider velocity and kiai as the target had
  ///   there) is added wherever the source changes them and the target has
  ///   no point. The target's timing, slider velocity and kiai don't change.
  static EditCommand? copy({
    required Beatmap source,
    required Beatmap target,
    double leniency = defaultLeniency,
    bool samplePoints = true,
    bool clearUnmatched = false,
  }) {
    final srcTiming = TimingInfo.of(source), tgtTiming = TimingInfo.of(target);
    final sounds = _soundsOf(source, srcTiming)..sort((a, b) => a.time.compareTo(b.time));
    final bodies = [for (final h in source.hitObjects) if (h is SliderObject) h];

    _Sound? at(double t) {
      // Binary search for the first sound at or after t − leniency.
      var lo = 0, hi = sounds.length;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (sounds[mid].time < t - leniency) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      _Sound? best;
      for (var i = lo; i < sounds.length && sounds[i].time <= t + leniency; i++) {
        if (best == null || (sounds[i].time - t).abs() < (best.time - t).abs()) best = sounds[i];
      }
      return best;
    }

    final before = <HitObject>[], after = <HitObject>[];
    final sm = target.sliderMultiplier;
    for (final h in target.hitObjects) {
      final next = switch (h) {
        SliderObject() => _slider(h, tgtTiming.sliderSpanDuration(h, sm), at, bodies, leniency, clearUnmatched),
        Spinner() => _single(h, at(h.endTime), clearUnmatched),
        HoldNote() => null,
        _ => _single(h, at(h.time), clearUnmatched),
      };
      if (next == null) continue;
      before.add(h);
      after.add(next);
    }

    final commands = <EditCommand>[
      if (before.isNotEmpty) ReplaceHitObjectsCommand(before, after, label: 'Copy hitsounds'),
      if (samplePoints) ..._samplePointCommands(source, srcTiming, target, tgtTiming),
    ];
    return commands.isEmpty ? null : CompositeCommand('Copy hitsounds', commands);
  }

  static List<_Sound> _soundsOf(Beatmap b, TimingInfo timing) {
    final out = <_Sound>[];
    for (final h in b.hitObjects) {
      switch (h) {
        case SliderObject():
          final span = timing.sliderSpanDuration(h, b.sliderMultiplier);
          for (var k = 0; k <= h.slides; k++) {
            final sounds = h.edgeSounds, sets = h.edgeSets;
            final set = sets != null && k < sets.length ? sets[k] : null;
            out.add(_Sound(
              h.time + span * k,
              sounds != null && k < sounds.length ? sounds[k] : h.hitSound,
              HitSample(
                normalSet: set?.normalSet ?? h.sample.normalSet,
                additionSet: set?.additionSet ?? h.sample.additionSet,
              ),
            ));
          }
        case Spinner():
          out.add(_Sound(h.endTime, h.hitSound, h.sample));
        case HoldNote():
          break;
        default:
          out.add(_Sound(h.time, h.hitSound, h.sample));
      }
    }
    return out;
  }

  /// A circle or spinner with [match]'s sound, or null if unchanged.
  static HitObject? _single(HitObject h, _Sound? match, bool clearUnmatched) {
    if (match == null && !clearUnmatched) return null;
    final hitSound = match?.hitSound ?? 0;
    final sample = match?.sample ?? HitSample.empty;
    if (h.hitSound == hitSound && h.sample == sample) return null;
    return h.copyWithBase(hitSound: hitSound, sample: sample);
  }

  static SliderObject? _slider(SliderObject s, double span, _Sound? Function(double) at, List<SliderObject> bodies,
      double leniency, bool clearUnmatched) {
    final edgeSounds = <int>[], edgeSets = <EdgeSet>[];
    var touched = false;
    for (var k = 0; k <= s.slides; k++) {
      final m = at(s.time + span * k);
      final oldSound = s.edgeSounds != null && k < s.edgeSounds!.length ? s.edgeSounds![k] : s.hitSound;
      final oldSet = s.edgeSets != null && k < s.edgeSets!.length
          ? s.edgeSets![k]
          : EdgeSet(s.sample.normalSet, s.sample.additionSet);
      if (m != null) {
        edgeSounds.add(m.hitSound);
        edgeSets.add(EdgeSet(m.sample.normalSet, m.sample.additionSet));
        touched = true;
      } else if (clearUnmatched) {
        edgeSounds.add(0);
        edgeSets.add(const EdgeSet(0, 0));
        touched = true;
      } else {
        edgeSounds.add(oldSound);
        edgeSets.add(oldSet);
      }
    }

    // The body: from a source slider starting at the same time.
    var hitSound = s.hitSound;
    var sample = s.sample;
    SliderObject? body;
    for (final b in bodies) {
      if ((b.time - s.time).abs() <= leniency) {
        body = b;
        break;
      }
    }
    if (body != null) {
      hitSound = body.hitSound;
      sample = HitSample(
        normalSet: body.sample.normalSet,
        additionSet: body.sample.additionSet,
        index: s.sample.index,
        volume: s.sample.volume,
        filename: s.sample.filename,
      );
    } else if (clearUnmatched) {
      hitSound = 0;
      sample = HitSample(index: s.sample.index, volume: s.sample.volume, filename: s.sample.filename);
    }

    final sameEdges = _listEq(edgeSounds, _edgeSoundsOf(s)) && _listEq(edgeSets, _edgeSetsOf(s));
    if (!touched && body == null) return null;
    if (sameEdges && hitSound == s.hitSound && sample == s.sample) return null;
    return s.copyWith(hitSound: hitSound, sample: sample, edgeSounds: edgeSounds, edgeSets: edgeSets);
  }

  static List<int> _edgeSoundsOf(SliderObject s) => [
        for (var k = 0; k <= s.slides; k++)
          s.edgeSounds != null && k < s.edgeSounds!.length ? s.edgeSounds![k] : s.hitSound,
      ];

  static List<EdgeSet> _edgeSetsOf(SliderObject s) => [
        for (var k = 0; k <= s.slides; k++)
          s.edgeSets != null && k < s.edgeSets!.length ? s.edgeSets![k] : EdgeSet(s.sample.normalSet, s.sample.additionSet),
      ];

  /// Whether the slider's stored edge lists already say exactly this (a
  /// slider without the fields counts as listing its own sound / sets).
  static bool _listEq<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static List<EditCommand> _samplePointCommands(
      Beatmap source, TimingInfo srcTiming, Beatmap target, TimingInfo tgtTiming) {
    if (source.timingPoints.isEmpty || target.timingPoints.isEmpty) return const [];
    final out = <EditCommand>[];
    final targetTimes = <double>{};
    for (final p in target.timingPoints) {
      targetTimes.add(p.time);
      final e = srcTiming.effectivePointAt(p.time)!;
      if (p.sampleSet == e.sampleSet && p.sampleIndex == e.sampleIndex && p.volume == e.volume) continue;
      out.add(ReplaceTimingPointCommand(p, _withSample(p, e)));
    }
    final times = targetTimes.toList()..sort();
    for (final t in {for (final p in source.timingPoints) p.time}) {
      if (targetTimes.contains(t) || t < times.first) continue;
      final e = srcTiming.effectivePointAt(t)!;
      // After the replacements above, the target has here what the source
      // has at its previous point's time: only a change needs a point.
      final previous = times.lastWhere((x) => x < t);
      final was = srcTiming.effectivePointAt(previous)!;
      if (was.sampleSet == e.sampleSet && was.sampleIndex == e.sampleIndex && was.volume == e.volume) continue;
      final here = tgtTiming.effectivePointAt(t)!;
      out.add(AddTimingPointCommand(TimingPoint(
        time: t,
        beatLength: here.uninherited ? -100 : here.beatLength,
        meter: here.meter,
        sampleSet: e.sampleSet,
        sampleIndex: e.sampleIndex,
        volume: e.volume,
        uninherited: false,
        effects: here.effects & TimingEffects.kiai,
      )));
    }
    return out;
  }

  static TimingPoint _withSample(TimingPoint p, TimingPoint from) => TimingPoint(
        time: p.time,
        beatLength: p.beatLength,
        meter: p.meter,
        sampleSet: from.sampleSet,
        sampleIndex: from.sampleIndex,
        volume: from.volume,
        uninherited: p.uninherited,
        effects: p.effects,
      );
}

class _Sound {
  final double time;
  final int hitSound;
  final HitSample sample;
  const _Sound(this.time, this.hitSound, this.sample);
}
