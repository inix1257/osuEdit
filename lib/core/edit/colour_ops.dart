import '../model/beatmap.dart';
import 'commands.dart';

/// An opaque RGB colour (0-255 each), as `[Colours]` stores it.
class RgbColour {
  final int r;
  final int g;
  final int b;

  const RgbColour(this.r, this.g, this.b);

  /// `#RRGGBB`.
  String get hex => '#${[r, g, b].map((v) => v.toRadixString(16).padLeft(2, '0')).join().toUpperCase()}';

  /// Parses `#RRGGBB` / `RRGGBB` (case-insensitive); null otherwise.
  static RgbColour? parseHex(String s) {
    final m = RegExp(r'^\s*#?([0-9a-fA-F]{6})\s*$').firstMatch(s);
    if (m == null) return null;
    final v = int.parse(m.group(1)!, radix: 16);
    return RgbColour((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
  }

  @override
  bool operator ==(Object other) => other is RgbColour && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(r, g, b);

  @override
  String toString() => hex;
}

/// The map's combo colours (`Combo1` … `Combo8` in `[Colours]`).
abstract final class ComboColours {
  /// osu! reads at most eight.
  static const max = 8;

  static final _comboRe = RegExp(r'^\s*Combo(\d+)\s*:\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)');

  /// The combo colours in file order, as stable / lazer read them (the
  /// number is only range-checked). Empty when the map has none (the skin's
  /// then apply).
  static List<RgbColour> of(Beatmap b) {
    final found = <RgbColour>[];
    final s = _section(b);
    if (s == null) return found;
    for (final line in s.lines) {
      final m = _comboRe.firstMatch(line);
      if (m == null) continue;
      final n = int.parse(m.group(1)!);
      if (n < 1 || n > max) continue;
      int g(int i) => int.parse(m.group(i)!).clamp(0, 255);
      found.add(RgbColour(g(2), g(3), g(4)));
    }
    return found;
  }

  static bool isComboLine(String line) => _comboRe.hasMatch(line);

  /// `SliderTrackOverride` (slider body colour instead of the combo
  /// colour) and `SliderBorder` keys of `[Colours]`.
  static const sliderTrack = 'SliderTrackOverride';
  static const sliderBorder = 'SliderBorder';

  static RegExp _keyRe(String key) => RegExp('^\\s*$key\\s*:\\s*(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)');

  /// The colour of `[Colours]` [key] (e.g. [sliderTrack]), or null when the
  /// map doesn't set it (the last line wins, like osu!).
  static RgbColour? colourOf(Beatmap b, String key) {
    final s = _section(b);
    if (s == null) return null;
    final re = _keyRe(key);
    RgbColour? found;
    for (final line in s.lines) {
      final m = re.firstMatch(line);
      if (m == null) continue;
      int g(int i) => int.parse(m.group(i)!).clamp(0, 255);
      found = RgbColour(g(1), g(2), g(3));
    }
    return found;
  }

  static RawSection? _section(Beatmap b) {
    for (final s in b.sections) {
      if (s is RawSection && s.name == SectionNames.colours) return s;
    }
    return null;
  }
}

/// Replaces the map's combo colours with [colours] (at most
/// [ComboColours.max]; empty = none, the skin's apply), written
/// `Combo1 : r,g,b` like stable where the first old combo line was (else
/// first). Other `[Colours]` lines (slider colours, comments) stay. Creates
/// `[Colours]` (before `[HitObjects]`) when needed; revert restores the
/// section exactly.
class SetComboColoursCommand extends EditCommand {
  final List<RgbColour> colours;

  SetComboColoursCommand(List<RgbColour> colours)
      : colours = List.unmodifiable(colours.take(ComboColours.max));

  RawSection? _created;
  List<String>? _oldLines;

  @override
  String get label => 'Change combo colours';

  @override
  void apply(Beatmap b) {
    var s = ComboColours._section(b);
    if (s == null) {
      if (colours.isEmpty) return;
      s = _created = RawSection(SectionNames.colours);
      final at = b.sections.indexWhere((x) => x.name == SectionNames.hitObjects);
      b.sections.insert(at < 0 ? b.sections.length : at, s);
    }
    _oldLines = List.of(s.lines);
    final lines = s.lines;
    var at = lines.indexWhere(ComboColours.isComboLine);
    lines.removeWhere(ComboColours.isComboLine);
    if (at < 0 || at > lines.length) at = 0;
    lines.insertAll(at, [
      for (var i = 0; i < colours.length; i++) 'Combo${i + 1} : ${colours[i].r},${colours[i].g},${colours[i].b}',
    ]);
    b.revision++;
  }

  @override
  void revert(Beatmap b) {
    final created = _created;
    if (created != null) {
      b.sections.remove(created);
      _created = null;
    } else {
      final old = _oldLines;
      if (old == null) return; // nothing was applied
      ComboColours._section(b)!.lines
        ..clear()
        ..addAll(old);
    }
    _oldLines = null;
    b.revision++;
  }
}

/// Sets `[Colours]` [key] (`SliderTrackOverride`, `SliderBorder`) to
/// [colour], or removes it (null: the default applies). An existing line is
/// rewritten in place (extra ones removed); a new one goes after the combo
/// colours. Creates `[Colours]` (before `[HitObjects]`) when needed; revert
/// restores the section exactly.
class SetColourKeyCommand extends EditCommand {
  final String key;
  final RgbColour? colour;

  SetColourKeyCommand(this.key, this.colour);

  RawSection? _created;
  List<String>? _oldLines;

  @override
  String get label => 'Change ${key == ComboColours.sliderTrack ? 'slider track' : key == ComboColours.sliderBorder ? 'slider border' : key} colour';

  @override
  void apply(Beatmap b) {
    final c = colour;
    var s = ComboColours._section(b);
    if (s == null) {
      if (c == null) return;
      s = _created = RawSection(SectionNames.colours);
      final at = b.sections.indexWhere((x) => x.name == SectionNames.hitObjects);
      b.sections.insert(at < 0 ? b.sections.length : at, s);
    }
    _oldLines = List.of(s.lines);
    final lines = s.lines;
    final re = ComboColours._keyRe(key);
    var at = lines.indexWhere(re.hasMatch);
    lines.removeWhere(re.hasMatch);
    if (c != null) {
      if (at < 0 || at > lines.length) {
        final lastCombo = lines.lastIndexWhere(ComboColours.isComboLine);
        at = lastCombo + 1;
      }
      lines.insert(at, '$key : ${c.r},${c.g},${c.b}');
    }
    b.revision++;
  }

  @override
  void revert(Beatmap b) {
    final created = _created;
    if (created != null) {
      b.sections.remove(created);
      _created = null;
    } else {
      final old = _oldLines;
      if (old == null) return;
      ComboColours._section(b)!.lines
        ..clear()
        ..addAll(old);
    }
    _oldLines = null;
    b.revision++;
  }
}
