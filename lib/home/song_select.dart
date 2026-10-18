import 'dart:io';

import 'package:flutter/material.dart';

import '../platform/beatmap_library.dart';

/// Pieces of the osu!stable-style song select (home screen): the blurred-out
/// background, the info panel on the left and the set / difficulty cards of
/// the carousel on the right.

/// osu!lazer's star rating spectrum (`OsuColour.ForStarDifficulty`).
Color starRatingColor(double sr) {
  if (sr < 0.1) return const Color(0xFFAAAAAA);
  const stops = [0.1, 1.25, 2.0, 2.5, 3.3, 4.2, 4.9, 5.8, 6.7, 7.7, 9.0];
  const colors = [
    Color(0xFF4290FB), Color(0xFF4FC0FF), Color(0xFF4FFFD5), Color(0xFF7CFF4F), //
    Color(0xFFF6F05C), Color(0xFFFF8068), Color(0xFFFF4E6F), Color(0xFFC645B8),
    Color(0xFF6563DE), Color(0xFF18158E), Color(0xFF000000),
  ];
  if (sr >= stops.last) return colors.last;
  var i = 0;
  while (sr > stops[i + 1]) {
    i++;
  }
  final t = (sr - stops[i]) / (stops[i + 1] - stops[i]);
  return Color.lerp(colors[i], colors[i + 1], t)!;
}

/// Text on a [starRatingColor] background (lazer: yellow on the dark end).
Color starRatingTextColor(double sr) => sr >= 6.5 ? const Color(0xFFFFD966) : const Color(0xBF000000);

const _accent = Color(0xFFFF66AA);

/// Resolved background image files, per set and file name (a few
/// `existsSync` calls each, so remembered).
class BackgroundFiles {
  final _cache = <String, File?>{};

  File? of(LibrarySet set) {
    final name = set.backgroundFile;
    if (name.isEmpty) return null;
    return _cache.putIfAbsent('${set.path}|$name', () => BeatmapLibrary.resolveFile(set.path, name));
  }

  void clear() => _cache.clear();
}

extension SongSelectInfo on LibrarySet {
  /// The first difficulty's background (osu! shows the selected one's).
  String get backgroundFile {
    for (final d in difficulties) {
      if (d.summary.backgroundFile.isNotEmpty) return d.summary.backgroundFile;
    }
    return '';
  }

  String get title => difficulties.isEmpty || difficulties.first.summary.title.isEmpty
      ? folderName
      : difficulties.first.summary.title;

  String get artist => difficulties.isEmpty ? '' : difficulties.first.summary.artist;

  /// Audio for the preview: the first difficulty's that has one.
  LibraryDifficulty? get previewSource {
    for (final d in difficulties) {
      if (d.summary.audioFilename.isNotEmpty) return d;
    }
    return null;
  }
}

/// A downscaled file image (decoded at [width] px at most).
ImageProvider fileImage(File file, int width) => ResizeImage(FileImage(file), width: width, policy: ResizeImagePolicy.fit);

/// The selected set's background, dimmed, cross-fading when it changes.
class SongSelectBackground extends StatelessWidget {
  final File? file;
  const SongSelectBackground({super.key, this.file});

  @override
  Widget build(BuildContext context) {
    final f = file;
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF2A1630), Color(0xFF101828)],
            ),
          ),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          child: f == null
              ? const SizedBox.expand()
              : Image(
                  key: ValueKey(f.path),
                  image: fileImage(f, 1280),
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.expand(),
                ),
        ),
        // Dim (darker behind the info panel on the left).
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xCC000000), Color(0x8C000000), Color(0xA6000000)],
              stops: [0, 0.5, 1],
            ),
          ),
        ),
      ],
    );
  }
}

String _formatLength(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String _formatBpm(double min, double max) {
  String f(double v) {
    final t = v.toStringAsFixed(1);
    return t.endsWith('.0') ? t.substring(0, t.length - 2) : t;
  }
  if (max <= 0) return '-';
  return (max - min).abs() < 0.05 ? f(max) : '${f(min)}–${f(max)}';
}

/// Top-left panel: the selected set and the stats of its selected
/// difficulty (like osu!stable's song info).
class MapInfoPanel extends StatelessWidget {
  final LibrarySet set;

  /// The difficulty whose stats are shown (null: the set has none).
  final LibraryDifficulty? difficulty;

  /// Opens the map's osu! website page; null when it has none (not
  /// submitted), which shows the button disabled.
  final VoidCallback? onOpenPage;

  const MapInfoPanel({super.key, required this.set, required this.difficulty, this.onOpenPage});

  @override
  Widget build(BuildContext context) {
    final d = difficulty;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0x99000000),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(set.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800, height: 1.15)),
                  if (set.artist.isNotEmpty)
                    Text(set.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70, fontSize: 13.5, fontWeight: FontWeight.w600)),
                  if (set.creator.isNotEmpty)
                    Text.rich(
                      TextSpan(children: [
                        const TextSpan(text: 'Mapped by ', style: TextStyle(color: Colors.white60)),
                        TextSpan(text: set.creator, style: const TextStyle(color: _accent, fontWeight: FontWeight.w700)),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            MapPageButton(onPressed: onOpenPage),
          ]),
          if (d != null) ...[
            const SizedBox(height: 8),
            _DifficultyStats(difficulty: d),
          ],
        ],
      ),
    );
  }
}

/// "Map page ↗": opens the map's page on the osu! website.
class MapPageButton extends StatelessWidget {
  /// Null: the map isn't submitted (disabled).
  final VoidCallback? onPressed;
  const MapPageButton({super.key, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: enabled ? 'Open the beatmap page on osu.ppy.sh' : 'Not submitted: no beatmap page',
      child: Material(
        color: enabled ? _accent.withValues(alpha: 0.22) : Colors.white10,
        shape: StadiumBorder(side: BorderSide(color: enabled ? _accent : Colors.white24)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(Icons.open_in_new, size: 16, color: enabled ? Colors.white : Colors.white38),
          ),
        ),
      ),
    );
  }
}

class _DifficultyStats extends StatelessWidget {
  final LibraryDifficulty difficulty;
  const _DifficultyStats({required this.difficulty});

  static const _label = TextStyle(color: Colors.white60, fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.4);
  static const _value = TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700);

  /// "Circle 725": name and count in different colours.
  static Widget _count(String name, int n) => Padding(
        padding: const EdgeInsets.only(right: 14),
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: '$name ', style: const TextStyle(color: _accent, fontWeight: FontWeight.w700)),
            TextSpan(text: '$n', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
          ]),
          style: const TextStyle(fontSize: 13),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final d = difficulty;
    final s = d.summary;
    final sr = d.starRating;
    final color = sr == null ? Colors.white54 : starRatingColor(sr);
    Widget stat(Widget icon, String name, String v) => Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            icon,
            const SizedBox(width: 4),
            if (name.isNotEmpty) ...[Text(name, style: _label), const SizedBox(width: 4)],
            Text(v, style: _value),
          ]),
        );
    Icon icon(IconData i) => Icon(i, size: 13, color: _accent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Which difficulty: its colour, name and SR.
        Row(children: [
          Container(width: 4, height: 18, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 7),
          Expanded(
            child: Text(s.version.isEmpty ? d.fileName : s.version,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 6),
          _SrPill(difficulty: d),
        ]),
        const SizedBox(height: 7),
        Wrap(runSpacing: 4, children: [
          stat(icon(Icons.schedule), 'LENGTH', _formatLength(s.lastObjectTime)),
          stat(icon(Icons.music_note), 'BPM', _formatBpm(s.minBpm, s.maxBpm)),
          stat(icon(Icons.bubble_chart), 'OBJECTS', '${s.hitObjectCount}'),
        ]),
        const SizedBox(height: 4),
        Wrap(runSpacing: 4, children: [
          _count('Circle', s.circleCount),
          _count('Slider', s.sliderCount),
          _count('Spinner', s.spinnerCount),
        ]),
        const SizedBox(height: 8),
        _StatBar(name: s.mode == 3 ? 'Keys' : 'CS', value: s.circleSize),
        if (s.mode != 3 && s.mode != 1) _StatBar(name: 'AR', value: s.approachRate),
        _StatBar(name: 'OD', value: s.overallDifficulty),
        _StatBar(name: 'HP', value: s.hpDrain),
      ],
    );
  }
}

/// "CS ▬▬▬▬──── 4.2": a 0–10 difficulty setting.
class _StatBar extends StatelessWidget {
  final String name;
  final double value;
  const _StatBar({required this.name, required this.value});

  @override
  Widget build(BuildContext context) {
    final v = value.toStringAsFixed(1);
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(children: [
        SizedBox(
          width: 34,
          child: Text(name, style: _DifficultyStats._label),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 6,
              child: Stack(fit: StackFit.expand, children: [
                const ColoredBox(color: Colors.white12),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: (value / 10).clamp(0.0, 1.0),
                  child: const ColoredBox(color: Colors.white),
                ),
              ]),
            ),
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(v.endsWith('.0') ? v.substring(0, v.length - 2) : v,
              textAlign: TextAlign.right, style: _DifficultyStats._value),
        ),
      ]),
    );
  }
}

/// One set in the carousel: background thumbnail, title, artist // mapper,
/// a dot per difficulty. The open one slides out to the left.
class SetCard extends StatelessWidget {
  final LibrarySet set;
  final bool expanded;
  final File? background;
  final VoidCallback onTap;
  final Widget menu;

  const SetCard({
    super.key,
    required this.set,
    required this.expanded,
    required this.background,
    required this.onTap,
    required this.menu,
  });

  static const height = 70.0;

  /// Vertical space between cards (above + below).
  static const gap = 6.0;

  @override
  Widget build(BuildContext context) {
    final bg = background;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(left: expanded ? 0 : 22, top: gap / 2, bottom: gap / 2),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFF221B2C),
          borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)),
          border: Border.all(color: expanded ? Colors.white : Colors.white24, width: expanded ? 2 : 1),
          boxShadow: [
            BoxShadow(color: expanded ? const Color(0x66FF66AA) : const Color(0x55000000), blurRadius: expanded ? 14 : 6),
          ],
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.horizontal(left: Radius.circular(10)),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (bg != null)
                    Image(
                      image: fileImage(bg, 480),
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const SizedBox(),
                    ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [Color(0xE6000000), Color(0x80000000), Color(0x40000000)]),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 0, 6),
                    child: Row(children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(set.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
                            Text(
                              [if (set.artist.isNotEmpty) set.artist, if (set.creator.isNotEmpty) set.creator].join(' // '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 4),
                            _DifficultyDots(set: set),
                          ],
                        ),
                      ),
                      menu,
                    ]),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DifficultyDots extends StatelessWidget {
  final LibrarySet set;
  const _DifficultyDots({required this.set});

  static const _max = 14;

  @override
  Widget build(BuildContext context) {
    final diffs = set.difficulties;
    return Row(children: [
      for (final d in diffs.take(_max))
        Container(
          width: 9,
          height: 9,
          margin: const EdgeInsets.only(right: 3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: d.starRating == null ? Colors.white38 : starRatingColor(d.starRating!),
            border: Border.all(color: Colors.white38, width: 0.75),
          ),
        ),
      if (diffs.length > _max)
        Text('+${diffs.length - _max}', style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w700)),
    ]);
  }
}

/// One difficulty of the open set: tap to select it (its stats show on the
/// left), tap the selected one to edit it.
class DifficultyCard extends StatelessWidget {
  final LibraryDifficulty difficulty;
  final String creator;
  final bool selected;
  final VoidCallback onTap;

  /// Long press: where on screen, to open a drop-down menu there.
  final void Function(Offset globalPosition)? onMenu;

  const DifficultyCard(
      {super.key,
      required this.difficulty,
      required this.creator,
      this.selected = false,
      required this.onTap,
      this.onMenu});

  static const _modeNames = ['osu!', 'taiko', 'catch', 'mania'];

  @override
  Widget build(BuildContext context) {
    final d = difficulty;
    final s = d.summary;
    final sr = d.starRating;
    final color = sr == null ? Colors.white54 : starRatingColor(sr);
    final mode = s.mode >= 0 && s.mode < _modeNames.length ? _modeNames[s.mode] : 'mode ${s.mode}';
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      // The selected one slides out a little, like the open set.
      padding: EdgeInsets.only(left: selected ? 22 : 34, top: 2, bottom: 2),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 54,
        decoration: BoxDecoration(
          color: Color.alphaBlend(color.withValues(alpha: selected ? 0.32 : 0.16), const Color(0xE6181420)),
          borderRadius: const BorderRadius.horizontal(left: Radius.circular(10)),
          border: selected ? Border.all(color: Colors.white, width: 2) : Border.all(color: color.withValues(alpha: 0.55)),
          boxShadow: selected ? [BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 12)] : null,
        ),
        child: GestureDetector(
          onLongPressStart: onMenu == null ? null : (d) => onMenu!(d.globalPosition),
          child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: const BorderRadius.horizontal(left: Radius.circular(10)),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(children: [
                _ModeIcon(color: color, mode: s.mode),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(s.version.isEmpty ? d.fileName : s.version,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 1),
                      Row(children: [
                        if (sr != null) ...[_StarRow(sr: sr, color: color), const SizedBox(width: 6)],
                        Flexible(
                          child: Text(
                            '${s.mode == 0 ? '' : '$mode · '}${s.hitObjectCount} objects',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white60, fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ]),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _SrPill(difficulty: d),
                const SizedBox(width: 2),
              ]),
            ),
          ),
        ),
        ),
      ),
    );
  }
}

class _ModeIcon extends StatelessWidget {
  final Color color;
  final int mode;
  const _ModeIcon({required this.color, required this.mode});

  @override
  Widget build(BuildContext context) => Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 3),
          color: Colors.black26,
        ),
        alignment: Alignment.center,
        child: mode == 0
            ? Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: color))
            : Text(['', 'T', 'C', 'M'][mode.clamp(0, 3)],
                style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w900)),
      );
}

/// osu!stable's star row: one star per point, the last one partial.
class _StarRow extends StatelessWidget {
  final double sr;
  final Color color;
  const _StarRow({required this.sr, required this.color});

  static const _max = 10;

  @override
  Widget build(BuildContext context) {
    final full = sr.floor().clamp(0, _max);
    final part = full >= _max ? 0.0 : sr - sr.floor();
    // Dark star colours vanish on the dark card.
    final c = color.computeLuminance() < 0.08 ? const Color(0xFFFFD966) : color;
    Widget star(double scale) => SizedBox(
          width: 11,
          height: 11,
          child: Center(child: Icon(Icons.star_rounded, size: 11 * (0.35 + 0.65 * scale), color: c)),
        );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < full; i++) star(1),
      if (part > 0.05) star(part),
    ]);
  }
}

class _SrPill extends StatelessWidget {
  final LibraryDifficulty difficulty;
  const _SrPill({required this.difficulty});

  @override
  Widget build(BuildContext context) {
    final sr = difficulty.starRating;
    if (sr == null && !difficulty.starRatingPending) return const SizedBox();
    final bg = sr == null ? Colors.white24 : starRatingColor(sr);
    final fg = sr == null ? Colors.white70 : starRatingTextColor(sr);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(
        sr == null ? '★ …' : '★ ${sr.toStringAsFixed(2)}',
        style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w800),
      ),
    );
  }
}

/// What [LoadingOverlay] shows: the difficulty being opened.
class OpeningMap {
  final String title;
  final String version;

  /// Its star rating colour (null: unrated).
  final Color? color;

  /// The headline under the spinner.
  final String message;
  const OpeningMap({required this.title, this.version = '', this.color, this.message = 'Loading…'});
}

/// Dims the whole song select while a difficulty loads, with a spinner and
/// what is loading in the middle; swallows taps meanwhile. Fades in / out.
class LoadingOverlay extends StatefulWidget {
  /// Null: hidden.
  final OpeningMap? opening;
  const LoadingOverlay({super.key, this.opening});

  @override
  State<LoadingOverlay> createState() => _LoadingOverlayState();
}

class _LoadingOverlayState extends State<LoadingOverlay> {
  /// Kept while fading out so the text doesn't vanish first.
  OpeningMap? _last;

  @override
  Widget build(BuildContext context) {
    final shown = widget.opening != null;
    final o = _last = widget.opening ?? _last;
    final color = o?.color ?? _accent;
    return IgnorePointer(
      ignoring: !shown,
      child: AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        child: o == null
            ? const SizedBox.expand()
            : Stack(fit: StackFit.expand, children: [
                // Swallows taps under the dim.
                const ModalBarrier(dismissible: false, color: Color(0xB8000000)),
                Center(
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 340),
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
                    decoration: BoxDecoration(
                      color: const Color(0xF0181420),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: color.withValues(alpha: 0.85), width: 1.5),
                      boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 24)],
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      SizedBox(
                        width: 38,
                        height: 38,
                        child: CircularProgressIndicator(strokeWidth: 4, color: color, backgroundColor: Colors.white12),
                      ),
                      const SizedBox(height: 14),
                      Text(o.message,
                          style: TextStyle(
                              color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 0.3)),
                      const SizedBox(height: 4),
                      Text(o.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70, fontSize: 12.5, fontWeight: FontWeight.w600)),
                      if (o.version.isNotEmpty)
                        Text('[${o.version}]',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Color.lerp(color, Colors.white, 0.35), fontSize: 13, fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ),
              ]),
      ),
    );
  }
}
