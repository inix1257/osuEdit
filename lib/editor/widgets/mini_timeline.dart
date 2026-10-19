import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/core.dart';
import '../editor_controller.dart';
import '../render/difficulty_graph.dart';

/// Whole-map overview bar (osu!stable's bottom timeline): bookmarks, timing
/// points, kiai and breaks — no objects; in Compose also the difficulty
/// graph. Tap or drag to seek; the beat snap
/// applies on release, like the main timeline.
///
/// Long-press enters fine adjustment: the playhead jumps to the pressed
/// spot; holding the finger to one side of the playhead moves it that way,
/// slowly when the finger is near it and faster the farther away (it
/// glides after the finger, easing in). Release snaps to the beat. While
/// it lasts, a magnifier above the playhead shows the bar around it
/// stretched [MiniTimelineLoupePainter.magnification] times.
class MiniTimeline extends StatefulWidget {
  final EditorController controller;

  /// Draw the difficulty graph (Compose) behind the markers.
  final bool difficultyGraph;
  const MiniTimeline({super.key, required this.controller, this.difficultyGraph = false});

  @override
  State<MiniTimeline> createState() => _MiniTimelineState();
}

class _MiniTimelineState extends State<MiniTimeline> with SingleTickerProviderStateMixin {
  EditorController get c => widget.controller;

  // Fine adjustment (long-press).

  /// The finger x while fine-adjusting, for the painter; null otherwise.
  final _fine = ValueNotifier<double?>(null);
  final _loupe = OverlayPortalController();
  final _barLink = LayerLink();
  double _height = 0;
  late final Ticker _fineTicker = createTicker(_onFineTick);
  Duration _fineLast = Duration.zero;
  double _width = 0;

  /// The unsnapped playhead time the fine adjustment moves.
  double _fineTime = 0;

  /// Finger offset from the playhead that still holds it still (touch
  /// jitter), in logical pixels.
  static const fineDeadZone = 6.0;

  /// Speed with the finger one bar width from the playhead, in ms per
  /// second; it grows with the square of the distance, so a few pixels
  /// creep by tens of ms per second and the far end crosses a song in
  /// seconds.
  static const fineMaxSpeed = 60000.0;

  /// The playhead speed (ms per second, negative = earlier) for a finger
  /// [dx] pixels from the playhead on a bar [width] wide.
  static double fineSpeed(double dx, double width) {
    final d = dx.abs() - fineDeadZone;
    if (d <= 0 || width <= 0) return 0;
    final f = d / width;
    return dx.sign * fineMaxSpeed * f * f;
  }

  void _onFineStart(LongPressStartDetails d) {
    c.pause();
    c.seek(_timeAt(d.localPosition.dx, _width));
    _fineTime = c.time.value;
    _fine.value = d.localPosition.dx;
    HapticFeedback.selectionClick();
    _loupe.show();
    _fineLast = Duration.zero;
    _fineTicker.start();
  }

  void _onFineMove(LongPressMoveUpdateDetails d) {
    if (_fine.value != null) _fine.value = d.localPosition.dx;
  }

  void _onFineTick(Duration elapsed) {
    final finger = _fine.value;
    if (finger == null || !mounted || c.isPlaying) return _endFine(snap: false);
    final dt = (elapsed - _fineLast).inMicroseconds / 1e6;
    _fineLast = elapsed;
    if (dt <= 0 || dt > 0.1) return; // first tick / a hitch: no jump
    // Measured from where the playhead is now, not where it started.
    final v = fineSpeed(finger - _xAt(_fineTime, _width), _width);
    if (v == 0) return;
    c.seek(_fineTime + v * dt);
    // Kept unclamped between ticks for sub-ms steps, but not past the
    // start / end of the song.
    _fineTime = (_fineTime + v * dt).clamp(c.time.value - 1, c.time.value + 1);
  }

  void _endFine({bool snap = true}) {
    if (_fineTicker.isActive) _fineTicker.stop();
    if (_fine.value == null) return;
    _fine.value = null;
    _loupe.hide();
    if (snap && !c.isPlaying) c.seekSnapped(_fineTime);
  }

  @override
  void dispose() {
    _fineTicker.dispose();
    _fine.dispose();
    super.dispose();
  }

  /// Rebuilt with the widget (the editor screen rebuilds on every edit),
  /// so painting during playback never re-scans the map.
  late MiniTimelineData _data;

  double _timeAt(double x, double width) {
    final d = _data;
    return d.start + (x / width).clamp(0.0, 1.0) * (d.end - d.start);
  }

  double _xAt(double t, double width) {
    final d = _data;
    return (t - d.start) / (d.end - d.start) * width;
  }

  void _seek(double x, double width) {
    c.pause();
    c.seek(_timeAt(x, width));
  }

  @override
  Widget build(BuildContext context) {
    _data = MiniTimelineData.of(c);
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      _width = width;
      _height = constraints.maxHeight;
      final bar = MiniTimelinePainter(_data, c.time,
          difficulty: widget.difficultyGraph ? c.difficulty : null, fine: _fine);
      return CompositedTransformTarget(
        link: _barLink,
        child: OverlayPortal(
          controller: _loupe,
          overlayChildBuilder: (_) => _buildLoupe(bar),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => c.seekSnapped(_timeAt(d.localPosition.dx, width)),
            onHorizontalDragStart: (d) => _seek(d.localPosition.dx, width),
            onHorizontalDragUpdate: (d) => _seek(d.localPosition.dx, width),
            onLongPressStart: _onFineStart,
            onLongPressMoveUpdate: _onFineMove,
            onLongPressEnd: (_) => _endFine(),
            onLongPressCancel: _endFine,
            child: RepaintBoundary(
              child: CustomPaint(painter: bar, size: Size(width, constraints.maxHeight)),
            ),
          ),
        ),
      );
    });
  }

  /// The magnifier: a strip as wide as the bar sitting on top of it (in
  /// the overlay, over the playfield); its painter follows the playhead,
  /// so nothing rebuilds per frame.
  Widget _buildLoupe(MiniTimelinePainter bar) {
    final painter = MiniTimelineLoupePainter(bar, _height);
    return Align(
      alignment: Alignment.topLeft,
      child: IgnorePointer(
        child: CompositedTransformFollower(
          link: _barLink,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topLeft,
          followerAnchor: Alignment.bottomLeft,
          child: RepaintBoundary(
            child: CustomPaint(painter: painter, size: Size(_width, painter.stripHeight)),
          ),
        ),
      ),
    );
  }
}

/// What the overview shows, extracted from the map once per rebuild.
class MiniTimelineData {
  final double start;
  final double end;
  final List<TimingPoint> timingPoints;
  final List<int> bookmarks;
  final List<(double, double)> breaks;
  final List<(double, double)> kiai;

  const MiniTimelineData({
    required this.start,
    required this.end,
    required this.timingPoints,
    required this.bookmarks,
    required this.breaks,
    required this.kiai,
  });

  factory MiniTimelineData.of(EditorController c) {
    final b = c.beatmap;
    final points = b.timingPoints;
    final bookmarks = b.bookmarks;
    final breaks = b.breaks;

    // Song length when audio is loaded; otherwise whatever the map reaches.
    var end = c.maxTime;
    if (!end.isFinite) {
      end = c.time.value;
      if (b.hitObjects.isNotEmpty) end = math.max(end, c.endTimeOf(b.hitObjects.last));
      if (points.isNotEmpty) end = math.max(end, points.last.time);
      for (final m in bookmarks) {
        end = math.max(end, m.toDouble());
      }
      for (final (_, e) in breaks) {
        end = math.max(end, e);
      }
      end += 2000;
    }
    const start = 0.0;
    if (end <= start + 1) end = start + 1;

    final kiai = <(double, double)>[];
    double? kiaiFrom;
    for (final p in points) {
      if (p.kiai && kiaiFrom == null) kiaiFrom = p.time;
      if (!p.kiai && kiaiFrom != null) {
        kiai.add((kiaiFrom, p.time));
        kiaiFrom = null;
      }
    }
    if (kiaiFrom != null) kiai.add((kiaiFrom, end));

    return MiniTimelineData(
      start: start,
      end: end,
      timingPoints: points,
      bookmarks: bookmarks,
      breaks: breaks,
      kiai: kiai,
    );
  }
}

class MiniTimelinePainter extends CustomPainter {
  final MiniTimelineData data;
  final ValueNotifier<double> time;

  /// The difficulty graph to draw behind the markers, if any.
  final ValueListenable<StarAnalysis?>? difficulty;

  /// Fine adjustment's finger x, if under way.
  final ValueListenable<double?>? fine;

  MiniTimelinePainter(this.data, this.time, {this.difficulty, this.fine})
      : super(repaint: Listenable.merge([time, difficulty, fine]));

  static const _bg = Color(0xFF15171B);
  static const _track = Color(0xFF3A3D45);
  static const _break = Color(0x33FFFFFF);
  static const _kiai = Color(0x88FF9F1A);
  static const _red = Color(0xFFFF3B3B);
  static const _green = Color(0xFF3BD16F);
  static const _bookmark = Color(0x994D8DFF);
  static const _playhead = Color(0xFFFFE066);
  static const _fineBand = Color(0x40FFFFFF);
  static const _fineAnchor = Color(0xCCFFFFFF);

  /// The bar without its playhead, as last recorded, and what it was
  /// recorded for (map data, graph, size).
  static ui.Picture? _markers;
  static Object? _markersKey;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final span = data.end - data.start;
    double x(double t) => ((t - data.start) / span).clamp(0.0, 1.0) * w;

    canvas.clipRect(Offset.zero & size);
    // Everything but the playhead changes only with the map: recorded once
    // (thousands of marker lines re-recorded every frame of playback were
    // paint time and a display list for the GC to free each frame).
    final key = (data, difficulty?.value, w, h);
    var markers = _markers;
    if (markers == null || key != _markersKey) {
      markers?.dispose();
      final recorder = ui.PictureRecorder();
      final c = Canvas(recorder);
      c.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4)), Paint()..color = _bg);
      paintMarkers(c, h, x, barWidth: w);
      markers = _markers = recorder.endRecording();
      _markersKey = key;
    }
    canvas.drawPicture(markers);
    final px = x(time.value);
    final f = fine?.value;
    if (f != null) _paintFine(canvas, px, f, h);
    canvas.drawRect(Rect.fromLTWH(px - 1.5, 0, 3, h), Paint()..color = _playhead);
  }

  /// The graph, breaks, kiai, track, bookmarks and timing points, [h]
  /// tall, placed by [x] (time to local x). The graph is laid out on a bar
  /// [barWidth] wide, then stretched by [graphScale] and moved by
  /// [graphShift] (the magnifier).
  void paintMarkers(Canvas canvas, double h, double Function(double t) x,
      {required double barWidth, double graphScale = 1, double graphShift = 0}) {
    final mid = h / 2;
    final graph = difficulty?.value;
    if (graph != null) {
      DifficultyGraph.paintOverview(canvas, graph,
          start: data.start,
          end: data.end,
          width: barWidth,
          top: h * 0.08,
          bottom: h,
          scaleX: graphScale,
          shiftX: graphShift);
    }

    for (final (s, e) in data.breaks) {
      canvas.drawRect(Rect.fromLTRB(x(s), h * 0.2, math.max(x(e), x(s) + 1), h * 0.8), Paint()..color = _break);
    }
    for (final (s, e) in data.kiai) {
      canvas.drawRect(Rect.fromLTRB(x(s), h * 0.72, math.max(x(e), x(s) + 1), h * 0.86), Paint()..color = _kiai);
    }
    canvas.drawLine(Offset(x(data.start), mid), Offset(x(data.end), mid), Paint()
      ..color = _track
      ..strokeWidth = 2);

    // Bookmarks under the timing points so both stay visible; red points
    // on the upper half, green on the lower (stable's look).
    final line = Paint()..strokeWidth = 1.5;
    for (final m in data.bookmarks) {
      final px = x(m.toDouble());
      canvas.drawLine(Offset(px, h * 0.1), Offset(px, h * 0.9), line..color = _bookmark);
    }
    for (final p in data.timingPoints) {
      final px = x(p.time);
      if (p.uninherited) {
        canvas.drawLine(Offset(px, 0), Offset(px, mid), line..color = _red);
      } else {
        canvas.drawLine(Offset(px, mid), Offset(px, h), line..color = _green);
      }
    }
  }

  /// The fine adjustment's pull: a band from the playhead to the finger
  /// with an arrow the way the playhead goes.
  void _paintFine(Canvas canvas, double anchor, double finger, double h) {
    final dx = finger - anchor;
    if (dx.abs() > _MiniTimelineState.fineDeadZone) {
      canvas.drawRect(Rect.fromLTRB(math.min(anchor, finger), h * 0.3, math.max(anchor, finger), h * 0.7),
          Paint()..color = _fineBand);
      final s = dx.sign, ah = h * 0.3;
      canvas.drawPath(
          Path()
            ..moveTo(finger + s * ah * 0.8, h / 2)
            ..lineTo(finger, h / 2 - ah)
            ..lineTo(finger, h / 2 + ah)
            ..close(),
          Paint()..color = _fineAnchor);
    }
  }

  @override
  bool shouldRepaint(covariant MiniTimelinePainter old) =>
      old.data != data || old.time != time || old.difficulty != difficulty || old.fine != fine;
}

/// The fine adjustment's magnifier, painted on a strip as wide as the bar
/// right above it: a box over the playhead showing the bar around it
/// stretched [magnification] times (redrawn at that scale, so markers stay
/// sharp), with a notch pointing down at the playhead.
class MiniTimelineLoupePainter extends CustomPainter {
  final MiniTimelinePainter bar;

  /// The bar's height.
  final double barHeight;

  MiniTimelineLoupePainter(this.bar, this.barHeight) : super(repaint: bar.time);

  static const magnification = 8.0;
  static const boxWidth = 176.0;

  /// Space between the notch's tip and the bar.
  static const gap = 4.0;
  static const notch = 6.0;

  double get boxHeight => barHeight * 1.4;

  /// Height of the strip the box and notch are drawn on.
  double get stripHeight => boxHeight + notch + gap;

  static const _border = Color(0xCCFFFFFF);

  @override
  void paint(Canvas canvas, Size size) {
    final data = bar.data, w = size.width;
    if (w <= 0) return;
    final span = data.end - data.start;
    final now = bar.time.value;
    final px = ((now - data.start) / span).clamp(0.0, 1.0) * w; // playhead on the bar
    final bw = math.min(boxWidth, w), bh = boxHeight;
    final left = (px - bw / 2).clamp(0.0, w - bw);
    final rbox = RRect.fromRectAndRadius(Rect.fromLTWH(left, 0, bw, bh), const Radius.circular(6));

    canvas.drawShadow(Path()..addRRect(rbox), Colors.black, 4, false);
    canvas.save();
    canvas.clipRRect(rbox);
    canvas.translate(left, 0);
    canvas.drawRect(Rect.fromLTWH(0, 0, bw, bh), Paint()..color = MiniTimelinePainter._bg);
    // Time to x in the box, the playhead where it is above the bar.
    final k = w * magnification / span, at = px - left;
    double x(double t) => (t - now) * k + at;
    bar.paintMarkers(canvas, bh, x, barWidth: w, graphScale: magnification, graphShift: at - px * magnification);
    canvas.drawRect(Rect.fromLTWH(at - 1, 0, 2, bh), Paint()..color = MiniTimelinePainter._playhead);
    canvas.restore();
    canvas.drawRRect(
        rbox,
        Paint()
          ..color = _border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
    canvas.drawPath(
        Path()
          ..moveTo(px - notch, bh)
          ..lineTo(px + notch, bh)
          ..lineTo(px, bh + notch)
          ..close(),
        Paint()..color = _border);
  }

  @override
  bool shouldRepaint(covariant MiniTimelineLoupePainter old) => old.bar != bar || old.barHeight != barHeight;
}
