import '../geometry/lazer_path.dart';
import '../math/vec2.dart';
import '../model/beatmap.dart';
import '../model/hit_object.dart';
import '../model/timing_point.dart';
import 'number_format.dart';

/// Thrown for input that is not an .osu file at all.
class OsuFormatException implements Exception {
  final String message;
  OsuFormatException(this.message);
  @override
  String toString() => 'OsuFormatException: $message';
}

/// Parses .osu text into a [Beatmap].
///
/// Design goals:
/// * **Lossless for untouched content.** Every parsed line keeps its source
///   text (`sourceLine` / `rawLine`) and section layout (blank lines, BOM,
///   line endings) is recorded so `OsuWriter.write(OsuParser.parse(x)) == x`.
/// * **Lenient.** Malformed lines inside modeled sections are skipped and
///   reported via [warnings] instead of failing the whole file.
abstract final class OsuParser {
  static final _versionRe = RegExp(r'osu file format v(\d+)');

  static Beatmap parse(String text, {List<String>? warnings}) {
    final hasBom = text.startsWith('﻿');
    if (hasBom) text = text.substring(1);

    final lineEnding = text.contains('\r\n') ? '\r\n' : '\n';
    final endsWithNewline = text.endsWith('\n');

    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      if (l.endsWith('\r')) lines[i] = l.substring(0, l.length - 1);
    }
    if (endsWithNewline) lines.removeLast();

    final prelude = <String>[];
    var formatVersion = 14;
    var sawVersion = false;

    final beatmap = Beatmap(
      prelude: prelude,
      hasBom: hasBom,
      lineEnding: lineEnding,
      endsWithNewline: endsWithNewline,
    );

    String? currentName;
    var currentLines = <String>[];
    var lineNo = 0;
    var sectionStartLine = 0;

    void flush() {
      if (currentName == null) return;
      _buildSection(beatmap, currentName, currentLines, sectionStartLine,
          warnings, formatVersion);
    }

    for (final line in lines) {
      lineNo++;
      final trimmed = line.trim();
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        flush();
        currentName = trimmed.substring(1, trimmed.length - 1);
        currentLines = <String>[];
        sectionStartLine = lineNo + 1;
        continue;
      }
      if (currentName == null) {
        prelude.add(line);
        final m = _versionRe.firstMatch(line);
        if (m != null) {
          formatVersion = int.parse(m.group(1)!);
          sawVersion = true;
        }
      } else {
        currentLines.add(line);
      }
    }
    flush();

    if (!sawVersion && beatmap.sections.isEmpty) {
      throw OsuFormatException('Not an .osu file (no version header, no sections)');
    }
    beatmap.formatVersion = formatVersion;
    beatmap.revision = 0;
    return beatmap;
  }

  static void _buildSection(Beatmap b, String name, List<String> lines,
      int firstLineNo, List<String>? warnings, int formatVersion) {
    var trailing = 0;
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
      trailing++;
    }

    if (SectionNames.keyValueSections.contains(name)) {
      final s = KeyValueSection(name, trailingBlankLines: trailing);
      for (final line in lines) {
        final colon = line.indexOf(':');
        if (colon < 0 || line.trimLeft().startsWith('//')) {
          s.entries.add(KeyValueEntry(key: null, value: '', rawLine: line));
        } else {
          s.entries.add(KeyValueEntry(
            key: line.substring(0, colon).trim(),
            value: line.substring(colon + 1).trim(),
            rawLine: line,
          ));
        }
      }
      b.sections.add(s);
      return;
    }

    if (name == SectionNames.timingPoints) {
      b.sections.add(_modeled(name, trailing, lines, b.timingPoints, parseTimingPoint, (t) => t.time,
          (i, line) => warnings?.add('Line ${firstLineNo + i}: bad timing point "$line"')));
      return;
    }

    if (name == SectionNames.hitObjects) {
      b.sections.add(_modeled(name, trailing, lines, b.hitObjects,
          (line) => parseHitObject(line, formatVersion: formatVersion), (h) => h.time,
          (i, line) => warnings?.add('Line ${firstLineNo + i}: bad hit object "$line"')));
      return;
    }

    b.sections.add(RawSection(name, lines: lines, trailingBlankLines: trailing));
  }

  /// Parses the items of a modeled section into [items] (then sorted by
  /// time, file order kept for ties, as osu! does). Comments, blank lines and
  /// unparsable lines become [ExtraLine]s anchored to the next item.
  static ModeledSection _modeled<T extends Object>(
    String name,
    int trailing,
    List<String> lines,
    List<T> items,
    T? Function(String) parse,
    double Function(T) timeOf,
    void Function(int index, String line) onBad,
  ) {
    final pending = <String>[];
    final extras = <ExtraLine>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final skip = line.trim().isEmpty || line.trimLeft().startsWith('//');
      final item = skip ? null : parse(line);
      if (item == null) {
        if (!skip) onBad(i, line);
        pending.add(line);
        continue;
      }
      for (final l in pending) {
        extras.add(ExtraLine(l, anchor: item, anchorTime: timeOf(item)));
      }
      pending.clear();
      items.add(item);
    }
    for (final l in pending) {
      extras.add(ExtraLine(l));
    }
    _stableSortByTime(items, timeOf);
    return ModeledSection(name, trailingBlankLines: trailing, extraLines: extras);
  }

  static void _stableSortByTime<T>(List<T> list, double Function(T) timeOf) {
    final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
    indexed.sort((a, b) {
      final c = timeOf(a.$2).compareTo(timeOf(b.$2));
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    for (var i = 0; i < list.length; i++) {
      list[i] = indexed[i].$2;
    }
  }

  /// `time,beatLength,meter,sampleSet,sampleIndex,volume,uninherited,effects`
  /// Older formats may omit trailing fields.
  static TimingPoint? parseTimingPoint(String line) {
    final p = line.split(',');
    if (p.length < 2) return null;
    final time = parseDoubleLenient(p[0]);
    final beatLength = parseDoubleLenient(p[1]);
    if (time == null || beatLength == null) return null;
    int intAt(int i, int fallback) =>
        i < p.length ? (parseIntLenient(p[i]) ?? fallback) : fallback;
    final uninherited =
        p.length > 6 ? intAt(6, 1) != 0 : !(beatLength < 0);
    return TimingPoint(
      time: time,
      beatLength: beatLength,
      meter: intAt(2, 4),
      sampleSet: intAt(3, 0),
      sampleIndex: intAt(4, 0),
      volume: intAt(5, 100),
      uninherited: uninherited,
      effects: intAt(7, 0),
      sourceLine: line,
    );
  }

  /// `x,y,time,type,hitSound,objectParams,hitSample`. [formatVersion]
  /// matters for paths in osu!lazer's syntax (see [LazerPath.decode]).
  static HitObject? parseHitObject(String line, {int formatVersion = 14}) {
    final p = line.split(',');
    if (p.length < 4) return null;
    final x = parseDoubleLenient(p[0]);
    final y = parseDoubleLenient(p[1]);
    final time = parseDoubleLenient(p[2]);
    final type = parseIntLenient(p[3]);
    if (x == null || y == null || time == null || type == null) return null;
    final hitSound = p.length > 4 ? (parseIntLenient(p[4]) ?? 0) : 0;
    final pos = Vec2(x, y);
    final newCombo = type & HitObjectType.newCombo != 0;
    final comboSkip =
        (type & HitObjectType.comboSkipMask) >> HitObjectType.comboSkipShift;
    HitSample sampleAt(int i) =>
        i < p.length ? HitSample.parse(p[i]) : HitSample.empty;

    if (type & HitObjectType.circle != 0) {
      return HitCircle(
        position: pos,
        time: time,
        newCombo: newCombo,
        comboSkip: comboSkip,
        hitSound: hitSound,
        sample: sampleAt(5),
        sourceLine: line,
      );
    }

    if (type & HitObjectType.slider != 0) {
      // The length (field 7) may be missing: then the computed path's
      // (SliderPath, as osu! does).
      if (p.length < 7) return null;
      var (curveType, points) = _parseCurve(p[5]);
      List<PathType?>? pointTypes;
      if (LazerPath.isLazerCurve(p[5])) {
        final (all, types) = LazerPath.decode(pos, p[5], formatVersion: formatVersion);
        points = all.sublist(1);
        pointTypes = types;
        curveType = types.first!.kind;
      }
      final slides = parseIntLenient(p[6]) ?? 1;
      final length = p.length > 7 ? parseDoubleLenient(p[7]) ?? 0 : 0.0;
      List<int>? edgeSounds;
      List<EdgeSet>? edgeSets;
      if (p.length > 8 && p[8].trim().isNotEmpty) {
        edgeSounds = [for (final s in p[8].split('|')) parseIntLenient(s) ?? 0];
      }
      if (p.length > 9 && p[9].trim().isNotEmpty) {
        edgeSets = [
          for (final s in p[9].split('|'))
            () {
              final ab = s.split(':');
              return EdgeSet(
                parseIntLenient(ab[0]) ?? 0,
                ab.length > 1 ? (parseIntLenient(ab[1]) ?? 0) : 0,
              );
            }()
        ];
      }
      return SliderObject(
        position: pos,
        time: time,
        curveType: curveType,
        controlPoints: points,
        slides: slides < 1 ? 1 : slides,
        length: length,
        edgeSounds: edgeSounds,
        edgeSets: edgeSets,
        pointTypes: pointTypes,
        newCombo: newCombo,
        comboSkip: comboSkip,
        hitSound: hitSound,
        sample: sampleAt(10),
        sourceLine: line,
      );
    }

    if (type & HitObjectType.spinner != 0) {
      final end = p.length > 5 ? parseDoubleLenient(p[5]) : null;
      return Spinner(
        position: pos,
        time: time,
        endTime: end ?? time,
        newCombo: newCombo,
        comboSkip: comboSkip,
        hitSound: hitSound,
        sample: sampleAt(6),
        sourceLine: line,
      );
    }

    if (type & HitObjectType.maniaHold != 0) {
      // endTime:normalSet:additionSet:index:volume:filename
      final rest = p.length > 5 ? p[5] : '';
      final colon = rest.indexOf(':');
      final endStr = colon < 0 ? rest : rest.substring(0, colon);
      return HoldNote(
        position: pos,
        time: time,
        endTime: parseDoubleLenient(endStr) ?? time,
        newCombo: newCombo,
        comboSkip: comboSkip,
        hitSound: hitSound,
        sample: colon < 0
            ? HitSample.empty
            : HitSample.parse(rest.substring(colon + 1)),
        sourceLine: line,
      );
    }
    return null;
  }

  /// `B|x:y|x:y|...` in stable's syntax (one curve type). Paths in lazer's
  /// syntax are read by [LazerPath.decode] instead.
  static (CurveType, List<Vec2>) _parseCurve(String s) {
    final tokens = s.split('|');
    var type = CurveType.bezier;
    var typeSet = false;
    final points = <Vec2>[];
    for (final t in tokens) {
      final colon = t.indexOf(':');
      if (colon < 0) {
        if (!typeSet && t.trim().isNotEmpty) {
          type = CurveType.fromLetter(t);
          typeSet = true;
        }
        continue;
      }
      final x = parseDoubleLenient(t.substring(0, colon));
      final y = parseDoubleLenient(t.substring(colon + 1));
      if (x != null && y != null) points.add(Vec2(x, y));
    }
    return (type, points);
  }
}
