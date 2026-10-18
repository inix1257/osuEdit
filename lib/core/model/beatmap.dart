import 'hit_object.dart';
import 'timing_point.dart';

/// Section names that have dedicated models.
abstract final class SectionNames {
  static const general = 'General';
  static const editor = 'Editor';
  static const metadata = 'Metadata';
  static const difficulty = 'Difficulty';
  static const events = 'Events';
  static const timingPoints = 'TimingPoints';
  static const colours = 'Colours';
  static const hitObjects = 'HitObjects';

  static const keyValueSections = {general, editor, metadata, difficulty};
}

/// A section of the .osu file, kept in file order so the writer can
/// reproduce the original layout.
sealed class OsuSection {
  final String name;

  /// Blank lines that followed this section in the source file. osu!stable
  /// writes e.g. two blank lines after `[TimingPoints]`; we keep what we read.
  int trailingBlankLines;

  OsuSection(this.name, {this.trailingBlankLines = 1});
}

/// One line inside a key-value section. A comment / unparseable line has a
/// null [key] and is preserved via [rawLine].
class KeyValueEntry {
  final String? key;
  final String value;

  /// Original text; null once the value was changed via [Beatmap.setValue].
  final String? rawLine;

  const KeyValueEntry({required this.key, required this.value, this.rawLine});
}

/// `[General]`, `[Editor]`, `[Metadata]`, `[Difficulty]`.
class KeyValueSection extends OsuSection {
  final List<KeyValueEntry> entries;

  KeyValueSection(super.name, {List<KeyValueEntry>? entries, super.trailingBlankLines})
      : entries = entries ?? [];

  /// osu!stable writes `Key: Value` in General/Editor and `Key:Value` in
  /// Metadata/Difficulty.
  String get separator =>
      name == SectionNames.general || name == SectionNames.editor ? ': ' : ':';

  int indexOfKey(String key) =>
      entries.indexWhere((e) => e.key == key);

  String? operator [](String key) {
    final i = indexOfKey(key);
    return i < 0 ? null : entries[i].value;
  }
}

/// Sections we don't model in detail (`[Events]`, `[Colours]`, unknown).
/// Lines are kept verbatim.
class RawSection extends OsuSection {
  final List<String> lines;
  RawSection(super.name, {List<String>? lines, super.trailingBlankLines})
      : lines = lines ?? [];
}

/// Placeholder marking where `[TimingPoints]` / `[HitObjects]` go; their
/// content lives in [Beatmap.timingPoints] / [Beatmap.hitObjects].
///
/// [extraLines] keeps everything else found between the section's items
/// (`//` comments, blank lines, lines that failed to parse) so they are
/// written back.
class ModeledSection extends OsuSection {
  final List<ExtraLine> extraLines;

  ModeledSection(super.name, {super.trailingBlankLines, List<ExtraLine>? extraLines})
      : extraLines = extraLines ?? [];
}

/// A non-item line inside a modeled section, remembered by what followed it
/// in the file: written right before [anchor] (a `HitObject` /
/// `TimingPoint`, compared by identity) while that object still exists,
/// otherwise before the first item at or after [anchorTime]. Both null: at
/// the end of the section.
class ExtraLine {
  final String line;
  final Object? anchor;
  final double? anchorTime;

  const ExtraLine(this.line, {this.anchor, this.anchorTime});
}

/// A break (`2,start,end` / `Break,start,end` in `[Events]`), remembering
/// which line of the section it is ([lineIndex]).
class BreakPeriod {
  final double start;
  final double end;
  final int lineIndex;

  const BreakPeriod(this.start, this.end, this.lineIndex);

  double get duration => end - start;

  /// Parses a break line; null for any other line (or end <= start).
  static BreakPeriod? parse(String line, int lineIndex) {
    final parts = line.split(',');
    if (parts.length < 3) return null;
    final kind = parts[0].trim();
    if (kind != '2' && kind != 'Break') return null;
    final start = double.tryParse(parts[1].trim());
    final end = double.tryParse(parts[2].trim());
    if (start == null || end == null || end <= start) return null;
    return BreakPeriod(start, end, lineIndex);
  }
}

/// In-memory .osu document.
///
/// Mutable container; all user edits must go through `EditHistory` commands
/// (lib/core/edit) so they are undoable. Both object lists are kept sorted by
/// time (stable: equal times keep insertion/file order).
class Beatmap {
  int formatVersion;

  /// Lines before the first section header (version line, blank lines).
  final List<String> prelude;
  final List<OsuSection> sections;
  final List<TimingPoint> timingPoints;
  final List<HitObject> hitObjects;

  // File encoding details preserved for byte-exact round trips.
  bool hasBom;
  String lineEnding;
  bool endsWithNewline;

  /// Bumped on every mutation. UI caches compare against it.
  int revision = 0;

  Beatmap({
    this.formatVersion = 14,
    List<String>? prelude,
    List<OsuSection>? sections,
    List<TimingPoint>? timingPoints,
    List<HitObject>? hitObjects,
    this.hasBom = false,
    this.lineEnding = '\r\n',
    this.endsWithNewline = true,
  })  : prelude = prelude ?? ['osu file format v$formatVersion', ''],
        sections = sections ?? [],
        timingPoints = timingPoints ?? [],
        hitObjects = hitObjects ?? [];

  /// A minimal valid v14 osu!standard map.
  factory Beatmap.empty() {
    final b = Beatmap(sections: [
      KeyValueSection(SectionNames.general),
      KeyValueSection(SectionNames.editor),
      KeyValueSection(SectionNames.metadata),
      KeyValueSection(SectionNames.difficulty),
      RawSection(SectionNames.events, lines: [
        '//Background and Video events',
        '//Break Periods',
        '//Storyboard Layer 0 (Background)',
        '//Storyboard Layer 1 (Fail)',
        '//Storyboard Layer 2 (Pass)',
        '//Storyboard Layer 3 (Foreground)',
        '//Storyboard Sound Samples',
      ]),
      ModeledSection(SectionNames.timingPoints, trailingBlankLines: 2),
      ModeledSection(SectionNames.hitObjects, trailingBlankLines: 0),
    ]);
    for (final (s, k, v) in const [
      (SectionNames.general, 'AudioFilename', 'audio.mp3'),
      (SectionNames.general, 'AudioLeadIn', '0'),
      (SectionNames.general, 'PreviewTime', '-1'),
      (SectionNames.general, 'Countdown', '0'),
      (SectionNames.general, 'SampleSet', 'Soft'),
      (SectionNames.general, 'StackLeniency', '0.7'),
      (SectionNames.general, 'Mode', '0'),
      (SectionNames.general, 'LetterboxInBreaks', '0'),
      (SectionNames.general, 'WidescreenStoryboard', '1'),
      (SectionNames.editor, 'DistanceSpacing', '1'),
      (SectionNames.editor, 'BeatDivisor', '4'),
      (SectionNames.editor, 'GridSize', '32'),
      (SectionNames.editor, 'TimelineZoom', '1'),
      (SectionNames.metadata, 'Title', ''),
      (SectionNames.metadata, 'TitleUnicode', ''),
      (SectionNames.metadata, 'Artist', ''),
      (SectionNames.metadata, 'ArtistUnicode', ''),
      (SectionNames.metadata, 'Creator', ''),
      (SectionNames.metadata, 'Version', ''),
      (SectionNames.metadata, 'Source', ''),
      (SectionNames.metadata, 'Tags', ''),
      (SectionNames.metadata, 'BeatmapID', '0'),
      (SectionNames.metadata, 'BeatmapSetID', '-1'),
      (SectionNames.difficulty, 'HPDrainRate', '5'),
      (SectionNames.difficulty, 'CircleSize', '4'),
      (SectionNames.difficulty, 'OverallDifficulty', '8'),
      (SectionNames.difficulty, 'ApproachRate', '9'),
      (SectionNames.difficulty, 'SliderMultiplier', '1.4'),
      (SectionNames.difficulty, 'SliderTickRate', '1'),
    ]) {
      b.setValue(s, k, v);
    }
    b.revision = 0;
    return b;
  }

  // ---------------------------------------------------------------------------
  // Key-value access

  KeyValueSection? keyValueSection(String name) {
    for (final s in sections) {
      if (s is KeyValueSection && s.name == name) return s;
    }
    return null;
  }

  String? getValue(String section, String key) => keyValueSection(section)?[key];

  /// Sets (or appends) a key. Creates the section if missing. Prefer
  /// `SetValueCommand` for user-facing edits so it can be undone.
  void setValue(String section, String key, String value) {
    var s = keyValueSection(section);
    if (s == null) {
      s = KeyValueSection(section);
      _insertSectionInCanonicalOrder(s);
    }
    final entry = KeyValueEntry(key: key, value: value);
    final i = s.indexOfKey(key);
    if (i < 0) {
      s.entries.add(entry);
    } else {
      s.entries[i] = entry;
    }
    revision++;
  }

  /// Removes a key. Returns the previous value.
  String? removeValue(String section, String key) {
    final s = keyValueSection(section);
    if (s == null) return null;
    final i = s.indexOfKey(key);
    if (i < 0) return null;
    revision++;
    return s.entries.removeAt(i).value;
  }

  void _insertSectionInCanonicalOrder(OsuSection section) {
    const order = [
      SectionNames.general,
      SectionNames.editor,
      SectionNames.metadata,
      SectionNames.difficulty,
      SectionNames.events,
      SectionNames.timingPoints,
      SectionNames.colours,
      SectionNames.hitObjects,
    ];
    final rank = order.indexOf(section.name);
    if (rank < 0) {
      sections.add(section);
      return;
    }
    final at = sections.indexWhere((s) {
      final r = order.indexOf(s.name);
      return r > rank;
    });
    if (at < 0) {
      sections.add(section);
    } else {
      sections.insert(at, section);
    }
  }

  double _num(String section, String key, double fallback) =>
      double.tryParse(getValue(section, key)?.trim() ?? '') ?? fallback;

  // ---------------------------------------------------------------------------
  // Typed convenience getters

  String get audioFilename =>
      getValue(SectionNames.general, 'AudioFilename')?.trim() ?? '';
  int get mode => _num(SectionNames.general, 'Mode', 0).toInt();
  double get stackLeniency => _num(SectionNames.general, 'StackLeniency', 0.7);
  int get defaultSampleSet =>
      SampleSet.parse(getValue(SectionNames.general, 'SampleSet') ?? 'Normal');

  int get beatDivisor => _num(SectionNames.editor, 'BeatDivisor', 4).toInt();
  List<int> get bookmarks =>
      (getValue(SectionNames.editor, 'Bookmarks') ?? '')
          .split(',')
          .map((s) => int.tryParse(s.trim()))
          .whereType<int>()
          .toList();

  String get title => getValue(SectionNames.metadata, 'Title') ?? '';
  String get artist => getValue(SectionNames.metadata, 'Artist') ?? '';
  String get creator => getValue(SectionNames.metadata, 'Creator') ?? '';
  String get version => getValue(SectionNames.metadata, 'Version') ?? '';

  double get hpDrainRate => _num(SectionNames.difficulty, 'HPDrainRate', 5);
  double get circleSize => _num(SectionNames.difficulty, 'CircleSize', 5);
  double get overallDifficulty =>
      _num(SectionNames.difficulty, 'OverallDifficulty', 5);

  /// Old maps have no ApproachRate; it then equals OD.
  double get approachRate =>
      _num(SectionNames.difficulty, 'ApproachRate', overallDifficulty);
  double get sliderMultiplier =>
      _num(SectionNames.difficulty, 'SliderMultiplier', 1.4);
  double get sliderTickRate => _num(SectionNames.difficulty, 'SliderTickRate', 1);

  /// Background image file from `[Events]` (`0,0,"bg.jpg",0,0`).
  String? get backgroundFilename {
    for (final s in sections) {
      if (s is! RawSection || s.name != SectionNames.events) continue;
      for (final line in s.lines) {
        final parts = line.split(',');
        if (parts.length >= 3 &&
            (parts[0].trim() == '0' || parts[0].trim() == 'Background')) {
          return parts[2].trim().replaceAll('"', '');
        }
      }
    }
    return null;
  }

  /// Break periods from `[Events]` (`2,start,end` or `Break,start,end`), in ms.
  List<(double, double)> get breaks => [for (final p in breakPeriods) (p.start, p.end)];

  /// The `[Events]` section, or null.
  RawSection? get eventsSection {
    for (final s in sections) {
      if (s is RawSection && s.name == SectionNames.events) return s;
    }
    return null;
  }

  /// Break periods with the `[Events]` line they come from, sorted by start.
  List<BreakPeriod> get breakPeriods {
    final lines = eventsSection?.lines;
    if (lines == null) return const [];
    final out = <BreakPeriod>[];
    for (var i = 0; i < lines.length; i++) {
      final p = BreakPeriod.parse(lines[i], i);
      if (p != null) out.add(p);
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  // ---------------------------------------------------------------------------
  // Sorted list maintenance (used by commands)


  /// Index at which an object with [time] is inserted to keep the list
  /// sorted (after existing objects with the same time).
  static int upperBound<T>(List<T> list, double time, double Function(T) timeOf) {
    var lo = 0, hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (timeOf(list[mid]) <= time) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// First index whose time is >= [time].
  static int lowerBound<T>(List<T> list, double time, double Function(T) timeOf) {
    var lo = 0, hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (timeOf(list[mid]) < time) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  static double _hoTime(HitObject h) => h.time;
  static double _tpTime(TimingPoint t) => t.time;

  int insertHitObject(HitObject h) {
    final i = upperBound(hitObjects, h.time, _hoTime);
    hitObjects.insert(i, h);
    revision++;
    return i;
  }

  /// Identity lookup using binary search on time.
  int indexOfHitObject(HitObject h) =>
      _identityIndex(hitObjects, h, h.time, _hoTime);

  bool removeHitObject(HitObject h) {
    final i = indexOfHitObject(h);
    if (i < 0) return false;
    hitObjects.removeAt(i);
    revision++;
    return true;
  }

  /// Inserts [t] in time order. Among points at the same time a red point
  /// goes first and a green one last, so a green point sharing a red one's
  /// time keeps applying its SV (the last point at a time wins).
  int insertTimingPoint(TimingPoint t) {
    final i = t.uninherited
        ? lowerBound(timingPoints, t.time, _tpTime)
        : upperBound(timingPoints, t.time, _tpTime);
    timingPoints.insert(i, t);
    revision++;
    return i;
  }

  int indexOfTimingPoint(TimingPoint t) =>
      _identityIndex(timingPoints, t, t.time, _tpTime);

  bool removeTimingPoint(TimingPoint t) {
    final i = indexOfTimingPoint(t);
    if (i < 0) return false;
    timingPoints.removeAt(i);
    revision++;
    return true;
  }

  static int _identityIndex<T>(
      List<T> list, T item, double time, double Function(T) timeOf) {
    for (var i = lowerBound(list, time, timeOf);
        i < list.length && timeOf(list[i]) == time;
        i++) {
      if (identical(list[i], item)) return i;
    }
    // Fallback (should not happen if the list is sorted).
    for (var i = 0; i < list.length; i++) {
      if (identical(list[i], item)) return i;
    }
    return -1;
  }

  /// Hit objects whose start time lies in [from, to).
  Iterable<HitObject> hitObjectsStartingIn(double from, double to) sync* {
    for (var i = lowerBound(hitObjects, from, _hoTime);
        i < hitObjects.length && hitObjects[i].time < to;
        i++) {
      yield hitObjects[i];
    }
  }
}
