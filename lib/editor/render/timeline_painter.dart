import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../../app_fonts.dart';
import '../../core/core.dart';
import '../editor_controller.dart';
import 'difficulty_graph.dart';
import 'playfield_painter.dart';

/// Horizontal timeline centred on the current time, compact like osu!stable's:
/// beat-snap ticks span the strip (centred, length by beat fraction), objects
/// sit on top of them in the middle, timing points are marked at the top.
class TimelinePainter extends CustomPainter {
  final EditorController controller;

  /// Timing mode: objects are drawn first (under the waveform, ticks and
  /// timing points) and translucent, without selection, numbers, the end
  /// handle or overlap badges — just context for placing timing points.
  final bool objectsInBackground;

  TimelinePainter(this.controller, {this.objectsInBackground = false})
      : super(repaint: Listenable.merge([controller, controller.time, controller.difficulty]));

  /// Opacity of the objects in [objectsInBackground] mode.
  static const backgroundObjectAlpha = 0.3;

  static const _bg = Color(0xFF15171B);
  static const _selection = Color(0xFFFFA726);
  static const _kiai = Color(0x99FF8A00);
  static const _bookmark = Color(0xFF4D8DFF);

  static const _waveColour = Color(0x5580A8D0);
  static const _waveStep = 2.0; // px per column
  static Float32List _wavePoints = Float32List(0);

  /// The song's envelope as mirrored vertical lines around [midY], one per
  /// [_waveStep] px column, in a single draw call. The waveform is in audio
  /// time; the screen shows audio time − [offset]. Also used by the
  /// Hitsound screen's timeline.
  static void drawWaveform(Canvas canvas, Waveform wave, double offset, double now, double zoom, double w,
      double midY, double half) {
    final columns = (w / _waveStep).ceil();
    if (_wavePoints.length < columns * 4) _wavePoints = Float32List(columns * 4);
    final pts = _wavePoints;
    var n = 0;
    for (var i = 0; i < columns; i++) {
      final x = i * _waveStep;
      final t0 = timeAt(x, now, zoom, w) + offset;
      final v = wave.peak(t0, t0 + _waveStep / zoom);
      if (v <= 0.01) continue;
      final y = v * half;
      pts[n++] = x;
      pts[n++] = midY - y;
      pts[n++] = x;
      pts[n++] = midY + y;
    }
    if (n == 0) return;
    canvas.drawRawPoints(
      ui.PointMode.lines,
      Float32List.sublistView(pts, 0, n),
      Paint()
        ..color = _waveColour
        ..strokeWidth = _waveStep,
    );
  }

  static void _band(Canvas canvas, double t0, double t1, double now, double zoom, double w, double y,
      double h, Paint paint) {
    final x0 = math.max(0.0, xOf(t0, now, zoom, w)), x1 = math.min(w, xOf(t1, now, zoom, w));
    if (x1 > x0) canvas.drawRect(Rect.fromLTRB(x0, y, x1, y + h), paint);
  }

  /// Tick colours by reduced beat fraction (lazer's palette).
  static Color tickColour(int denominator) => switch (denominator) {
        1 => const Color(0xFFFFFFFF),
        2 => const Color(0xFFED1121),
        3 => const Color(0xFF8866EE),
        4 => const Color(0xFF66CCFF),
        6 => const Color(0xFFEEAA00),
        8 => const Color(0xFFFFCC22),
        12 => const Color(0xFFCCCCCC),
        _ => const Color(0xFF888888),
      };

  /// Screen x of time [t].
  static double xOf(double t, double now, double zoom, double width) =>
      width / 2 + (t - now) * zoom;

  /// Time at screen x.
  static double timeAt(double x, double now, double zoom, double width) =>
      now + (x - width / 2) / zoom;

  /// Radius of object markers for a strip of height [h] (centred vertically).
  static double objectRadius(double h) => h * 0.27;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final now = controller.time.value;
    final zoom = controller.timelineZoom;
    final from = timeAt(0, now, zoom, w);
    final to = timeAt(w, now, zoom, w);

    // Long objects extend far past the edges; keep them off the neighbours.
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = _bg);

    final markerH = h * 0.14;
    final objY = h / 2;
    final objR = objectRadius(h);

    if (objectsInBackground) _drawObjects(canvas, from, to, now, zoom, w, objY, objR, alpha: backgroundObjectAlpha);

    // Compose shows the difficulty graph; the other modes keep the
    // song's waveform (timing and hitsounds are placed by ear).
    final graph = objectsInBackground ? null : controller.difficulty.value;
    final wave = objectsInBackground && controller.showWaveform ? controller.waveform : null;
    if (graph != null) {
      DifficultyGraph.paintRange(canvas, graph,
          from: from, to: to, x: (t) => xOf(t, now, zoom, w), top: h * 0.08, bottom: h);
    }
    if (wave != null) drawWaveform(canvas, wave, controller.waveformOffsetMs, now, zoom, w, objY, h * 0.46);

    final editable = !objectsInBackground;
    _drawBreaks(canvas, from, to, now, zoom, w, h, editable: editable);

    // Beat ticks, centred on the object line (measure starts span it all).
    final tickPaint = Paint()..strokeWidth = 1;
    for (final tick in controller.timing.ticks(from, to, controller.divisor)) {
      final x = xOf(tick.time, now, zoom, w);
      final len = tick.isMeasureStart
          ? 1.0
          : tick.denominator == 1
              ? 0.75
              : tick.denominator <= 2
                  ? 0.6
                  : 0.45;
      tickPaint
        ..color = tickColour(tick.denominator).withValues(alpha: tick.isMeasureStart ? 0.9 : 0.6)
        ..strokeWidth = tick.isMeasureStart ? 2 : 1;
      final half = h * len / 2;
      canvas.drawLine(Offset(x, objY - half), Offset(x, objY + half), tickPaint);
    }

    // Kiai time: a band along the bottom edge.
    final bandH = h * 0.1;
    final kiai = Paint()..color = _kiai;
    double? kiaiFrom;
    for (final tp in controller.timing.points) {
      if (tp.time > to) break;
      if (tp.kiai && kiaiFrom == null) kiaiFrom = tp.time;
      if (!tp.kiai && kiaiFrom != null) {
        if (tp.time >= from) _band(canvas, kiaiFrom, tp.time, now, zoom, w, h - bandH, bandH, kiai);
        kiaiFrom = null;
      }
    }
    if (kiaiFrom != null) _band(canvas, kiaiFrom, to, now, zoom, w, h - bandH, bandH, kiai);

    // Bookmarks: a hairline plus a marker at the bottom.
    for (final m in controller.beatmap.bookmarks) {
      if (m < from || m > to) continue;
      final x = xOf(m.toDouble(), now, zoom, w);
      canvas.drawLine(Offset(x, 0), Offset(x, h), Paint()..color = _bookmark.withValues(alpha: 0.45));
      canvas.drawRect(Rect.fromLTWH(x - 2, h - markerH, 4, markerH), Paint()..color = _bookmark);
    }

    // Timing points: a full-height hairline plus a marker at the top.
    for (final tp in controller.timing.points) {
      if (tp.time < from || tp.time > to) continue;
      final x = xOf(tp.time, now, zoom, w);
      final c = tp.uninherited ? const Color(0xFFFF3B3B) : const Color(0xFF3BD16F);
      canvas.drawLine(Offset(x, 0), Offset(x, h), Paint()..color = c.withValues(alpha: 0.5));
      canvas.drawRect(Rect.fromLTWH(x - 2, 0, 4, markerH), Paint()..color = c);
    }

    if (editable) _drawBreakButtons(canvas, from, to, now, zoom, w, h);

    if (!objectsInBackground) _drawObjects(canvas, from, to, now, zoom, w, objY, objR);

    // Draggable end handle of the selected spinner / slider.
    final draggable = objectsInBackground ? null : controller.endDraggable;
    if (draggable != null) {
      final x = xOf(controller.endTimeOf(draggable), now, zoom, w);
      if (x >= 0 && x <= w) {
        final handle = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(x, objY), width: 8, height: math.min(h, objR * 2 + 10)),

          const Radius.circular(3),
        );
        canvas.drawRRect(handle, Paint()..color = _selection);
        canvas.drawRRect(
          handle,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = const Color(0xFF000000),
        );
      }
    }

    // Time range being box-selected (long-press drag).
    final box = controller.timelineBox;
    if (box != null) {
      final rect = Rect.fromLTRB(xOf(box.$1, now, zoom, w), 1, xOf(box.$2, now, zoom, w), h - 1);
      canvas.drawRect(rect, Paint()..color = _selection.withValues(alpha: 0.15));
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = _selection,
      );
    }

    // Shade time outside the song (before 0, after the end).
    final shade = Paint()..color = const Color(0x99000000);
    final xZero = xOf(0, now, zoom, w);
    if (xZero > 0) canvas.drawRect(Rect.fromLTRB(0, 0, xZero, h), shade);
    final end = controller.maxTime;
    if (end.isFinite) {
      final xEnd = xOf(end, now, zoom, w);
      if (xEnd < w) canvas.drawRect(Rect.fromLTRB(xEnd, 0, w, h), shade);
    }

    if (!objectsInBackground) _drawOverlapWarnings(canvas, from, to, now, zoom, w, h);

    // The circle being placed (finger down with the Circle tool): where in
    // time it lands, ringed when it replaces an object starting there.
    final ghost = objectsInBackground ? null : controller.placementGhost;
    final ghostCombo = ghost == null ? null : controller.placementGhostCombo;
    if (ghost != null && ghostCombo != null) {
      final x = xOf(ghost.time, now, zoom, w);
      // As on the playfield: the circle at 60 %.
      PlayfieldPainter.paintCircle(canvas, controller.skin, Offset(x, objY), objR,
          controller.comboColourAt(ghostCombo.colourIndex), 0.6, ghostCombo.number);
      if (controller.placementCollides) {
        canvas.drawCircle(
          Offset(x, objY),
          objR + 4,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = PlayfieldPainter.replaceColour,
        );
      }
    }

    // Playhead.
    canvas.drawLine(
      Offset(w / 2, 0),
      Offset(w / 2, h),
      Paint()
        ..color = const Color(0xFFFFE066)
        ..strokeWidth = 2,
    );
  }

  /// Hit objects on the middle line (reverse so earlier ones end up on
  /// top), drawn like the playfield's ([PlayfieldPainter.paintCircle] etc.,
  /// the skin's textures included): slider / spinner bodies as a straight
  /// slider track from head to tail, `sliderendcircle`s at the tail and
  /// the repeats (with the repeat arrow, pointing back). With [alpha] < 1
  /// (context in the other modes) they go opaque into one translucent
  /// layer, so overlapping ones don't show through each other; the
  /// selection and combo numbers are left out.
  void _drawObjects(
    Canvas canvas,
    double from,
    double to,
    double now,
    double zoom,
    double w,
    double objY,
    double objR, {
    double alpha = 1,
  }) {
    final faded = alpha < 1;
    if (faded) canvas.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, alpha));
    final skin = controller.skin;
    final objs = controller.objectsInRange(from, to).toList();
    for (var i = objs.length - 1; i >= 0; i--) {
      final o = objs[i];
      if (!faded && controller.isBeingReplaced(o)) continue; // the ghost takes its place
      final colour = controller.shownComboColourOf(o);
      final selected = !faded && controller.selection.contains(o);
      final x0 = xOf(o.time, now, zoom, w);
      final end = controller.endTimeOf(o);
      if (end > o.time) {
        final x1 = xOf(end, now, zoom, w);
        if (selected) {
          canvas.drawRRect(
              RRect.fromLTRBR(x0, objY - objR, x1, objY + objR, Radius.circular(objR)).inflate(3),
              Paint()..color = _selection);
        }
        // Clipped to a little past the screen.
        final b0 = math.max(x0, -objR * 2), b1 = math.min(x1, w + objR * 2);
        if (b1 > b0) {
          PlayfieldPainter.paintStraightBody(canvas, b0, b1, objY, objR,
              o is SliderObject ? controller.sliderTrackColour ?? colour : colour, controller.sliderBorderColour);
        }
        // The tail, then the repeats (earlier ones on top), tappable to pick
        // their hitsounds like stable.
        final endElement = o is SliderObject ? 'sliderendcircle' : 'hitcircle';
        PlayfieldPainter.paintCircle(canvas, skin, Offset(x1, objY), objR, colour, 1, null, element: endElement);
        if (o is SliderObject && o.slides > 1) {
          final span = (end - o.time) / o.slides;
          for (var k = o.slides - 1; k >= 1; k--) {
            final xr = xOf(o.time + span * k, now, zoom, w);
            if (xr < -objR || xr > w + objR) continue;
            PlayfieldPainter.paintCircle(canvas, skin, Offset(xr, objY), objR, colour, 1, null, element: endElement);
            PlayfieldPainter.paintRepeatArrow(canvas, skin, Vec2(xr, objY), Vec2(xr - objR, objY), objR, colour, 1);
          }
        }
      }
      if (selected) canvas.drawCircle(Offset(x0, objY), objR + 3, Paint()..color = _selection);
      PlayfieldPainter.paintCircle(canvas, skin, Offset(x0, objY), objR, colour, 1,
          faded || o is Spinner ? null : controller.shownComboOf(o).number,
          element: o is SliderObject ? 'sliderstartcircle' : 'hitcircle');
    }
    if (faded) canvas.restore();

    // The slider edge picked for hitsound editing.
    final edited = faded ? null : controller.editedSlider;
    final edge = edited == null ? null : controller.selectedEdge;
    if (edited != null && edge != null) {
      final x = xOf(controller.edgeTimes(edited)[edge], now, zoom, w);
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = edgeColour;
      canvas.drawCircle(Offset(x, objY), objR + 4, ring);
    }
  }

  /// The colour marking the picked slider edge (also on the playfield).
  static const edgeColour = Color(0xFF40C4FF);

  // ---------------------------------------------------------------------------
  // Breaks: a shaded span with draggable edges, a "Break ×" pill inside
  // (deletes it) and a "+ Break" pill in every gap long enough for one.

  static const _breakFill = Color(0x4D8FA3B8);
  static const _breakInvalidFill = Color(0x40FF3030);
  static const _breakEdge = Color(0xCCB8C7D9);
  static const _breakPill = Color(0xFF3A4350);
  static const _breakInvalidPill = Color(0xFF7A2A2A);
  static const _breakInvalidBorder = Color(0xFFFF6B6B);
  static const _breakText =Color(0xFFE3E9F0);
  static const _breakPreviewFill = Color(0x128FA3B8);
  static const _breakPreviewEdge = Color(0x66B8C7D9);

  /// Margin kept between a pill and its span's edges, in logical pixels.
  static const _pillMargin = 10.0;

  static TextPainter? _breakLabel;
  static double _breakLabelSize = -1;

  static double _pillHeight(double h) => math.min(22.0, h * 0.5);

  static TextPainter _label(double h) {
    final size = _pillHeight(h) * 0.55;
    if (_breakLabelSize != size) {
      _breakLabel?.dispose();
      _breakLabelSize = size;
      _breakLabel = TextPainter(
        text: TextSpan(
          text: 'Break',
          style: TextStyle(color: _breakText, fontSize: size, fontFamily: kUiFont, fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
    }
    return _breakLabel!;
  }

  /// Width of a pill: the label plus room for the × / + glyph.
  static double _pillWidth(double h) => _label(h).width + _pillHeight(h) * 1.6;

  /// Where the pill for the span [t0]..[t1] is drawn: centred on the span
  /// but kept inside its visible part, so it stays reachable while a long
  /// break scrolls by. Null when the visible part is too narrow.
  static Rect? breakPillRect(double t0, double t1, double now, double zoom, double w, double h) {
    final x0 = math.max(0.0, xOf(t0, now, zoom, w)), x1 = math.min(w, xOf(t1, now, zoom, w));
    final pw = _pillWidth(h), ph = _pillHeight(h);
    if (x1 - x0 < pw + 2 * _pillMargin) return null;
    final cx = xOf((t0 + t1) / 2, now, zoom, w).clamp(x0 + _pillMargin + pw / 2, x1 - _pillMargin - pw / 2);
    return Rect.fromCenter(center: Offset(cx, h / 2), width: pw, height: ph);
  }

  void _drawBreaks(Canvas canvas, double from, double to, double now, double zoom, double w, double h,
      {required bool editable}) {
    final drag = controller.breakDrag;
    final edge = Paint()..strokeWidth = 2;
    for (final b in controller.breaks) {
      if (b.end < from || b.start > to) continue;
      final invalid = controller.isBreakInvalid(b);
      final x0 = xOf(b.start, now, zoom, w), x1 = xOf(b.end, now, zoom, w);
      canvas.drawRect(Rect.fromLTRB(x0, 0, x1, h), Paint()..color = invalid ? _breakInvalidFill : _breakFill);
      for (final (x, isEnd) in [(x0, false), (x1, true)]) {
        final dragged = drag != null && drag.$1.lineIndex == b.lineIndex && drag.$2 == isEnd;
        edge.color = dragged ? _selection : _breakEdge;
        canvas.drawLine(Offset(x, 0), Offset(x, h), edge);
        if (!editable) continue;
        // Grip: a small handle just inside the span.
        final gx = isEnd ? x - 4 : x + 4;
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(gx, h / 2), width: 6, height: h * 0.42),
              const Radius.circular(3)),
          Paint()..color = dragged ? _selection : _breakEdge,
        );
      }
    }
  }

  void _drawBreakButtons(Canvas canvas, double from, double to, double now, double zoom, double w, double h) {
    final label = _label(h);
    final glyph = Paint()
      ..color = _breakText
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    void pill(Rect r, Color fill, {required bool add, bool outline = false}) {
      final rr = RRect.fromRectAndRadius(r, Radius.circular(r.height / 2));
      if (outline) {
        canvas.drawRRect(
          rr,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = _breakEdge,
        );
      } else {
        canvas.drawRRect(rr, Paint()..color = fill);
        canvas.drawRRect(
          rr.deflate(0.6),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = fill == _breakInvalidPill ? _breakInvalidBorder : _breakEdge,
        );
      }
      final g = r.height * 0.22;
      // + before the label, × after it.
      final gc = add ? Offset(r.left + r.height * 0.6, r.center.dy) : Offset(r.right - r.height * 0.6, r.center.dy);
      final tx = add ? r.left + r.height * 1.1 : r.left + r.height * 0.5;
      label.paint(canvas, Offset(tx, r.center.dy - label.height / 2));
      if (add) {
        canvas.drawLine(gc - Offset(g, 0), gc + Offset(g, 0), glyph);
        canvas.drawLine(gc - Offset(0, g), gc + Offset(0, g), glyph);
      } else {
        canvas.drawLine(gc - Offset(g, g), gc + Offset(g, g), glyph);
        canvas.drawLine(gc - Offset(g, -g), gc + Offset(g, -g), glyph);
      }
    }

    final dragging = controller.breakDrag != null;
    for (final b in controller.breaks) {
      if (b.end < from || b.start > to) continue;
      final r = breakPillRect(b.start, b.end, now, zoom, w, h);
      if (r != null && controller.canRemoveBreak(b)) pill(r, controller.isBreakInvalid(b) ? _breakInvalidPill : _breakPill, add: false);
    }
    if (dragging) return;
    for (final (s, e) in controller.insertableBreaks) {
      if (e < from || s > to) continue;
      final r = breakPillRect(s, e, now, zoom, w, h);
      if (r == null) continue;
      // Faint preview of the range the pill adds (it is not centred between
      // the objects: 200 ms after the previous one, the next one's approach
      // before it), so the pill reads as centred on it.
      final x0 = xOf(s, now, zoom, w), x1 = xOf(e, now, zoom, w);
      canvas.drawRect(Rect.fromLTRB(x0, 0, x1, h), Paint()..color = _breakPreviewFill);
      for (final x in [x0, x1]) {
        canvas.drawLine(Offset(x, h * 0.2), Offset(x, h * 0.8), Paint()..color = _breakPreviewEdge);
      }
      pill(r, _bg, add: true, outline: true);
    }
  }

  static const _warning = Color(0xFFFF3030);

  /// A red "!" badge at the top of every spot where objects overlap in time.
  void _drawOverlapWarnings(Canvas canvas, double from, double to, double now, double zoom, double w, double h) {
    final issues = controller.overlapIssues;
    if (issues.isEmpty) return;
    final r = math.min(9.0, h * 0.2);
    final margin = r / zoom + 1;
    final fill = Paint()..color = _warning;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0xFFFFFFFF);
    final mark = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = r * 0.24
      ..strokeCap = StrokeCap.round;
    var lastX = double.negativeInfinity;
    for (var i = Beatmap.lowerBound(issues, from - margin, (o) => o.time);
        i < issues.length && issues[i].time <= to + margin;
        i++) {
      final x = xOf(issues[i].time, now, zoom, w);
      if (x - lastX < 1) continue; // one badge per spot
      lastX = x;
      final c = Offset(x, r + 1);
      canvas.drawCircle(c, r, fill);
      canvas.drawCircle(c, r, ring);
      canvas.drawLine(Offset(x, c.dy - r * 0.55), Offset(x, c.dy + r * 0.12), mark);
      canvas.drawCircle(Offset(x, c.dy + r * 0.52), r * 0.16, mark);
    }
  }

  @override
  bool shouldRepaint(covariant TimelinePainter old) =>
      old.controller != controller || old.objectsInBackground != objectsInBackground;
}
