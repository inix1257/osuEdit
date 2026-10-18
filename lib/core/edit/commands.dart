import '../model/beatmap.dart';
import '../model/hit_object.dart';
import '../model/timing_point.dart';

/// An undoable mutation of a [Beatmap].
///
/// `apply` followed by `revert` must leave the beatmap exactly as before
/// (including object identities, so selections and caches stay valid).
abstract class EditCommand {
  String get label;
  void apply(Beatmap b);
  void revert(Beatmap b);
}

class CompositeCommand extends EditCommand {
  @override
  final String label;
  final List<EditCommand> commands;

  CompositeCommand(this.label, this.commands);

  @override
  void apply(Beatmap b) {
    for (final c in commands) {
      c.apply(b);
    }
  }

  @override
  void revert(Beatmap b) {
    for (final c in commands.reversed) {
      c.revert(b);
    }
  }
}

class AddHitObjectsCommand extends EditCommand {
  final List<HitObject> objects;
  AddHitObjectsCommand(this.objects);

  @override
  String get label => objects.length == 1 ? 'Add object' : 'Add ${objects.length} objects';

  @override
  void apply(Beatmap b) {
    for (final h in objects) {
      b.insertHitObject(h);
    }
  }

  @override
  void revert(Beatmap b) {
    for (final h in objects.reversed) {
      _mustRemove(b, h);
    }
  }
}

class RemoveHitObjectsCommand extends EditCommand {
  final List<HitObject> objects;
  RemoveHitObjectsCommand(this.objects);

  @override
  String get label => objects.length == 1 ? 'Delete object' : 'Delete ${objects.length} objects';

  @override
  void apply(Beatmap b) {
    for (final h in objects) {
      _mustRemove(b, h);
    }
  }

  @override
  void revert(Beatmap b) {
    for (final h in objects) {
      b.insertHitObject(h);
    }
  }
}

/// Replaces objects with modified copies (move, retime, change sounds...).
/// `before[i]` is replaced by `after[i]`.
class ReplaceHitObjectsCommand extends EditCommand {
  @override
  final String label;
  final List<HitObject> before;
  final List<HitObject> after;

  ReplaceHitObjectsCommand(this.before, this.after, {this.label = 'Modify objects'})
      : assert(before.length == after.length);

  @override
  void apply(Beatmap b) => _swap(b, before, after);

  @override
  void revert(Beatmap b) => _swap(b, after, before);

  static void _swap(Beatmap b, List<HitObject> from, List<HitObject> to) {
    // Remove all first, then insert: keeps ordering right when objects
    // pass each other in time.
    for (final h in from) {
      _mustRemove(b, h);
    }
    for (final h in to) {
      b.insertHitObject(h);
    }
  }
}

void _mustRemove(Beatmap b, HitObject h) {
  if (!b.removeHitObject(h)) {
    throw StateError('Hit object not in beatmap (stale reference): $h');
  }
}

class AddTimingPointCommand extends EditCommand {
  final TimingPoint point;
  AddTimingPointCommand(this.point);

  @override
  String get label => point.uninherited ? 'Add timing point' : 'Add inherited point';

  @override
  void apply(Beatmap b) => b.insertTimingPoint(point);

  @override
  void revert(Beatmap b) => _mustRemoveTp(b, point);
}

class RemoveTimingPointCommand extends EditCommand {
  final TimingPoint point;

  /// Original index, so revert restores the exact file order among points
  /// that share a time.
  int _index = -1;

  RemoveTimingPointCommand(this.point);

  @override
  String get label => 'Delete timing point';

  @override
  void apply(Beatmap b) {
    _index = b.indexOfTimingPoint(point);
    if (_index < 0) throw StateError('Timing point not in beatmap');
    b.timingPoints.removeAt(_index);
    b.revision++;
  }

  @override
  void revert(Beatmap b) {
    b.timingPoints.insert(_index, point);
    b.revision++;
  }
}

/// Swaps [before] for [after]. At the same time and kind the point keeps its
/// place in the list (a red point stays ahead of a green one at its time);
/// a moved point is re-inserted in time order. Revert restores the original
/// index.
class ReplaceTimingPointCommand extends EditCommand {
  final TimingPoint before;
  final TimingPoint after;
  ReplaceTimingPointCommand(this.before, this.after);

  int _index = -1;

  bool get _inPlace => before.time == after.time && before.uninherited == after.uninherited;

  @override
  String get label => 'Modify timing point';

  @override
  void apply(Beatmap b) {
    _index = b.indexOfTimingPoint(before);
    if (_index < 0) throw StateError('Timing point not in beatmap (stale reference)');
    if (_inPlace) {
      b.timingPoints[_index] = after;
      b.revision++;
    } else {
      b.timingPoints.removeAt(_index);
      b.insertTimingPoint(after);
    }
  }

  @override
  void revert(Beatmap b) {
    if (_inPlace) {
      final i = b.indexOfTimingPoint(after);
      if (i < 0) throw StateError('Timing point not in beatmap (stale reference)');
      b.timingPoints[i] = before;
    } else {
      _mustRemoveTp(b, after);
      b.timingPoints.insert(_index, before);
    }
    b.revision++;
  }
}

void _mustRemoveTp(Beatmap b, TimingPoint t) {
  if (!b.removeTimingPoint(t)) {
    throw StateError('Timing point not in beatmap (stale reference)');
  }
}

/// Sets a key in a key-value section (`[Metadata]` Title, `[Difficulty]`
/// CircleSize...). Revert restores the original entry verbatim (raw line and
/// position), or removes the key if it didn't exist.
class SetValueCommand extends EditCommand {
  final String section;
  final String key;
  final String value;

  KeyValueEntry? _old;
  int _oldIndex = -1;
  bool _createdSection = false;

  SetValueCommand(this.section, this.key, this.value);

  @override
  String get label => 'Set $key';

  @override
  void apply(Beatmap b) {
    final s = b.keyValueSection(section);
    _createdSection = s == null;
    if (s != null) {
      _oldIndex = s.indexOfKey(key);
      _old = _oldIndex >= 0 ? s.entries[_oldIndex] : null;
    }
    b.setValue(section, key, value);
  }

  @override
  void revert(Beatmap b) {
    if (_createdSection) {
      b.sections.removeWhere((x) => x is KeyValueSection && x.name == section);
      b.revision++;
      return;
    }
    final s = b.keyValueSection(section)!;
    final i = s.indexOfKey(key);
    if (_old == null) {
      if (i >= 0) s.entries.removeAt(i);
    } else {
      s.entries[i] = _old!;
    }
    b.revision++;
  }
}

/// Removes `key` from a key/value section (no-op if absent). Revert puts the
/// original entry back at its old index.
class RemoveValueCommand extends EditCommand {
  final String section;
  final String key;

  KeyValueEntry? _old;
  int _oldIndex = -1;

  RemoveValueCommand(this.section, this.key);

  @override
  String get label => 'Remove $key';

  @override
  void apply(Beatmap b) {
    final s = b.keyValueSection(section);
    _oldIndex = s?.indexOfKey(key) ?? -1;
    if (_oldIndex < 0) {
      _old = null;
      return;
    }
    _old = s!.entries.removeAt(_oldIndex);
    b.revision++;
  }

  @override
  void revert(Beatmap b) {
    final old = _old;
    if (old == null) return;
    b.keyValueSection(section)!.entries.insert(_oldIndex, old);
    b.revision++;
  }
}

/// Sets the background image (`0,0,"bg.jpg",0,0` in `[Events]`). An
/// existing background line keeps its position and offsets; otherwise a new
/// line goes under the `//Background and Video events` comment (or first).
/// Creates `[Events]` (before `[TimingPoints]`) if the map has none.
class SetBackgroundCommand extends EditCommand {
  final String fileName;
  SetBackgroundCommand(this.fileName);

  static final _bgLine = RegExp(r'^(\s*(?:0|Background)\s*,\s*[^,]*,\s*)("[^"]*"|[^,]*)(.*)$');

  RawSection? _created;
  int _index = -1;
  String? _oldLine;

  @override
  String get label => 'Set background';

  @override
  void apply(Beatmap b) {
    var events = _eventsOf(b);
    if (events == null) {
      events = _created = RawSection(SectionNames.events);
      final at = b.sections.indexWhere((s) => s.name == SectionNames.timingPoints);
      b.sections.insert(at < 0 ? b.sections.length : at, events);
    }
    final lines = events.lines;
    final newValue = '"$fileName"';
    _index = lines.indexWhere(_bgLine.hasMatch);
    if (_index >= 0) {
      _oldLine = lines[_index];
      final m = _bgLine.firstMatch(_oldLine!)!;
      lines[_index] = '${m.group(1)}$newValue${m.group(3)}';
    } else {
      _oldLine = null;
      _index = lines.indexWhere((l) => l.trim() == '//Background and Video events') + 1;
      lines.insert(_index, '0,0,$newValue,0,0');
    }
    b.revision++;
  }

  @override
  void revert(Beatmap b) {
    if (_created != null) {
      b.sections.remove(_created);
      _created = null;
    } else {
      final lines = _eventsOf(b)!.lines;
      if (_oldLine != null) {
        lines[_index] = _oldLine!;
      } else {
        lines.removeAt(_index);
      }
    }
    b.revision++;
  }

  static RawSection? _eventsOf(Beatmap b) {
    for (final s in b.sections) {
      if (s is RawSection && s.name == SectionNames.events) return s;
    }
    return null;
  }
}
