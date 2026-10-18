import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../../app_fonts.dart';
import '../../core/core.dart';
import '../editor_controller.dart';
import 'timeline_painter.dart';

/// Waveform drawing shared by the Timing mode's BPM strip and beat rows,
/// one column per physical pixel, each layer in one `drawVertices`:
/// * behind: the low band's envelope (its peak over ~[envelopeMs] around
///   the column, mirrored, translucent blue), so kicks stand out even where
///   the samples themselves look like noise;
/// * in front: min..max of the samples under the column (the actual wave).
/// Both are coloured by frequency band (low = blue, mid = amber, high =
/// white). Until the detailed waveform is decoded the timeline's 5 ms
/// envelope (grey, mirrored) stands in.
class BpmWave {
  BpmWave._();

  static const lowColour = Color(0xFF3D7DFF);
  static const midColour = Color(0xFFFFA63D);
  static const highColour = Color(0xFFF2F4FF);
  static const _coarseColour = Color(0xFF6E7A8C);

  /// Width of the envelope's window, in ms.
  static const envelopeMs = 6.0;
  static const _envelopeColour = Color(0x803D7DFF);

  static final WaveColumn _col = WaveColumn();
  static Float32List _pos = Float32List(0);
  static Int32List _colours = Int32List(0);
  static int _n = 0;

  /// Draws audio time [audioFrom] at x = [left] onwards ([msPerPx]) up to
  /// x = [right], centred on [midY] with amplitude 1 = [half] px. [step] is
  /// the column width (one physical pixel).
  static void draw(Canvas canvas, EditorController c,
      {required double audioFrom,
      required double msPerPx,
      required double left,
      required double right,
      required double midY,
      required double half,
      required double step}) {
    final detail = c.detailedWaveform;
    final coarse = c.waveform;
    if (detail == null && coarse == null) return;
    final columns = ((right - left) / step).ceil();
    if (columns <= 0) return;
    if (_pos.length < columns * 12) {
      _pos = Float32List(columns * 12);
      _colours = Int32List(columns * 6);
    }
    final col = _col;

    if (detail == null) {
      _n = 0;
      final argb = _argb(_coarseColour, 1);
      for (var i = 0; i < columns; i++) {
        final x0 = left + i * step;
        final t0 = audioFrom + (x0 - left) * msPerPx;
        final v = coarse!.peak(t0, t0 + step * msPerPx);
        if (v <= 0.01) continue;
        _quad(x0, math.min(right, x0 + step), midY - v * half, midY + v * half, step, argb);
      }
      _flush(canvas);
      return;
    }

    // Envelope: only worth it when a column is narrower than its window.
    final colMs = step * msPerPx;
    if (colMs < envelopeMs) {
      _n = 0;
      final pad = (envelopeMs - colMs) / 2;
      final envelope = _argb(_envelopeColour, _envelopeColour.a);
      for (var i = 0; i < columns; i++) {
        final x0 = left + i * step;
        final t0 = audioFrom + (x0 - left) * msPerPx;
        if (!detail.column(t0 - pad, t0 + colMs + pad, col) || col.isSilent) continue;
        final v = col.low;
        if (v < 0.02) continue;
        _quad(x0, math.min(right, x0 + step), midY - v * half, midY + v * half, step, envelope);
      }
      _flush(canvas);
    }

    _n = 0;
    for (var i = 0; i < columns; i++) {
      final x0 = left + i * step;
      final t0 = audioFrom + (x0 - left) * msPerPx;
      if (!detail.column(t0, t0 + colMs, col) || col.isSilent) continue;
      _quad(x0, math.min(right, x0 + step), midY - col.max * half, midY - col.min * half, step,
          _mix(col.low, col.mid, col.high, 1));
    }
    _flush(canvas);
  }

  /// Adds a column rectangle (at least [minH] tall, so quiet columns stay
  /// visible as a hairline).
  static void _quad(double x0, double x1, double top, double bottom, double minH, int argb) {
    if (bottom - top < minH) {
      final m = (top + bottom) / 2;
      top = m - minH / 2;
      bottom = m + minH / 2;
    }
    final pos = _pos;
    final p = _n * 12;
    pos[p] = x0;
    pos[p + 1] = top;
    pos[p + 2] = x1;
    pos[p + 3] = top;
    pos[p + 4] = x1;
    pos[p + 5] = bottom;
    pos[p + 6] = x0;
    pos[p + 7] = top;
    pos[p + 8] = x1;
    pos[p + 9] = bottom;
    pos[p + 10] = x0;
    pos[p + 11] = bottom;
    final q = _n * 6;
    for (var k = 0; k < 6; k++) {
      _colours[q + k] = argb;
    }
    _n++;
  }

  static void _flush(Canvas canvas) {
    if (_n == 0) return;
    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      Float32List.sublistView(_pos, 0, _n * 12),
      colors: Int32List.sublistView(_colours, 0, _n * 6),
    );
    canvas.drawVertices(vertices, BlendMode.dst, Paint());
    vertices.dispose();
    _n = 0;
  }

  static int _argb(Color c, double alpha) =>
      ((alpha * 255).round() << 24 | (c.r * 255).round() << 16 | (c.g * 255).round() << 8 | (c.b * 255).round())
          .toSigned(32);

  /// Band-weighted colour; louder columns are brighter.
  static int _mix(double low, double mid, double high, double alpha) {
    final sum = low + mid + high;
    if (sum < 1e-3) return _argb(_coarseColour, alpha);
    final r = (lowColour.r * low + midColour.r * mid + highColour.r * high) / sum;
    final g = (lowColour.g * low + midColour.g * mid + highColour.g * high) / sum;
    final b = (lowColour.b * low + midColour.b * mid + highColour.b * high) / sum;
    final bright = 0.55 + 0.45 * math.min(1.0, math.max(low, math.max(mid, high)));
    return ((alpha * 255).round() << 24 |
            (r * bright * 255).round().clamp(0, 255) << 16 |
            (g * bright * 255).round().clamp(0, 255) << 8 |
            (b * bright * 255).round().clamp(0, 255))
        .toSigned(32);
  }
}

const _background = Color(0xFF101216);
const _timingRed = Color(0xFFE53935);
const _playhead = Color(0xFFFFE066);

/// The BPM strip: a zoomable stretch of the song centred on the playhead
/// with the detailed waveform, the metronome ticks of the beat divisor and
/// the red (timing) points. No objects. Repaints from `controller.time`.
class BpmStripPainter extends CustomPainter {
  final EditorController c;

  /// Pixels per ms.
  final double zoom;

  /// Device pixel ratio (waveform columns are one physical pixel wide).
  final double dpr;

  BpmStripPainter(this.c, {required this.zoom, required this.dpr}) : super(repaint: c.time);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = _background);
    final now = c.time.value;
    final from = TimelinePainter.timeAt(0, now, zoom, w), to = TimelinePainter.timeAt(w, now, zoom, w);

    // Before 0 / after the end of the song: darker.
    final shade = Paint()..color = const Color(0x66000000);
    final x0 = TimelinePainter.xOf(0, now, zoom, w);
    if (x0 > 0) canvas.drawRect(Rect.fromLTRB(0, 0, math.min(w, x0), h), shade);

    // Metronome ticks behind the waveform.
    final tick = Paint();
    for (final t in c.timing.ticks(from, to, c.divisor)) {
      final x = TimelinePainter.xOf(t.time, now, zoom, w);
      final len = t.isMeasureStart ? 1.0 : (t.denominator == 1 ? 0.8 : (t.denominator <= 2 ? 0.55 : 0.35));
      tick
        ..color = TimelinePainter.tickColour(t.denominator).withValues(alpha: t.isMeasureStart ? 0.75 : 0.45)
        ..strokeWidth = t.isMeasureStart ? 2 : 1;
      final half = h * len / 2;
      canvas.drawLine(Offset(x, h / 2 - half), Offset(x, h / 2 + half), tick);
    }

    final offset = c.waveformOffsetMs;
    BpmWave.draw(canvas, c,
        audioFrom: from + offset,
        msPerPx: 1 / zoom,
        left: 0,
        right: w,
        midY: h / 2,
        half: h * 0.46,
        step: 1 / dpr);

    // Red points on top.
    final red = Paint()
      ..color = _timingRed
      ..strokeWidth = 2;
    for (final p in c.timing.redPoints) {
      if (p.time < from - 2 / zoom || p.time > to + 2 / zoom) continue;
      final x = TimelinePainter.xOf(p.time, now, zoom, w);
      canvas.drawLine(Offset(x, 0), Offset(x, h), red);
      canvas.drawPath(
          Path()
            ..moveTo(x - 5, 0)
            ..lineTo(x + 5, 0)
            ..lineTo(x, 7)
            ..close(),
          red);
    }

    canvas.drawLine(Offset(w / 2, 0), Offset(w / 2, h), Paint()
      ..color = _playhead
      ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(BpmStripPainter old) => true; // rebuilds are rare (edits, zoom)
}

/// The rows a [BpmRowsPainter] shows: row i is centred on red point time
/// + (first + i) × [length] (a beat or a bar of the red point at the
/// playhead), half a [length] either side.
class BpmRows {
  final TimingPoint red;

  /// ms per row (a beat or a bar).
  final double length;

  /// Index (beats or bars from [red]) of the first row.
  final int first;
  final int count;

  /// Row that holds the playhead.
  final int current;

  const BpmRows(this.red, this.length, this.first, this.count, this.current);

  /// Rows for the playhead at [time]; null without a red point there.
  static BpmRows? at(TimingInfo timing, double time, {required bool bars, required int count}) {
    final red = timing.redPointAt(time) ?? (timing.redPoints.isEmpty ? null : timing.redPoints.first);
    if (red == null || !(red.beatLength > 0) || count < 1) return null;
    final meter = red.meter < 1 ? 4 : red.meter;
    final length = bars ? red.beatLength * meter : red.beatLength;
    final n = ((time - red.time) / length).round();
    final before = math.min(2, (count - 1) ~/ 3);
    return BpmRows(red, length, n - before, count, before);
  }

  /// Centre (the beat / bar) of row [i].
  double centreOf(int i) => red.time + (first + i) * length;

  /// Time at fraction [f] (0..1) across row [i].
  double timeAt(int i, double f) => centreOf(i) + (f - 0.5) * length;
}

/// The beat rows under the BPM strip (lazer's waveform comparison): the
/// song cut into one row per beat (or bar) of the red point at the
/// playhead, stacked, each centred on its beat. With the right BPM and
/// offset the beats' attacks line up on the centre line in every row; a
/// wrong BPM shows as attacks drifting across the rows, a wrong offset as
/// them all sitting off the line. Repaints from `controller.time`.
class BpmRowsPainter extends CustomPainter {
  final EditorController c;
  final bool bars;
  final int count;
  final double dpr;

  /// Width of the row labels on the left.
  static const gutter = 40.0;

  BpmRowsPainter(this.c, {required this.bars, required this.count, required this.dpr}) : super(repaint: c.time);

  static final Map<String, TextPainter> _labels = {};

  static TextPainter _label(String s, Color colour) {
    final key = '$s|${colour.toARGB32()}';
    var tp = _labels[key];
    if (tp == null) {
      if (_labels.length > 400) {
        for (final p in _labels.values) {
          p.dispose();
        }
        _labels.clear();
      }
      tp = _labels[key] = TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(color: colour, fontSize: 11, fontFamily: kMonoFont),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
    }
    return tp;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = _background);
    final now = c.time.value;
    final rows = BpmRows.at(c.timing, now, bars: bars, count: count);
    if (rows == null) return;
    final red = rows.red;
    final meter = red.meter < 1 ? 4 : red.meter;
    final rowH = h / count;
    final left = gutter, right = w;
    final rowW = right - left;
    if (rowW <= 0) return;
    final msPerPx = rows.length / rowW;
    final offset = c.waveformOffsetMs;

    // The section ends at the next red point; rows past it are shaded.
    final reds = c.timing.redPoints;
    final ri = reds.indexWhere((p) => identical(p, red));
    final nextRed = ri >= 0 && ri + 1 < reds.length ? reds[ri + 1].time : double.infinity;

    final line = Paint();
    final divisor = c.divisor;
    final subdivisions = bars ? divisor * meter : divisor;
    for (var i = 0; i < count; i++) {
      final top = i * rowH, mid = top + rowH / 2;
      final start = rows.timeAt(i, 0);
      if (i == rows.current) {
        canvas.drawRect(Rect.fromLTRB(0, top, w, top + rowH), Paint()..color = const Color(0xFF1C2028));
      }
      // Grid of the beat divisor across the row.
      for (var j = -subdivisions ~/ 2; j <= subdivisions - subdivisions ~/ 2; j++) {
        final t = rows.centreOf(i) + j * rows.length / subdivisions;
        final x = left + (t - start) / msPerPx;
        if (x < left - 0.5 || x > right + 0.5) continue;
        final k = j % divisor; // position in the beat
        final g = _gcd(k, divisor);
        final denominator = divisor ~/ g;
        final barLine = k == 0 && ((rows.first + i) * (bars ? meter : 1) + (j - k) ~/ divisor) % meter == 0;
        line
          ..color = TimelinePainter.tickColour(k == 0 ? 1 : denominator).withValues(alpha: k == 0 ? 0.4 : 0.22)
          ..strokeWidth = barLine ? 2 : 1;
        canvas.drawLine(Offset(x, top + 1), Offset(x, top + rowH - 1), line);
      }

      BpmWave.draw(canvas, c,
          audioFrom: start + offset,
          msPerPx: msPerPx,
          left: left,
          right: right,
          midY: mid,
          half: rowH * 0.46,
          step: 1 / dpr);

      // Past the section's end: another BPM rules there.
      final endX = left + (nextRed - start) / msPerPx;
      if (endX < right) {
        final x = math.max(left, endX);
        canvas.drawRect(Rect.fromLTRB(x, top, right, top + rowH), Paint()..color = const Color(0xB0101216));
        if (endX >= left) {
          canvas.drawLine(Offset(x, top), Offset(x, top + rowH), Paint()
            ..color = _timingRed.withValues(alpha: 0.6)
            ..strokeWidth = 1);
        }
      }

      // The beat itself: the line attacks should sit on.
      final cx = left + rowW / 2;
      canvas.drawLine(Offset(cx, top), Offset(cx, top + rowH), Paint()
        ..color = _timingRed.withValues(alpha: 0.9)
        ..strokeWidth = 1.5);

      // Row separator and label (bar:beat, 1-based, from the red point).
      canvas.drawLine(Offset(0, top + rowH), Offset(w, top + rowH), Paint()
        ..color = const Color(0xFF2A2F38)
        ..strokeWidth = 1);
      final index = rows.first + i;
      final beat = bars ? index * meter : index;
      final bar = (beat / meter).floor() + 1;
      final inBar = beat - (bar - 1) * meter + 1;
      final tp = _label(
          bars ? '$bar' : '$bar:$inBar', i == rows.current ? const Color(0xFFFFFFFF) : const Color(0xFF8A93A3));
      tp.paint(canvas, Offset(6, mid - tp.height / 2));
    }
    canvas.drawLine(Offset(left, 0), Offset(left, h), Paint()..color = const Color(0xFF2A2F38));

    // Playhead in its row.
    final f = (now - rows.timeAt(rows.current, 0)) / rows.length;
    if (f >= 0 && f <= 1) {
      final x = left + f * rowW, top = rows.current * rowH;
      canvas.drawLine(Offset(x, top), Offset(x, top + rowH), Paint()
        ..color = _playhead
        ..strokeWidth = 1.5);
    }
  }

  static int _gcd(int a, int b) {
    a = a.abs();
    while (b != 0) {
      final t = a % b;
      a = b;
      b = t;
    }
    return a == 0 ? 1 : a;
  }

  @override
  bool shouldRepaint(BpmRowsPainter old) => true; // rebuilds are rare (edits, row settings)
}
