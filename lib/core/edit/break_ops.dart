import 'dart:math' as math;

import '../model/beatmap.dart';
import '../model/hit_object.dart';
import 'commands.dart';

/// Why a break would not be accepted by lazer (its Verify `CheckBreaks`
/// and the editor's removal of manual breaks).
enum BreakIssue {
  /// An object lies (partly) inside it.
  overlapsObject,

  /// It ends before the first object or starts after the last one.
  outsideObjects,

  /// It starts less than [BreakRules.gapBefore] after the previous object.
  startsEarly,

  /// It ends less than [BreakRules.gapAfter] before the next object.
  endsLate,

  /// It is shorter than [BreakRules.minDuration] (has no effect).
  tooShort,
}

/// Break rules from lazer (`BreakPeriod`, `EditorBeatmapProcessor`,
/// `CheckBreaks`): a break starts at least [gapBefore] after the previous
/// object ends, ends at least [gapAfter] before the next object starts and
/// lasts at least [minDuration], so the gap between two objects must be at
/// least [minGap] to hold one.
abstract final class BreakRules {
  static const gapBefore = 200.0;
  static const gapAfter = 450.0;
  static const minDuration = 650.0;
  static const minGap = gapBefore + minDuration + gapAfter;

  /// lazer's Verify lets breaks be off by this much.
  static const leniency = 1.0;

  /// lazer's "Lighten during breaks": the background dim drops by this much
  /// (`UserDimContainer.BREAK_LIGHTEN_AMOUNT`)...
  static const lightenAmount = 0.3;

  /// ...fading over this long, OutQuint (`BACKGROUND_FADE_DURATION`)...
  static const lightenFade = 800.0;

  /// ...from a break's start until this long before its end
  /// (`BreakOverlay.BREAK_FADE_DURATION`), for breaks of at least
  /// [minDuration].
  static const lightenEndsEarly = minDuration / 2;

  /// lazer counts the intro as break time until this long before the first
  /// object (`DrawableRuleset.GameplayStartTime`)...
  static const introLead = 2000.0;

  /// ...or, in osu!, until the first object's preempt if that is longer
  /// (`DrawableOsuRuleset.GameplayStartTime`).
  static double introEnd(HitObject first, {required int mode, required double preempt}) =>
      first.time - (mode == 0 ? math.max(introLead, preempt) : introLead);

  static double _outQuint(double x) {
    final r = 1 - x.clamp(0.0, 1.0);
    return 1 - r * r * r * r * r;
  }

  /// How far the background is lightened at [t], 0..1 (times
  /// [lightenAmount]): in [breaks] (sorted by start), before [introEnd]
  /// (the intro) and after [outroStart] (everything judged: the outro), as
  /// lazer's `BreakTracker.IsBreakTime`. lazer animates this when that state
  /// flips; here it is a function of time so scrubbing and pausing show the
  /// same thing.
  static double lighteningAt(List<BreakPeriod> breaks, double t, {double? introEnd, double? outroStart}) {
    var out = 0.0;
    if (introEnd != null) out = 1 - _outQuint((t - introEnd) / lightenFade);
    if (outroStart != null && t > outroStart) out = math.max(out, _outQuint((t - outroStart) / lightenFade));
    return out >= 1 ? 1 : math.max(out, _breakLightening(breaks, t));
  }

  static double _breakLightening(List<BreakPeriod> breaks, double t) {
    for (final b in breaks) {
      if (b.start > t) break;
      if (b.duration < minDuration) continue;
      final off = b.end - lightenEndsEarly;
      if (t > off + lightenFade) continue;
      if (t <= off) return _outQuint((t - b.start) / lightenFade);
      return _outQuint((off - b.start) / lightenFade) * (1 - _outQuint((t - off) / lightenFade));
    }
    return 0;
  }

  /// Gaps between objects, as (end of everything before, start of the next
  /// object), for every pair of consecutive objects with free time between
  /// them. [objects] are sorted by start time.
  static List<(double, double, HitObject)> objectGaps(List<HitObject> objects, double Function(HitObject) endTime) {
    final out = <(double, double, HitObject)>[];
    var prevEnd = double.negativeInfinity;
    for (final h in objects) {
      if (prevEnd.isFinite && h.time > prevEnd) out.add((prevEnd, h.time, h));
      prevEnd = math.max(prevEnd, endTime(h));
    }
    return out;
  }

  /// Free time the object starting a gap's end needs before a break, as in
  /// lazer's automatic breaks: its preempt (AR) for modes whose objects fade
  /// in (osu!, catch), otherwise two beats but at least [gapAfter].
  static double leadIn({required int mode, required double preempt, required double beatLength}) =>
      mode == 0 || mode == 2 ? preempt : math.max(gapAfter, beatLength * 2);

  /// The default break for a gap from [prevEnd] to [nextStart]. Whether
  /// there is one follows lazer's automatic breaks: the gap is at least
  /// [minGap] and still leaves [minDuration] between [gapBefore] after the
  /// previous object and the next object's [leadIn] (so its approach isn't
  /// already showing during the break). The break itself is as long as the
  /// rules allow: from [gapBefore] after the previous object to [gapAfter]
  /// before the next one (lazer stops at the lead-in). Rounded inwards to
  /// whole ms (the file stores integers).
  static (double, double)? suggested(double prevEnd, double nextStart, double leadIn) {
    if (nextStart - prevEnd < minGap) return null;
    final start = (prevEnd + gapBefore).ceilToDouble();
    if (nextStart - math.max(leadIn, gapAfter) - start < minDuration) return null;
    return (start, (nextStart - gapAfter).floorToDouble());
  }

  /// Default breaks for the gaps that can hold one and hold no break yet.
  /// [leadIn] gives the gap's next object's lead-in.
  static List<(double, double)> insertable(List<HitObject> objects, double Function(HitObject) endTime,
      List<BreakPeriod> breaks, double Function(HitObject next) leadIn) {
    final out = <(double, double)>[];
    for (final (prevEnd, nextStart, next) in objectGaps(objects, endTime)) {
      if (breaks.any((b) => b.start < nextStart && b.end > prevEnd)) continue;
      final s = suggested(prevEnd, nextStart, leadIn(next));
      if (s != null) out.add(s);
    }
    return out;
  }

  /// lazer's `EditorBeatmapProcessor.autoGenerateBreaks`, run after the
  /// objects' times change: every automatic break goes; a [manual] one
  /// (adjusted by the user) stays unless it ends before the first object,
  /// starts after the last one ends or overlaps an object; then every gap
  /// that can hold a break and doesn't touch a kept one gets the default
  /// one ([suggested]). Returns the kept breaks and the new ranges.
  static (List<BreakPeriod>, List<(double, double)>) regenerate(
      List<HitObject> objects,
      double Function(HitObject) endTime,
      List<BreakPeriod> breaks,
      bool Function(BreakPeriod) manual,
      double Function(HitObject next) leadIn) {
    if (objects.isEmpty) return (const [], const []);
    var lastEnd = double.negativeInfinity;
    for (final h in objects) {
      lastEnd = math.max(lastEnd, endTime(h));
    }
    final kept = [
      for (final b in breaks)
        if (manual(b) &&
            b.end > objects.first.time &&
            b.start < lastEnd &&
            !objects.any((h) => h.time <= b.end && endTime(h) >= b.start))
          b,
    ];
    final added = <(double, double)>[];
    for (final (prevEnd, nextStart, next) in objectGaps(objects, endTime)) {
      final s = suggested(prevEnd, nextStart, leadIn(next));
      if (s == null) continue;
      if (kept.any((b) => b.start <= s.$2 && b.end >= s.$1)) continue;
      added.add(s);
    }
    return (kept, added);
  }

  /// What is wrong with [b] (empty when nothing).
  static Set<BreakIssue> issues(BreakPeriod b, List<HitObject> objects, double Function(HitObject) endTime) {
    final out = <BreakIssue>{};
    if (b.duration < minDuration) out.add(BreakIssue.tooShort);
    if (objects.isEmpty) return out..add(BreakIssue.outsideObjects);
    var prevEnd = double.negativeInfinity, lastEnd = double.negativeInfinity;
    double? nextStart;
    for (final h in objects) {
      final e = endTime(h);
      lastEnd = math.max(lastEnd, e);
      if (h.time <= b.end && e >= b.start) out.add(BreakIssue.overlapsObject);
      if (e <= b.start) prevEnd = math.max(prevEnd, e);
      if (h.time >= b.end) nextStart ??= h.time;
    }
    if (b.end <= objects.first.time || b.start >= lastEnd) out.add(BreakIssue.outsideObjects);
    if (prevEnd.isFinite && b.start - prevEnd < gapBefore - leniency) out.add(BreakIssue.startsEarly);
    if (nextStart != null && nextStart - b.end < gapAfter - leniency) out.add(BreakIssue.endsLate);
    return out;
  }

  /// Allowed ranges for [b]'s start and end while dragging one of them:
  /// [gapBefore] / [gapAfter] clear of the neighbouring objects (lazer's
  /// timeline only stops at the objects themselves, but its Verify flags
  /// anything closer as a problem), off other breaks, and at least
  /// [minDuration] long. Each range is (min, max) with min <= max.
  static ((double, double), (double, double)) limits(BreakPeriod b, List<HitObject> objects,
      double Function(HitObject) endTime, List<BreakPeriod> breaks) {
    var prevEnd = double.negativeInfinity;
    var nextStart = double.infinity;
    for (final h in objects) {
      if (h.time < b.start) {
        prevEnd = math.max(prevEnd, endTime(h));
      } else {
        nextStart = h.time;
        break;
      }
    }
    var prevBreak = double.negativeInfinity, nextBreak = double.infinity;
    for (final o in breaks) {
      if (o.lineIndex == b.lineIndex) continue;
      if (o.start < b.start) prevBreak = math.max(prevBreak, o.end);
      if (o.start >= b.start) nextBreak = math.min(nextBreak, o.start);
    }
    final startHi = b.end - minDuration;
    final startLo = math.min(startHi, math.max(0.0, math.max(prevEnd + gapBefore, prevBreak)));
    final endLo = b.start + minDuration;
    final endHi = math.max(endLo, math.min(nextStart - gapAfter, nextBreak));
    return ((startLo, startHi), (endLo, endHi));
  }
}

/// Adds a break line (`2,start,end`) to `[Events]`: in start order among the
/// existing breaks, else under the `//Break Periods` comment, else after the
/// background / video lines. Creates `[Events]` if the map has none.
class AddBreakCommand extends EditCommand {
  final int start;
  final int end;
  AddBreakCommand(this.start, this.end);

  RawSection? _created;
  int _index = -1;

  @override
  String get label => 'Add break';

  @override
  void apply(Beatmap b) {
    var events = b.eventsSection;
    if (events == null) {
      events = _created = RawSection(SectionNames.events);
      final at = b.sections.indexWhere((s) => s.name == SectionNames.timingPoints);
      b.sections.insert(at < 0 ? b.sections.length : at, events);
    }
    final lines = events.lines;
    _index = insertIndex(lines, start);
    lines.insert(_index, '2,$start,$end');
    b.revision++;
  }

  /// Where a break starting at [start] goes in the `[Events]` [lines].
  static int insertIndex(List<String> lines, int start) {
    int? afterBreak;
    for (var i = 0; i < lines.length; i++) {
      final p = BreakPeriod.parse(lines[i], i);
      if (p == null) continue;
      if (p.start > start) return i;
      afterBreak = i + 1;
    }
    if (afterBreak != null) return afterBreak;
    final comment = lines.indexWhere((l) => l.trim() == '//Break Periods');
    if (comment >= 0) return comment + 1;
    var at = 0;
    for (var i = 0; i < lines.length; i++) {
      final kind = lines[i].split(',').first.trim();
      if (const {'0', '1', 'Background', 'Video'}.contains(kind)) at = i + 1;
    }
    return at;
  }

  @override
  void revert(Beatmap b) {
    if (_created != null) {
      b.sections.remove(_created);
      _created = null;
    } else {
      b.eventsSection!.lines.removeAt(_index);
    }
    b.revision++;
  }
}

/// Swaps a set of breaks in one step (automatic break regeneration):
/// removes the break lines at [remove] and adds [add] (each placed like
/// [AddBreakCommand]). Revert restores the section's lines as they were.
class ReplaceBreaksCommand extends EditCommand {
  final Set<int> remove;
  final List<(int, int)> add;
  ReplaceBreaksCommand(this.remove, this.add);

  RawSection? _created;
  List<String>? _old;

  bool get isEmpty => remove.isEmpty && add.isEmpty;

  @override
  String get label => 'Update breaks';

  @override
  void apply(Beatmap b) {
    var events = b.eventsSection;
    if (events == null) {
      if (add.isEmpty) return;
      events = _created = RawSection(SectionNames.events);
      final at = b.sections.indexWhere((s) => s.name == SectionNames.timingPoints);
      b.sections.insert(at < 0 ? b.sections.length : at, events);
    }
    final lines = events.lines;
    _old = List.of(lines);
    for (final i in remove.toList()..sort((a, b) => b - a)) {
      lines.removeAt(i);
    }
    for (final (start, end) in add) {
      lines.insert(AddBreakCommand.insertIndex(lines, start), '2,$start,$end');
    }
    b.revision++;
  }

  @override
  void revert(Beatmap b) {
    if (_created != null) {
      b.sections.remove(_created);
      _created = null;
    } else {
      final old = _old;
      if (old == null) return;
      b.eventsSection!.lines
        ..clear()
        ..addAll(old);
    }
    b.revision++;
  }
}

/// Removes the break on line [lineIndex] of `[Events]`.
class RemoveBreakCommand extends EditCommand {
  final int lineIndex;
  RemoveBreakCommand(this.lineIndex);

  String? _old;

  @override
  String get label => 'Delete break';

  @override
  void apply(Beatmap b) {
    _old = b.eventsSection!.lines.removeAt(lineIndex);
    b.revision++;
  }

  @override
  void revert(Beatmap b) {
    b.eventsSection!.lines.insert(lineIndex, _old!);
    b.revision++;
  }
}

/// Changes the times of the break on line [lineIndex], keeping the rest of
/// the line (its `2` / `Break` kind and any extra fields).
class SetBreakCommand extends EditCommand {
  final int lineIndex;
  final int start;
  final int end;
  SetBreakCommand(this.lineIndex, this.start, this.end);

  String? _old;

  @override
  String get label => 'Change break';

  @override
  void apply(Beatmap b) {
    final lines = b.eventsSection!.lines;
    _old = lines[lineIndex];
    final parts = _old!.split(',');
    parts[1] = '$start';
    parts[2] = '$end';
    lines[lineIndex] = parts.join(',');
    b.revision++;
  }

  @override
  void revert(Beatmap b) {
    b.eventsSection!.lines[lineIndex] = _old!;
    b.revision++;
  }
}
