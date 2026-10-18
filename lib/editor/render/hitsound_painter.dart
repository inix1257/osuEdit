import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../../app_fonts.dart';
import '../../core/core.dart';
import '../editor_controller.dart';
import 'timeline_painter.dart';

/// The rows under the Hitsound screen's timeline, top to bottom.
enum HitsoundLayer {
  /// The timing points' sample settings (what notes inherit).
  timing('Timing'),
  sampleSet('Sampleset'),
  additions('Additions'),
  whistle('Whistle'),
  finish('Finish'),
  clap('Clap');

  final String label;
  const HitsoundLayer(this.label);
}

/// Where the Hitsound screen's parts go for a grid [height]: the timeline
/// strip on top, then one equal row per [HitsoundLayer].
class HitsoundGeometry {
  final double height;
  final double rulerHeight;
  final double rowHeight;

  HitsoundGeometry(this.height)
      : rulerHeight = (height * 0.3).clamp(40.0, 88.0),
        rowHeight = math.max(0.0, height - (height * 0.3).clamp(40.0, 88.0)) / HitsoundLayer.values.length;

  /// The top of [layer]'s row.
  double rowTop(HitsoundLayer layer) => rulerHeight + rowHeight * layer.index;

  /// The layer row at [y], or null on the timeline strip.
  HitsoundLayer? layerAt(double y) {
    if (y < rulerHeight || rowHeight <= 0) return null;
    final i = ((y - rulerHeight) / rowHeight).floor();
    return i < HitsoundLayer.values.length ? HitsoundLayer.values[i] : null;
  }
}

/// The Hitsound screen's timeline and its layers, like a DAW's playlist:
/// time runs left to right at the top timeline's zoom with the playhead in
/// the middle; the strip on top shows beat ticks, the waveform, timing
/// points and the objects; below, one row per [HitsoundLayer] shows each
/// sounding point (circles, slider heads / repeats / tails, spinner ends):
/// its sample set (inherited ones hollow) with the custom sample index
/// under the letter, its addition set when it has additions, and whistle / finish /
/// clap. A note with its own sample file shows "F" and its additions faded
/// (only the file plays). Slider bodies show as bars from head to tail (the
/// sliderslide set, and the sliderwhistle set / whistle with body whistle),
/// slider ticks as dots on the sample set row; the addition set's colour
/// is washed faintly behind the Additions ... Clap rows. The Timing row
/// shows each timing point's set, index and volume; behind the Timing ... Clap rows
/// the timing points' volume runs as a translucent stepped area (taller =
/// louder), with tinted bars where an object sets its own volume.
class HitsoundPainter extends CustomPainter {
  final EditorController controller;

  HitsoundPainter(this.controller) : super(repaint: Listenable.merge([controller, controller.time]));

  static const _bg = Color(0xFF15171B);
  static const _rowA = Color(0xFF1C1F24);
  static const _rowB = Color(0xFF202329);
  static const _selection = Color(0xFFFFA726);

  /// Sample set colours (normal, soft, drum).
  static Color setColour(int set) => switch (set) {
        SampleSet.soft => const Color(0xFF7BD389),
        SampleSet.drum => const Color(0xFFFFB454),
        _ => const Color(0xFF5DB8F5),
      };

  static String setLetter(int set) => switch (set) {
        SampleSet.soft => 'S',
        SampleSet.drum => 'D',
        _ => 'N',
      };

  /// A note playing its own sample file.
  static const fileColour = Color(0xFFB39DDB);

  static const whistleColour = Color(0xFF4DD0E1);
  static const finishColour = Color(0xFFFFD54F);
  static const clapColour = Color(0xFFF06292);

  static const _volumeFill = Color(0x14FFFFFF);
  static const _volumeEdge = Color(0x40FFFFFF);
  static const _volumeOwn = Color(0x38FFB74D);
  static const _volumeOwnEdge = Color(0x99FFB74D);


  /// Note blocks are this share of a 1/4 beat wide at the current zoom
  /// (so they grow and shrink with it), within [minNoteWidth] ..
  /// [maxNoteWidth] logical pixels; too narrow for a letter, they drop it.
  static const _noteBeatShare = 0.85;
  static const minNoteWidth = 3.0;
  static const maxNoteWidth = 36.0;

  /// Width of a note block at [time] for [controller]'s zoom.
  static double noteWidthAt(EditorController controller, double time) =>
      (controller.timing.beatLengthAt(time) / 4 * controller.timelineZoom * _noteBeatShare)
          .clamp(minNoteWidth, maxNoteWidth)
          .toDouble();

  static final Map<(String, String, double, Color), TextPainter> _labels = {};

  /// A set letter with an optional smaller suffix (a timing chip's
  /// volume), laid out once per text, size and colour.
  static TextPainter _label(String letter, String suffix, double size, Color colour) =>
      _labels[(letter, suffix, size, colour)] ??= (TextPainter(
        text: TextSpan(
          text: letter,
          style: TextStyle(color: colour, fontSize: size, fontFamily: kUiFont, fontWeight: FontWeight.w700),
          children: [
            if (suffix.isNotEmpty)
              TextSpan(text: suffix, style: TextStyle(fontSize: size * 0.72, fontWeight: FontWeight.w600)),
          ],
        ),
        textDirection: TextDirection.ltr,
      )..layout());

  static final Map<(String, String, double, Color), TextPainter> _stacked = {};

  /// A set letter with a smaller [index] under it (none when empty), so a
  /// note block keeps its width; shrinks to fit [maxHeight].
  static TextPainter _stackedLabel(String letter, String index, double size, double maxHeight, Color colour) {
    if (index.isNotEmpty) size = math.min(size, ((maxHeight - 2) / 1.72).floorToDouble());
    return _stacked[(letter, index, size, colour)] ??= (TextPainter(
      text: TextSpan(
        text: letter,
        style: TextStyle(color: colour, fontSize: size, fontFamily: kUiFont, fontWeight: FontWeight.w700, height: 1),
        children: [
          if (index.isNotEmpty)
            TextSpan(text: '\n$index', style: TextStyle(fontSize: size * 0.72, fontWeight: FontWeight.w600)),
        ],
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout());
  }

  /// The index suffix shown after a set letter (none for built-in samples).
  static String indexSuffix(int index) => index > 0 ? '$index' : '';

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final g = HitsoundGeometry(h);
    final now = controller.time.value;
    final zoom = controller.timelineZoom;
    double x(double t) => TimelinePainter.xOf(t, now, zoom, w);
    final from = TimelinePainter.timeAt(-maxNoteWidth, now, zoom, w);
    final to = TimelinePainter.timeAt(w + maxNoteWidth, now, zoom, w);

    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = _bg);
    for (final layer in HitsoundLayer.values) {
      canvas.drawRect(
        Rect.fromLTWH(0, g.rowTop(layer), w, g.rowHeight),
        Paint()..color = layer.index.isEven ? _rowA : _rowB,
      );
    }

    final rulerMid = g.rulerHeight / 2;
    final wave = controller.showWaveform ? controller.waveform : null;
    if (wave != null) {
      TimelinePainter.drawWaveform(
          canvas, wave, controller.waveformOffsetMs, now, zoom, w, rulerMid, g.rulerHeight * 0.46);
    }

    // Beat grid: ticks on the strip, faint lines through the rows.
    final tick = Paint()..strokeWidth = 1;
    for (final t in controller.timing.ticks(from, to, controller.divisor)) {
      final tx = x(t.time);
      final colour = TimelinePainter.tickColour(t.denominator);
      final len = t.isMeasureStart ? 1.0 : (t.denominator == 1 ? 0.7 : 0.45);
      tick
        ..color = colour.withValues(alpha: t.isMeasureStart ? 0.9 : 0.55)
        ..strokeWidth = t.isMeasureStart ? 2 : 1;
      canvas.drawLine(Offset(tx, rulerMid - g.rulerHeight * len / 2), Offset(tx, rulerMid + g.rulerHeight * len / 2), tick);
      tick
        ..color = colour.withValues(alpha: t.isMeasureStart ? 0.35 : (t.denominator == 1 ? 0.18 : 0.08))
        ..strokeWidth = t.isMeasureStart ? 1.5 : 1;
      canvas.drawLine(Offset(tx, g.rulerHeight), Offset(tx, h), tick);
    }

    // Timing points (green lines set the inherited sample sets).
    final markerH = g.rulerHeight * 0.14;
    for (final tp in controller.timing.points) {
      if (tp.time < from || tp.time > to) continue;
      final tx = x(tp.time);
      final c = tp.uninherited ? const Color(0xFFFF3B3B) : const Color(0xFF3BD16F);
      canvas.drawLine(Offset(tx, 0), Offset(tx, h), Paint()..color = c.withValues(alpha: 0.4));
      canvas.drawRect(Rect.fromLTWH(tx - 2, 0, 4, markerH), Paint()..color = c);
    }

    _drawObjects(canvas, from, to, x, rulerMid, g.rulerHeight * 0.22);
    canvas.drawLine(Offset(0, g.rulerHeight), Offset(w, g.rulerHeight), Paint()..color = const Color(0xFF34383F));

    _drawVolume(canvas, g, from, to, x);
    _drawTimingRow(canvas, g, from, to, x);
    _drawNotes(canvas, g, from, to, x);

    // Time outside the song.
    final shade = Paint()..color = const Color(0x99000000);
    final xZero = x(0);
    if (xZero > 0) canvas.drawRect(Rect.fromLTRB(0, 0, xZero, h), shade);
    final end = controller.maxTime;
    if (end.isFinite && x(end) < w) canvas.drawRect(Rect.fromLTRB(x(end), 0, w, h), shade);

    // Playhead.
    canvas.drawLine(
      Offset(w / 2, 0),
      Offset(w / 2, h),
      Paint()
        ..color = const Color(0xFFFFE066)
        ..strokeWidth = 2,
    );
  }

  /// Objects on the strip, like the top timeline: combo-coloured heads;
  /// sliders / spinners with a body, a tail (dark, ringed) and, for
  /// sliders, small rings where they repeat.
  void _drawObjects(Canvas canvas, double from, double to, double Function(double) x, double y, double r) {
    const rim = Color(0xFFFFFFFF);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = rim;
    final objs = controller.objectsInRange(from, to).toList();
    for (var i = objs.length - 1; i >= 0; i--) {
      final o = objs[i];
      final colour = controller.shownComboColourOf(o);
      final selected = controller.selection.contains(o);
      final x0 = x(o.time), end = controller.endTimeOf(o);
      if (end > o.time) {
        final x1 = x(end);
        final dark = Color.lerp(colour, const Color(0xFF000000), 0.45)!;
        final bar = RRect.fromLTRBR(x0, y - r * 0.7, x1, y + r * 0.7, Radius.circular(r * 0.7));
        if (selected) {
          canvas.drawRRect(bar.inflate(2), Paint()..color = _selection);
          canvas.drawCircle(Offset(x1, y), r + 2, Paint()..color = _selection);
        }
        canvas.drawRRect(bar, Paint()..color = dark);
        if (o is SliderObject && o.slides > 1) {
          final span = (end - o.time) / o.slides;
          for (var k = 1; k < o.slides; k++) {
            canvas.drawCircle(Offset(x(o.time + span * k), y), r * 0.62, ring);
          }
        }
        canvas.drawCircle(Offset(x1, y), r, Paint()..color = dark);
        canvas.drawCircle(Offset(x1, y), r, ring);
      }
      if (selected) canvas.drawCircle(Offset(x0, y), r + 2, Paint()..color = _selection);
      canvas.drawCircle(Offset(x0, y), r, Paint()..color = colour);
      canvas.drawCircle(Offset(x0, y), r, ring);
    }
  }

  static double _blockH(double rowH) => rowH - math.min(4.0, rowH * 0.15) * 2;
  static double _letterSize(double blockH) => (blockH * 0.6).clamp(8.0, 13.0).roundToDouble();

  /// Volume behind the Timing ... Clap rows (taller = louder; 100% fills
  /// up to the Timing row's top): the timing points' volume as one
  /// continuous stepped area across the whole timeline, notes or not;
  /// objects (and slider bodies) that set their own volume stand out on top
  /// of it as tinted bars. Drawn under the Timing row's chips.
  void _drawVolume(Canvas canvas, HitsoundGeometry g, double from, double to, double Function(double) x) {
    final rowH = g.rowHeight;
    if (rowH <= 4) return;
    final volTop = g.rowTop(HitsoundLayer.timing);
    final volBottom = g.rowTop(HitsoundLayer.clap) + rowH;
    final volH = volBottom - volTop;
    double volY(int v) => volBottom - volH * v / 100;
    final volPaint = Paint();
    final edgePaint = Paint()..strokeWidth = 1.5;

    void drawSteps(List<(double, int)> steps, double end, Color fill, Color edge) {
      volPaint.color = fill;
      edgePaint.color = edge;
      for (var k = 0; k < steps.length; k++) {
        final x0 = x(steps[k].$1), x1 = x(k + 1 < steps.length ? steps[k + 1].$1 : end);
        if (x1 <= x0) continue;
        final y = volY(steps[k].$2);
        canvas.drawRect(Rect.fromLTRB(x0, y, x1, volBottom), volPaint);
        canvas.drawLine(Offset(x0, y), Offset(x1, y), edgePaint);
        if (k > 0) canvas.drawLine(Offset(x0, volY(steps[k - 1].$2)), Offset(x0, y), edgePaint);
      }
    }

    final timing = controller.timing;
    final pts = timing.points;
    if (pts.isNotEmpty) {
      // From the point in effect at the left edge (the first point's volume
      // before it), then each point in view; a red and a green line at the
      // same time count once (the green one wins).
      final steps = <(double, int)>[(from, (timing.effectivePointAt(from) ?? pts.first).volume)];
      for (var i = Beatmap.lowerBound(pts, from, (p) => p.time); i < pts.length && pts[i].time <= to; i++) {
        final v = timing.effectivePointAt(pts[i].time)!.volume;
        if (v != steps.last.$2) steps.add((pts[i].time, v));
      }
      drawSteps(steps, to, _volumeFill, _volumeEdge);
    }
    for (final o in controller.objectsInRange(from, to)) {
      if (o is! SliderObject) continue;
      final body = controller.hitsoundBodyOf(o);
      if (body == null || body.volumeInherited) continue;
      drawSteps([(body.start, body.volume)], body.end, _volumeOwn, _volumeOwnEdge);
    }
    for (final n in controller.hitsoundNotesInRange(from, to)) {
      if (n.volumeInherited) continue;
      final xn = x(n.time), half = noteWidthAt(controller, n.time) / 2;
      final r = Rect.fromLTRB(xn - half, volY(n.volume), xn + half, volBottom);
      canvas.drawRect(r, volPaint..color = _volumeOwn);
      canvas.drawLine(r.topLeft, r.topRight, edgePaint..color = _volumeOwnEdge);
    }
  }

  /// The Timing row: a chip per timing point with the sample set (hollow =
  /// the map default), index and volume. The point in effect at the left
  /// edge keeps its chip pinned there; a chip that would overlap the
  /// previous one shows only its marker.
  void _drawTimingRow(Canvas canvas, HitsoundGeometry g, double from, double to, double Function(double) x) {
    final rowH = g.rowHeight;
    if (rowH <= 4) return;
    final blockH = _blockH(rowH);
    final top = g.rowTop(HitsoundLayer.timing) + (rowH - blockH) / 2;
    final beatmapDefault = controller.beatmap.defaultSampleSet;
    final defaultSet = beatmapDefault == 0 ? SampleSet.normal : beatmapDefault;
    final size = _letterSize(blockH);
    final points = controller.timing.points;
    var i = math.max(0, Beatmap.lowerBound(points, from, (p) => p.time) - 1);
    for (; i < points.length && points[i].time <= to; i++) {
      final tp = points[i];
      final tx = x(tp.time);
      final line = tp.uninherited ? const Color(0xFFFF3B3B) : const Color(0xFF3BD16F);
      final set = tp.sampleSet == 0 ? defaultSet : tp.sampleSet;
      final colour = setColour(set);
      final hollow = tp.sampleSet == 0;
      final textColour = hollow ? colour : const Color(0xFF101114);
      final letter = setLetter(set) + indexSuffix(tp.sampleIndex);
      TextPainter? label = _label(letter, ' ${tp.volume}%', size, textColour);
      final nextX = i + 1 < points.length ? x(points[i + 1].time) : double.infinity;
      // Pinned at the left edge while in effect there, but pushed off by
      // the next point's chip.
      var chipW = label.width + 10;
      final left = tx >= 0 ? tx : math.min(0.0, nextX - chipW - 2);
      // In view, the chip fills the gap to the next point (so it narrows as
      // the timeline zooms out), dropping the volume, then all text, then
      // becoming a marker. This depends only on that gap, never on the
      // chips drawn before it, so it can't flicker while scrolling.
      if (tx >= 0 && nextX - tx < chipW + 2) {
        chipW = nextX - tx - 2;
        final short = _label(letter, '', size, textColour);
        label = short.width + 10 <= chipW ? short : null;
        if (chipW < 8) {
          canvas.drawRect(Rect.fromLTWH(tx - 1.5, top, 3, blockH), Paint()..color = line);
          continue;
        }
      }
      final chip = RRect.fromRectAndRadius(Rect.fromLTWH(left, top, chipW, blockH), const Radius.circular(3));
      canvas.drawRRect(chip, Paint()..color = hollow ? colour.withValues(alpha: 0.25) : colour);
      if (hollow) {
        canvas.drawRRect(
          chip.deflate(0.75),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = colour,
        );
      }
      canvas.drawRect(Rect.fromLTWH(left, top, 3, blockH), Paint()..color = line);
      if (label != null && blockH >= 12) label.paint(canvas, Offset(left + 6, top + (blockH - label.height) / 2));
    }
  }

  void _drawNotes(Canvas canvas, HitsoundGeometry g, double from, double to, double Function(double) x) {
    final rowH = g.rowHeight;
    if (rowH <= 4) return;
    final blockH = _blockH(rowH);
    final letterSize = _letterSize(blockH);

    void drawBlock(HitsoundLayer layer, double t, Color colour,
        {bool hollow = false,
        String? letter,
        String suffix = '',
        bool selected = false,
        bool faded = false}) {
      // Filled: dark text on the fill; hollow: text in the colour. No text
      // when the block (zoomed out) is narrower than it.
      final width = noteWidthAt(controller, t);
      var label = letter == null || blockH < 12
          ? null
          : _stackedLabel(letter, suffix, letterSize, blockH, hollow ? colour : const Color(0xFF101114));
      if (label != null && label.width + 2 > width) label = null;
      final r = Rect.fromCenter(center: Offset(x(t), g.rowTop(layer) + rowH / 2), width: width, height: blockH);
      final rr = RRect.fromRectAndRadius(r, Radius.circular(math.min(math.min(3.0, blockH / 4), width / 3)));
      if (faded) {
        // Set on the object but not played (its own file plays instead).
        canvas.drawRRect(
          rr.deflate(0.75),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = colour.withValues(alpha: 0.35),
        );
        return;
      }
      if (selected) canvas.drawRRect(rr.inflate(2), Paint()..color = _selection);
      canvas.drawRRect(rr, Paint()..color = hollow ? colour.withValues(alpha: 0.28) : colour);
      if (hollow) {
        canvas.drawRRect(
          rr.deflate(0.75),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = colour,
        );
      }
      label?.paint(canvas, r.center - Offset(label.width / 2, label.height / 2));
    }

    // The addition set as a faint wash behind the Additions ... Clap rows:
    // a note-wide strip per note with additions (not for its own file, which
    // plays instead), head to tail for a body whistle; fainter when
    // inherited.
    final washTop = g.rowTop(HitsoundLayer.additions);
    final washBottom = g.rowTop(HitsoundLayer.clap) + rowH;
    final wash = Paint();
    void drawWash(double x0, double x1, int set, bool inherited) {
      wash.color = setColour(set).withValues(alpha: inherited ? 0.07 : 0.14);
      canvas.drawRect(Rect.fromLTRB(x0, washTop, x1, washBottom), wash);
    }

    for (final o in controller.objectsInRange(from, to)) {
      if (o is! SliderObject) continue;
      final body = controller.hitsoundBodyOf(o);
      if (body == null || !body.whistle) continue;
      drawWash(x(body.start), x(body.end), body.additionSet, body.additionInherited);
    }
    for (final n in controller.hitsoundNotesInRange(from, to)) {
      if (!n.hasAdditions || n.filename.isNotEmpty) continue;
      final xn = x(n.time), half = noteWidthAt(controller, n.time) / 2;
      drawWash(xn - half, xn + half, n.additionSet, n.additionInherited);
    }

    // Slider bodies (sliderslide / sliderwhistle while the ball rolls): a
    // bar from head to tail under the edge notes, on the sample set row and,
    // with body whistle, on the additions and whistle rows. Inherited sets
    // are fainter.
    final barH = math.max(3.0, blockH * 0.32);
    final bar = Paint();
    void drawBar(HitsoundLayer layer, double start, double end, Color colour, {bool faint = false}) {
      final mid = g.rowTop(layer) + rowH / 2;
      bar.color = colour.withValues(alpha: faint ? 0.3 : 0.6);
      canvas.drawRect(Rect.fromLTRB(x(start), mid - barH / 2, x(end), mid + barH / 2), bar);
    }

    for (final o in controller.objectsInRange(from, to)) {
      if (o is! SliderObject) continue;
      final body = controller.hitsoundBodyOf(o);
      if (body == null) continue;
      drawBar(HitsoundLayer.sampleSet, body.start, body.end, setColour(body.normalSet), faint: body.normalInherited);
      if (body.whistle) {
        drawBar(HitsoundLayer.additions, body.start, body.end, setColour(body.additionSet),
            faint: body.additionInherited);
        drawBar(HitsoundLayer.whistle, body.start, body.end, whistleColour);
      }
    }

    // Slider ticks: dots on the sample set row's body bar.
    final dot = Paint();
    final dotR = math.max(2.0, barH * 0.75);
    final dotY = g.rowTop(HitsoundLayer.sampleSet) + rowH / 2;
    for (final t in controller.hitsoundTicksInRange(from, to)) {
      final colour = setColour(t.set);
      dot.color = t.setInherited ? Color.lerp(colour, _bg, 0.35)! : colour;
      canvas.drawCircle(Offset(x(t.time), dotY), dotR, dot);
    }

    for (final n in controller.hitsoundNotesInRange(from, to)) {
      final selected = controller.selection.contains(n.object);
      final file = n.filename.isNotEmpty;
      final index = indexSuffix(n.index);
      if (file) {
        drawBlock(HitsoundLayer.sampleSet, n.time, fileColour, letter: 'F', selected: selected);
      } else {
        drawBlock(HitsoundLayer.sampleSet, n.time, setColour(n.normalSet),
            hollow: n.normalInherited, letter: setLetter(n.normalSet), suffix: index, selected: selected);
      }
      if (n.hasAdditions) {
        drawBlock(HitsoundLayer.additions, n.time, setColour(n.additionSet),
            hollow: n.additionInherited,
            letter: setLetter(n.additionSet),
            suffix: index,
            selected: selected,
            faded: file);
      }
      if (n.whistle) drawBlock(HitsoundLayer.whistle, n.time, whistleColour, selected: selected, faded: file);
      if (n.finish) drawBlock(HitsoundLayer.finish, n.time, finishColour, selected: selected, faded: file);
      if (n.clap) drawBlock(HitsoundLayer.clap, n.time, clapColour, selected: selected, faded: file);
    }
  }

  @override
  bool shouldRepaint(HitsoundPainter old) => old.controller != controller;
}
