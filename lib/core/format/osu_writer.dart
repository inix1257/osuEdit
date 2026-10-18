import '../geometry/lazer_path.dart';
import '../model/beatmap.dart';
import '../model/hit_object.dart';
import '../model/timing_point.dart';
import 'number_format.dart';

/// Serializes a [Beatmap] back to .osu text.
///
/// Untouched lines are emitted verbatim from their `sourceLine`/`rawLine`;
/// edited ones are written in osu!stable's canonical v14 form.
abstract final class OsuWriter {
  static String write(Beatmap b) {
    final out = <String>[];
    if (b.prelude.isEmpty) {
      out.addAll(['osu file format v${b.formatVersion}', '']);
    } else {
      out.addAll(b.prelude);
    }

    for (final s in b.sections) {
      out.add('[${s.name}]');
      switch (s) {
        case KeyValueSection():
          for (final e in s.entries) {
            out.add(e.rawLine ?? '${e.key}${s.separator}${e.value}');
          }
        case RawSection():
          out.addAll(s.lines);
        case ModeledSection():
          if (s.name == SectionNames.timingPoints) {
            _writeModeled(out, s.extraLines, b.timingPoints, (t) => t.time,
                (t) => t.sourceLine ?? encodeTimingPoint(t));
          } else if (s.name == SectionNames.hitObjects) {
            _writeModeled(out, s.extraLines, b.hitObjects, (h) => h.time,
                (h) => h.sourceLine ?? encodeHitObject(h));
          }
      }
      for (var i = 0; i < s.trailingBlankLines; i++) {
        out.add('');
      }
    }

    final body = out.join(b.lineEnding);
    return '${b.hasBom ? '﻿' : ''}$body${b.endsWithNewline ? b.lineEnding : ''}';
  }

  /// Writes [items] with the section's [extras] (comments, blank and
  /// unparsable lines) in place: before their anchor while it exists, else
  /// before the first item at or after their anchor time (an edited object
  /// is a new instance at about the same time; a deleted one leaves its
  /// comment where it was), else at the end.
  static void _writeModeled<T extends Object>(List<String> out, List<ExtraLine> extras, List<T> items,
      double Function(T) timeOf, String Function(T) encode) {
    if (extras.isEmpty) {
      for (final i in items) {
        out.add(encode(i));
      }
      return;
    }
    final present = Set<Object>.identity()..addAll(items);
    final anchored = Map<Object, List<String>>.identity();
    final floating = <ExtraLine>[];
    for (final e in extras) {
      final a = e.anchor;
      if (a != null && present.contains(a)) {
        (anchored[a] ??= []).add(e.line);
      } else {
        floating.add(e);
      }
    }
    // Stable: equal times keep file order; time-less (trailing) lines last.
    final order = [for (var i = 0; i < floating.length; i++) i];
    order.sort((x, y) {
      final tx = floating[x].anchorTime ?? double.infinity, ty = floating[y].anchorTime ?? double.infinity;
      final c = tx.compareTo(ty);
      return c != 0 ? c : x.compareTo(y);
    });
    var f = 0;
    for (final item in items) {
      final t = timeOf(item);
      while (f < order.length && (floating[order[f]].anchorTime ?? double.infinity) <= t) {
        out.add(floating[order[f++]].line);
      }
      final mine = anchored[item];
      if (mine != null) out.addAll(mine);
      out.add(encode(item));
    }
    while (f < order.length) {
      out.add(floating[order[f++]].line);
    }
  }

  static String encodeTimingPoint(TimingPoint t) => [
        formatNumber(t.time),
        formatNumber(t.beatLength),
        t.meter,
        t.sampleSet,
        t.sampleIndex,
        t.volume,
        t.uninherited ? 1 : 0,
        t.effects,
      ].join(',');

  /// A slider's curve field: stable's syntax (one letter, doubled red
  /// anchors) whenever stable can express the path, else lazer's.
  static String encodeCurve(SliderObject h) {
    final types = h.pointTypes;
    var (type, points) = (h.curveType, h.allPoints);
    if (types != null) {
      final stable = LazerPath.toStableForm(h.allPoints, types);
      if (stable == null) return LazerPath.encodeCurve(h.allPoints, types);
      (type, points) = stable;
    }
    return [
      type.letter,
      for (final p in points.skip(1)) '${p.x.round()}:${p.y.round()}',
    ].join('|');
  }

  static String encodeHitObject(HitObject h) {
    final head = [
      h.position.x.round(),
      h.position.y.round(),
      h.time.round(),
      h.encodedType,
      h.hitSound,
    ].join(',');

    switch (h) {
      case HitCircle():
        return '$head,${h.sample.encode()}';
      case Spinner():
        return '$head,${h.endTime.round()},${h.sample.encode()}';
      case HoldNote():
        return '$head,${h.endTime.round()}:${h.sample.encode()}';
      case SliderObject():
        final curve = encodeCurve(h);
        final edges = h.slides + 1;
        // Edges the file didn't list (no fields 8/9, or more repeats now) sound
        // like the object: its hitsound and its sets, as osu! reads a missing
        // field (and as [Hitsounds.resolve] plays it). Writing 0 / 0:0 here
        // would silence their additions.
        final sounds = List<int>.generate(
            edges,
            (i) => h.edgeSounds != null && i < h.edgeSounds!.length
                ? h.edgeSounds![i]
                : h.hitSound);
        final sets = List<EdgeSet>.generate(
            edges,
            (i) => h.edgeSets != null && i < h.edgeSets!.length
                ? h.edgeSets![i]
                : EdgeSet(h.sample.normalSet, h.sample.additionSet));
        return [
          head,
          curve,
          h.slides,
          formatNumber(h.length),
          sounds.join('|'),
          sets.map((e) => '${e.normalSet}:${e.additionSet}').join('|'),
          h.sample.encode(),
        ].join(',');
    }
  }
}
