import '../model/beatmap.dart';
import '../model/hit_object.dart';
import '../model/timing_point.dart';
import 'colour_ops.dart';
import 'commands.dart';

/// Where an undo / redo step's change lives in the editor, so the UI can
/// take the user there.
enum EditArea {
  /// Hit objects (Compose: seek to them and select them).
  objects,

  /// Timing points (Timing mode / the Control Points popup).
  timing,

  /// Break periods (the top timeline, edited in Compose).
  breaks,

  /// `[Editor]` Bookmarks (the timelines, any mode).
  bookmarks,

  /// Metadata, difficulty settings, audio / background files (Song setup).
  songSetup,

  /// Base slider velocity / tick rate (Timing mode's map column, or Song
  /// setup).
  sliderSettings,

  /// Compose toolbox settings stored in the map (grid size, distance
  /// spacing).
  composeSettings,

  /// Nothing recognisable changed.
  other,
}

/// What a map looked like before an undo / redo, to diff against.
class EditSnapshot {
  final List<HitObject> objects;
  final List<TimingPoint> points;
  final List<(double, double)> breaks;
  final List<int> bookmarks;

  EditSnapshot.of(Beatmap b)
      : objects = List.of(b.hitObjects),
        points = List.of(b.timingPoints),
        breaks = b.breaks,
        bookmarks = b.bookmarks;
}

/// What one undo / redo step changed: the area, the time to show and the
/// objects / points it left in the map, plus a short description for a toast.
class EditFocus {
  final EditArea area;

  /// Time (ms) of the earliest change, if it has one.
  final double? time;

  /// Changed hit objects still in the map after the step (restored by an
  /// undo of a delete, the new copies of moved ones...), in map order.
  final List<HitObject> objects;

  /// Changed timing points still in the map after the step, in map order.
  final List<TimingPoint> timingPoints;

  /// Timing points the step took out of the map (undo of an add...).
  final List<TimingPoint> removedTimingPoints;

  /// Human-readable name of the step ("Move objects", "Change HP drain").
  final String label;

  const EditFocus({
    required this.area,
    required this.label,
    this.time,
    this.objects = const [],
    this.timingPoints = const [],
    this.removedTimingPoints = const [],
  });

  /// Only inherited (green) points changed: they are edited in the Control
  /// Points popup, red ones in Timing mode.
  bool get inheritedOnly =>
      area == EditArea.timing && [...timingPoints, ...removedTimingPoints].every((p) => !p.uninherited);

  /// Diffs the map now against [before], the state just before [step] was
  /// undone or redone. Timing beats objects (moving objects with timing),
  /// objects and settings beat breaks (regenerated after those).
  factory EditFocus.between(EditSnapshot before, Beatmap after, EditCommand step) {
    final label = describe(step);

    final (pointsIn, pointsOut) = _diff(before.points, after.timingPoints);
    if (pointsIn.isNotEmpty || pointsOut.isNotEmpty) {
      return EditFocus(
        area: EditArea.timing,
        label: label,
        time: _earliest([for (final p in pointsIn.isNotEmpty ? pointsIn : pointsOut) p.time]),
        timingPoints: pointsIn,
        removedTimingPoints: pointsOut,
      );
    }

    final (objsIn, objsOut) = _diff(before.objects, after.hitObjects);
    if (objsIn.isNotEmpty || objsOut.isNotEmpty) {
      return EditFocus(
        area: EditArea.objects,
        label: label,
        time: _earliest([for (final h in objsIn.isNotEmpty ? objsIn : objsOut) h.time]),
        objects: objsIn,
      );
    }

    final keys = _keysOf(step);
    if (keys.isNotEmpty) {
      final area = _areaOfKeys(keys);
      if (area != EditArea.bookmarks) return EditFocus(area: area, label: label);
    }

    final marks = before.bookmarks.toSet();
    final nowMarks = after.bookmarks.toSet();
    final changedMarks = [...marks.difference(nowMarks), ...nowMarks.difference(marks)];
    if (changedMarks.isNotEmpty) {
      return EditFocus(
        area: EditArea.bookmarks,
        label: label,
        time: _earliest([for (final m in changedMarks) m.toDouble()]),
      );
    }

    final breaks = before.breaks.toSet();
    final nowBreaks = after.breaks.toSet();
    final added = nowBreaks.difference(breaks);
    final changedBreaks = added.isNotEmpty ? added : breaks.difference(nowBreaks);
    if (changedBreaks.isNotEmpty) {
      return EditFocus(
        area: EditArea.breaks,
        label: label,
        time: _earliest([for (final b in changedBreaks) b.$1]),
      );
    }

    return EditFocus(area: keys.isEmpty ? EditArea.other : _areaOfKeys(keys), label: label);
  }

  /// Items of [now] not in [then], and of [then] not in [now] (identity).
  static (List<T>, List<T>) _diff<T extends Object>(List<T> then, List<T> now) {
    final a = Set<T>.identity()..addAll(then);
    final b = Set<T>.identity()..addAll(now);
    return ([for (final x in now) if (!a.contains(x)) x], [for (final x in then) if (!b.contains(x)) x]);
  }

  static double? _earliest(Iterable<double> times) {
    double? m;
    for (final t in times) {
      if (m == null || t < m) m = t;
    }
    return m;
  }

  /// `(section, key)` of every value the step sets or removes; a background
  /// change counts as `[Events]` Background.
  static List<(String, String)> _keysOf(EditCommand c) => switch (c) {
        CompositeCommand(:final commands) => [for (final x in commands) ..._keysOf(x)],
        SetValueCommand(:final section, :final key) => [(section, key)],
        RemoveValueCommand(:final section, :final key) => [(section, key)],
        SetBackgroundCommand() => [(SectionNames.events, 'Background')],
        SetComboColoursCommand() => [(SectionNames.colours, 'Combo')],
        SetColourKeyCommand(:final key) => [(SectionNames.colours, key)],
        _ => const [],
      };

  static EditArea _areaOfKeys(List<(String, String)> keys) {
    final (section, key) = keys.first;
    if (section == SectionNames.editor) {
      return key == 'Bookmarks' ? EditArea.bookmarks : EditArea.composeSettings;
    }
    if (section == SectionNames.difficulty && (key == 'SliderMultiplier' || key == 'SliderTickRate')) {
      return EditArea.sliderSettings;
    }
    return EditArea.songSetup;
  }

  /// A short name for [c], with friendlier names for single settings.
  static String describe(EditCommand c) {
    // A follow-up (regenerated breaks) wraps the step under its own label.
    var lead = c;
    while (lead is CompositeCommand && lead.commands.isNotEmpty && lead.commands.first.label == lead.label) {
      lead = lead.commands.first;
    }
    final key = switch (lead) {
      SetValueCommand(:final key) || RemoveValueCommand(:final key) => key,
      _ => null,
    };
    final name = _keyNames[key];
    return name == null ? c.label : 'Change $name';
  }

  static const _keyNames = {
    'Title': 'romanised title',
    'TitleUnicode': 'title',
    'Artist': 'romanised artist',
    'ArtistUnicode': 'artist',
    'Creator': 'creator',
    'Version': 'difficulty name',
    'Source': 'source',
    'Tags': 'tags',
    'HPDrainRate': 'HP drain',
    'CircleSize': 'circle size',
    'OverallDifficulty': 'overall difficulty',
    'ApproachRate': 'approach rate',
    'SliderMultiplier': 'base slider velocity',
    'SliderTickRate': 'slider tick rate',
    'PreviewTime': 'preview time',
    'SampleSet': 'default sample set',
    'AudioLeadIn': 'audio lead-in',
    'StackLeniency': 'stack leniency',
    'Countdown': 'countdown',
    'CountdownOffset': 'countdown offset',
    'LetterboxInBreaks': 'letterbox during breaks',
    'WidescreenStoryboard': 'widescreen storyboard',
    'EpilepsyWarning': 'epilepsy warning',
    'AudioFilename': 'audio file',
    'GridSize': 'grid size',
    'DistanceSpacing': 'distance spacing',
  };
}
