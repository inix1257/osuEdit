import '../edit/colour_ops.dart';

/// The parts of a classic (osu!stable) skin's `skin.ini` the editor uses.
///
/// Read the way lazer's `LegacySkinDecoder` does: `Key: Value` lines per
/// section, `//` comments, unknown keys ignored, the last value wins
/// (combo colours are collected per number, in number order).
class SkinIni {
  /// `[General] Name`; null when the skin doesn't name itself.
  final String? name;
  final String? author;

  /// `[General] Version`: `latest` → [latestVersion]; a skin.ini without it
  /// is 1.0 (lazer); no skin.ini at all is the latest.
  final double version;

  /// `[Colours] Combo1`..`Combo8`, in number order; empty: none.
  final List<RgbColour> comboColours;
  final RgbColour? sliderBorder;
  final RgbColour? sliderTrackOverride;

  /// `[Colours] SliderBall`: the ball's tint (white when unset) unless
  /// [allowSliderBallTint] tints it with the combo colour.
  final RgbColour? sliderBall;
  final bool allowSliderBallTint;

  /// `[Fonts] HitCirclePrefix` (`default`; may name a sub-folder with `\`)
  /// and `HitCircleOverlap` (px the digits overlap, default −2 = 2 px apart).
  final String hitCirclePrefix;
  final double hitCircleOverlap;

  /// `[General] HitCircleOverlayAboveNumber` (also the old typo
  /// `HitCircleOverlayAboveNumer`), default true.
  final bool hitCircleOverlayAboveNumber;

  /// `[General] AnimationFramerate`: frames per second of animated
  /// elements that follow it; ≤ 0 (default −1): the whole animation in one
  /// second.
  final double animationFramerate;

  const SkinIni({
    this.animationFramerate = -1,
    this.name,
    this.author,
    this.version = latestVersion,
    this.comboColours = const [],
    this.sliderBorder,
    this.sliderTrackOverride,
    this.sliderBall,
    this.allowSliderBallTint = false,
    this.hitCirclePrefix = 'default',
    this.hitCircleOverlap = -2,
    this.hitCircleOverlayAboveNumber = true,
  });

  /// What `Version: latest` means (lazer's `LegacySkinConfiguration.LATEST_VERSION`).
  static const latestVersion = 2.7;

  /// A skin without a skin.ini.
  static const none = SkinIni();

  static SkinIni parse(String text) {
    String? section;
    final general = <String, String>{}, colours = <String, String>{}, fonts = <String, String>{};
    for (var line in text.split(RegExp(r'\r?\n|\r'))) {
      final comment = line.indexOf('//');
      if (comment >= 0) line = line.substring(0, comment);
      line = line.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('[') && line.endsWith(']')) {
        section = line.substring(1, line.length - 1).trim().toLowerCase();
        continue;
      }
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      final key = line.substring(0, colon).trim().toLowerCase(), value = line.substring(colon + 1).trim();
      switch (section) {
        case 'general':
          general[key] = value;
        case 'colours' || 'colors':
          colours[key] = value;
        case 'fonts':
          fonts[key] = value;
      }
    }

    final combos = <int, RgbColour>{};
    for (final e in colours.entries) {
      final m = RegExp(r'^combo(\d+)$').firstMatch(e.key);
      final c = _colour(e.value);
      if (m == null || c == null) continue;
      final n = int.parse(m.group(1)!);
      if (n >= 1 && n <= ComboColours.max) combos[n] = c;
    }
    final order = combos.keys.toList()..sort();

    bool flag(String? v, bool fallback) => v == null ? fallback : v == '1' || v.toLowerCase() == 'true';
    final version = general['version'];
    final overlay = general['hitcircleoverlayabovenumber'] ?? general['hitcircleoverlayabovenumer'];
    final name = general['name'], author = general['author'];
    return SkinIni(
      animationFramerate: double.tryParse(general['animationframerate'] ?? '') ?? -1,
      name: name == null || name.isEmpty ? null : name,
      author: author == null || author.isEmpty ? null : author,
      version: version == null
          ? 1.0
          : version.toLowerCase() == 'latest'
              ? latestVersion
              : double.tryParse(version) ?? latestVersion,
      comboColours: [for (final n in order) combos[n]!],
      sliderBorder: _colour(colours['sliderborder']),
      sliderTrackOverride: _colour(colours['slidertrackoverride']),
      sliderBall: _colour(colours['sliderball']),
      allowSliderBallTint: flag(general['allowsliderballtint'], false),
      hitCirclePrefix: _prefix(fonts['hitcircleprefix']) ?? 'default',
      hitCircleOverlap: double.tryParse(fonts['hitcircleoverlap'] ?? '') ?? -2,
      hitCircleOverlayAboveNumber: flag(overlay, true),
    );
  }

  /// `r,g,b` (an alpha after them is ignored); null if malformed.
  static RgbColour? _colour(String? v) {
    if (v == null) return null;
    final parts = v.split(',');
    if (parts.length < 3) return null;
    final c = [for (final p in parts.take(3)) int.tryParse(p.trim())];
    if (c.any((x) => x == null)) return null;
    return RgbColour(c[0]!.clamp(0, 255), c[1]!.clamp(0, 255), c[2]!.clamp(0, 255));
  }

  /// A path relative to the skin folder with `/` separators.
  static String? _prefix(String? v) {
    if (v == null) return null;
    final p = v.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '').trim();
    return p.isEmpty ? null : p;
  }
}
