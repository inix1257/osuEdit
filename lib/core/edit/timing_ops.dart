import '../model/beatmap.dart';
import '../model/hit_object.dart';
import '../model/timing_point.dart';
import 'commands.dart';

/// Timing changes that carry the map along (osu!stable's "move already
/// placed notes", lazer's `TimingSectionAdjustments`): when a red point's
/// offset or BPM changes, the objects and green points of its section keep
/// their place on its beat grid.
abstract final class TimingOps {
  /// One undoable command that replaces red point [before] with [after] and
  /// moves everything in its section — from [before] (from the start of the
  /// map for the first red point) up to the next red point — so that
  /// `t' = after.time + (t − before.time) × after.beatLength / before.beatLength`.
  /// Spinner / hold note ends move the same way; slider durations follow on
  /// their own (they scale with the beat length). Moved objects and green
  /// points land on whole ms (what osu! stores; the same rounding for both,
  /// so a green line and an object that were together stay together); what
  /// was at or after [before] stays at or after [after]. Null if [before] is not a red point of [b] or [after]
  /// has no valid beat length.
  static CompositeCommand? retimeSection(Beatmap b, TimingPoint before, TimingPoint after) {
    final reds = [for (final p in b.timingPoints) if (p.uninherited && p.beatLength > 0) p];
    final i = reds.indexWhere((p) => identical(p, before));
    if (i < 0 || !after.uninherited || !(after.beatLength > 0)) return null;
    final start = i == 0 ? double.negativeInfinity : before.time;
    final end = i + 1 < reds.length ? reds[i + 1].time : double.infinity;
    final ratio = after.beatLength / before.beatLength;
    double map(double t) {
      final x = after.time + (t - before.time) * ratio;
      final r = x.roundToDouble();
      return t >= before.time && r < after.time ? x.ceilToDouble() : r;
    }

    bool inSection(double t) => t >= start && t < end;

    final cmds = <EditCommand>[ReplaceTimingPointCommand(before, after)];
    for (final g in b.timingPoints) {
      if (g.uninherited || !inSection(g.time)) continue;
      cmds.add(ReplaceTimingPointCommand(g, g.copyWith(time: map(g.time))));
    }
    final objects = [for (final h in b.hitObjects) if (inSection(h.time)) h];
    if (objects.isNotEmpty) {
      cmds.add(ReplaceHitObjectsCommand(
        objects,
        [for (final h in objects) moved(h, map)],
        label: 'Move objects with timing',
      ));
    }
    return CompositeCommand('Change timing', cmds);
  }

  /// [h] with its start (and end, for spinners / hold notes) mapped by [map].
  static HitObject moved(HitObject h, double Function(double) map) => switch (h) {
    Spinner s => s.copyWith(time: map(s.time), endTime: map(s.endTime)),
    HoldNote n => HoldNote(
      position: n.position,
      time: map(n.time),
      endTime: map(n.endTime),
      newCombo: n.newCombo,
      comboSkip: n.comboSkip,
      hitSound: n.hitSound,
      sample: n.sample,
    ),
    _ => h.copyWithBase(time: map(h.time)),
  };
}
