import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/core.dart';
import '../editor_controller.dart';
import '../render/timeline_painter.dart';

/// Timeline interaction:
/// * one-finger drag scrubs, two-finger pinch zooms; in Compose the
///   playhead snaps to the beat divisor (the finger moves a free position,
///   the playhead jumps to the snap tick nearest it), elsewhere it is free;
///   a fast scrub keeps gliding after release and slows down (fling);
///   touching the timeline, playing or any other seek stops it;
/// * tap on an object selects it, tap on empty space does nothing;
/// * dragging a selected object moves the selection in time (snapped);
///   unselected objects don't move, so scrubbing over them is safe;
/// * long-press then drag, or double-tap then drag, selects the objects
///   starting in that time range (shift/ctrl = additive); this never moves
///   objects or the playhead;
/// * dragging the end of the selected spinner changes its length, of the
///   selected slider its repeat count;
/// * mouse wheel steps by the beat divisor, ctrl+wheel zooms;
/// * breaks: drag a break's edge to move it (snapped, kept clear of the
///   objects), tap its "Break ×" pill to delete it, tap the "+ Break" pill
///   shown in a long enough gap between objects to add one;
/// * during a range selection, object time drag, end drag or break edge
///   drag, holding the finger near the left / right edge scrolls the
///   timeline that way (faster nearer the edge), so the drag can reach
///   beyond the visible stretch.
///
/// With [objectsInBackground] (every mode but Compose) objects are only faded context:
/// none of the object gestures (select, move, end drag, range select) work,
/// only scrubbing, zooming and the wheel.
class TimelineView extends StatefulWidget {
  final EditorController controller;
  final double height;
  final bool objectsInBackground;
  const TimelineView({super.key, required this.controller, this.height = 96, this.objectsInBackground = false});

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends State<TimelineView> with TickerProviderStateMixin {
  double _zoomAtStart = 1;
  bool _scrubbed = false;
  bool _endDrag = false;
  bool _timeDrag = false;
  bool _breakDrag = false;

  /// Grabbed object's time minus the time under the finger.
  double _grabOffset = 0;
  bool _boxing = false;
  double _width = 0;

  // Double-tap-drag detection, from raw pointer events.
  int _pointersDown = 0;
  Offset? _downAt;
  Duration _downTime = Duration.zero;
  bool _downMoved = false;
  Offset? _lastTapAt;
  Duration? _lastTapTime;

  /// The second press of a double tap: the next drag box-selects.
  bool _doubleTapArmed = false;

  /// Movement that turns a press into a drag (well under the scale
  /// recognizer's pan slop, so the box wins over scrubbing).
  static const _dragSlop = 8.0;

  /// Touch radius around an object's end handle, in logical pixels.
  static const _endHitRadius = 24.0;

  /// Touch radius around a break's edge.
  static const _breakEdgeHitRadius = 16.0;

  /// Extra touch area around the break pills.
  static const _pillSlop = 6.0;

  // Scrub fling (inertia after a fast one-finger scrub).
  late final Ticker _flingTicker = createTicker(_onFlingTick);
  FrictionSimulation? _fling;

  /// Time the fling last seeked to; any other change to `c.time` (a seek
  /// elsewhere, playback) stops the fling.
  double _flingTime = 0;

  /// Playhead time when the fling started.
  double _flingStartTime = 0;

  /// The unsnapped scrub position (Compose snaps the playhead to it).
  double _scrubTime = 0;

  /// Seeks the scrub to [t]: snapped in Compose, free elsewhere.
  void _scrubTo(double t) {
    _scrubTime = t;
    if (_objectsEditable) {
      c.seekSnapped(t);
    } else {
      c.seek(t);
    }
  }

  /// Release speed below which a scrub just stops, in logical px/s.
  static const _minFlingSpeed = 300.0;

  /// Release speeds above this are clamped, in logical px/s.
  static const _maxFlingSpeed = 8000.0;

  /// Fraction of the velocity left after one second (lower = stops sooner).
  static const _flingDrag = 0.05;

  EditorController get c => widget.controller;

  @override
  void dispose() {
    _flingTicker.dispose();
    _edgeTicker.dispose();
    super.dispose();
  }

  // Edge auto-scroll while dragging something on the timeline.

  /// Width of the zone at each end that scrolls, in logical pixels.
  static const edgeZone = 48.0;

  /// Scroll speed at the zone's inner edge / at the very edge, in
  /// timeline widths per second (so the time covered per second follows
  /// the zoom: one screenful at most).
  static const _edgeMinSpeed = 0.1;
  static const _edgeMaxSpeed = 1.0;

  late final Ticker _edgeTicker = createTicker(_onEdgeTick);
  Duration _edgeLast = Duration.zero;

  /// Where the dragging finger is (local x), while a drag that follows it
  /// is under way.
  double? _dragX;

  /// Whether a drag that should auto-scroll is under way.
  bool get _edgeDrag => _boxing || _timeDrag || _endDrag || _breakDrag;

  /// The scroll speed (logical px/s, negative = towards earlier) for a
  /// finger at [x]: zero outside the edge zones.
  double _edgeSpeed(double x) {
    double speed(double depth) {
      final f = (depth / edgeZone).clamp(0.0, 1.0);
      return (_edgeMinSpeed + (_edgeMaxSpeed - _edgeMinSpeed) * f * f) * _width;
    }

    if (x < edgeZone) return -speed(edgeZone - x);
    if (x > _width - edgeZone) return speed(x - (_width - edgeZone));
    return 0;
  }

  /// A drag moved to [x]: starts or stops the edge scroll.
  void _trackDrag(double x) {
    _dragX = x;
    final scroll = _edgeDrag && _edgeSpeed(x) != 0;
    if (scroll && !_edgeTicker.isActive) {
      _edgeLast = Duration.zero;
      _edgeTicker.start();
    } else if (!scroll && _edgeTicker.isActive) {
      _edgeTicker.stop();
    }
  }

  void _stopEdgeScroll() {
    _dragX = null;
    if (_edgeTicker.isActive) _edgeTicker.stop();
  }

  void _onEdgeTick(Duration elapsed) {
    final x = _dragX;
    if (!mounted || x == null || !_edgeDrag) return _stopEdgeScroll();
    final dt = (elapsed - _edgeLast).inMicroseconds / 1e6;
    _edgeLast = elapsed;
    if (dt <= 0 || dt > 0.1) return; // first tick / a hitch: no jump
    final before = c.time.value;
    c.seek(before + _edgeSpeed(x) * dt / c.timelineZoom);
    if (c.time.value == before) return; // at the start / end of the song
    // The time under the finger changed: move what is being dragged.
    _followDrag(x);
  }

  /// Applies the current drag at [x] (the time under it).
  void _followDrag(double x) {
    if (_boxing) {
      c.updateTimelineBox(_timeAtX(x));
    } else if (_timeDrag) {
      c.updateTimeDrag(_timeAtX(x) + _grabOffset);
    } else if (_breakDrag) {
      c.updateBreakDrag(_timeAtX(x) + _grabOffset);
    } else if (_endDrag) {
      c.updateEndDrag(_timeAtX(x));
    }
  }

  /// Continues the scrub at [pxPerSecond] (finger velocity), decelerating.
  void _startFling(double pxPerSecond) {
    _stopFling();
    final v = pxPerSecond.clamp(-_maxFlingSpeed, _maxFlingSpeed);
    if (v.abs() < _minFlingSpeed || _width <= 0) return;
    // Simulated in pixels (zoom changes mid-fling are not possible: any
    // touch stops it), converted to time on each tick.
    _fling = FrictionSimulation(_flingDrag, 0, v, tolerance: const Tolerance(velocity: 20));
    _flingTime = c.time.value;
    _flingStartTime = _scrubTime;
    _flingTicker.start();
  }

  void _onFlingTick(Duration elapsed) {
    final sim = _fling;
    if (sim == null || !mounted) return _stopFling();
    if (c.isPlaying || c.time.value != _flingTime) return _stopFling();
    final s = elapsed.inMicroseconds / 1e6;
    final target = _flingStartTime - sim.x(s) / c.timelineZoom;
    _scrubTo(target);
    _flingTime = c.time.value;
    // Done, or stuck against the start / end of the song.
    if (sim.isDone(s) || target <= c.minTime || target >= c.maxTime) _stopFling();
  }

  void _stopFling() {
    _fling = null;
    if (_flingTicker.isActive) _flingTicker.stop();
  }
  bool get _objectsEditable => !widget.objectsInBackground;

  void _onScaleStart(ScaleStartDetails d) {
    if (d.pointerCount == 1) _beginDoubleTapBox();
    if (_boxing) return;
    _zoomAtStart = c.timelineZoom;
    _scrubbed = false;
    if (!_objectsEditable) return;
    final h = c.endDraggable;
    if (d.pointerCount == 1 && h != null) {
      final x = TimelinePainter.xOf(c.endTimeOf(h), c.time.value, c.timelineZoom, _width);
      if ((d.localFocalPoint.dx - x).abs() <= _endHitRadius) {
        c.pause();
        _endDrag = true;
        c.beginEndDrag();
        return;
      }
    }
    // Measured from where the finger went down (the scale start only fires
    // after the pan slop, which a quick drag crosses well past an object).
    final at = _downAt ?? d.localFocalPoint;
    final grabbed = d.pointerCount == 1 ? _objectAt(at) : null;
    if (grabbed != null && c.selection.contains(grabbed) && c.beginTimeDrag(grabbed)) {
      c.pause();
      _timeDrag = true;
      _grabOffset = grabbed.time - _timeAtX(at.dx);
      return;
    }
    // Break edges.
    final edge = d.pointerCount == 1 && grabbed == null && _objectAt(at) == null ? _breakEdgeAt(at.dx) : null;
    if (edge != null && c.beginBreakDrag(edge.$1, end: edge.$2)) {
      c.pause();
      _breakDrag = true;
      _grabOffset = (edge.$2 ? edge.$1.end : edge.$1.start) - _timeAtX(at.dx);
    }
  }

  /// The break edge nearest to [x] within reach: the break and whether it
  /// is its end.
  (BreakPeriod, bool)? _breakEdgeAt(double x) {
    (BreakPeriod, bool)? best;
    var bestDist = _breakEdgeHitRadius;
    for (final b in c.breaks) {
      for (final (t, isEnd) in [(b.start, false), (b.end, true)]) {
        final dist = (TimelinePainter.xOf(t, c.time.value, c.timelineZoom, _width) - x).abs();
        if (dist <= bestDist) {
          bestDist = dist;
          best = (b, isEnd);
        }
      }
    }
    return best;
  }

  /// Handles a tap on a break pill: deletes that break or adds the
  /// suggested one. Returns whether a pill was hit.
  bool _tapBreakPill(Offset p) {
    final now = c.time.value, zoom = c.timelineZoom, h = widget.height;
    for (final b in c.breaks) {
      final r = TimelinePainter.breakPillRect(b.start, b.end, now, zoom, _width, h);
      if (r != null && r.inflate(_pillSlop).contains(p)) {
        if (!c.removeBreak(b)) continue;
        return true;
      }
    }
    for (final gap in c.insertableBreaks) {
      final r = TimelinePainter.breakPillRect(gap.$1, gap.$2, now, zoom, _width, h);
      if (r != null && r.inflate(_pillSlop).contains(p)) {
        c.addBreak(gap);
        return true;
      }
    }
    return false;
  }

  double _timeAtX(double x) => TimelinePainter.timeAt(x, c.time.value, c.timelineZoom, _width);

  /// The object marker under [p] (nearest in time), or null. Objects sit on
  /// the middle line; above / below it the strip only seeks.
  HitObject? _objectAt(Offset p) {
    final objR = TimelinePainter.objectRadius(widget.height);
    if ((p.dy - widget.height / 2).abs() > objR + 6) return null;
    final t = _timeAtX(p.dx);
    final slack = objR / c.timelineZoom;
    final hits = c.objectsInRange(t - slack, t + slack).toList();
    if (hits.isEmpty) return null;
    hits.sort((a, b) => (a.time - t).abs().compareTo((b.time - t).abs()));
    return hits.first;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_boxing) return;
    if (_timeDrag || _breakDrag || _endDrag) {
      _followDrag(d.localFocalPoint.dx);
      _trackDrag(d.localFocalPoint.dx);
      return;
    }
    if (d.pointerCount >= 2) {
      c.timelineZoom = _zoomAtStart * d.horizontalScale;
      return;
    }
    final dx = d.focalPointDelta.dx;
    if (dx == 0) return;
    if (!_scrubbed) {
      c.pause();
      _scrubbed = true;
      _scrubTime = c.time.value;
    }
    _scrubTo(_scrubTime - dx / c.timelineZoom);
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_timeDrag || _endDrag || _breakDrag) _stopEdgeScroll();
    if (_timeDrag) {
      _timeDrag = false;
      c.endTimeDrag();
      return;
    }
    if (_endDrag) {
      _endDrag = false;
      c.endEndDrag();
      return;
    }
    if (_breakDrag) {
      _breakDrag = false;
      c.endBreakDrag();
      return;
    }
    if (_scrubbed && !_boxing && d.pointerCount == 0) _startFling(d.velocity.pixelsPerSecond.dx);
    _scrubbed = false;
  }

  static bool get _additive {
    final keys = HardwareKeyboard.instance;
    return keys.isShiftPressed || keys.isControlPressed;
  }

  void _onTapUp(TapUpDetails d) {
    if (_boxing || !_objectsEditable) return;
    if (_tapBreakPill(d.localPosition)) return;
    // stable: on the selected slider, a tap on its head / repeat / tail
    // picks that edge for the hitsound toggles (again: the whole slider).
    final edge = _additive ? null : _edgeAt(d.localPosition);
    if (edge != null) {
      c.selectEdge(c.selectedEdge == edge ? null : edge);
      return;
    }
    final hit = _objectAt(d.localPosition);
    if (hit != null) c.select(hit, additive: _additive);
  }

  /// The edge of the selected slider under [p] (nearest in time), or null.
  int? _edgeAt(Offset p) {
    final s = c.editedSlider;
    if (s == null || c.tool != EditorTool.select) return null;
    final objR = TimelinePainter.objectRadius(widget.height);
    if ((p.dy - widget.height / 2).abs() > objR + 6) return null;
    int? best;
    var bestDist = objR;
    final times = c.edgeTimes(s);
    for (var i = 0; i < times.length; i++) {
      final dist = (TimelinePainter.xOf(times[i], c.time.value, c.timelineZoom, _width) - p.dx).abs();
      if (dist <= bestDist) {
        bestDist = dist;
        best = i;
      }
    }
    return best;
  }

  void _onPointerDown(PointerDownEvent e) {
    _stopFling();
    _pointersDown++;
    _downAt = e.localPosition;
    _downTime = e.timeStamp;
    _downMoved = false;
    final lastAt = _lastTapAt, lastTime = _lastTapTime;
    _doubleTapArmed = _pointersDown == 1 &&
        lastAt != null &&
        lastTime != null &&
        e.timeStamp - lastTime <= kDoubleTapTimeout &&
        (e.localPosition - lastAt).distance <= kDoubleTapSlop;
    _lastTapAt = _lastTapTime = null;
    if (_pointersDown > 1) _cancelDoubleTapBox();
  }

  void _onPointerMove(PointerMoveEvent e) {
    final down = _downAt;
    if (down == null) return;
    if (!_downMoved && (e.localPosition - down).distance > _dragSlop) {
      _downMoved = true;
      _beginDoubleTapBox();
    }
    if (_boxing && _doubleTapArmed) {
      c.updateTimelineBox(_timeAtX(e.localPosition.dx));
      _trackDrag(e.localPosition.dx);
    }
  }

  /// Starts the double-tap-drag box at the press position. Called from
  /// whichever sees the drag first: the raw pointer move or the scale start.
  void _beginDoubleTapBox() {
    final down = _downAt;
    if (!_objectsEditable || !_doubleTapArmed || _boxing || _endDrag || _timeDrag || _breakDrag || down == null) {
      return;
    }
    c.pause();
    _boxing = true;
    HapticFeedback.selectionClick();
    c.beginTimelineBox(_timeAtX(down.dx), additive: _additive);
  }

  void _onPointerUp(PointerEvent e) {
    _pointersDown = (_pointersDown - 1).clamp(0, 1 << 30);
    final wasTap = e is PointerUpEvent &&
        _pointersDown == 0 &&
        !_downMoved &&
        !_doubleTapArmed &&
        e.timeStamp - _downTime <= kLongPressTimeout;
    if (wasTap) {
      _lastTapAt = _downAt;
      _lastTapTime = e.timeStamp;
    }
    if (_doubleTapArmed) _cancelDoubleTapBox();
    if (_pointersDown == 0) _downAt = null;
  }

  void _cancelDoubleTapBox() {
    if (!_doubleTapArmed) return;
    _doubleTapArmed = false;
    if (_boxing) {
      _boxing = false;
      _stopEdgeScroll();
      c.endTimelineBox();
    }
  }

  void _onLongPressStart(LongPressStartDetails d) {
    if (_endDrag || _timeDrag || _breakDrag || _boxing) return;
    c.pause();
    _boxing = true;
    HapticFeedback.selectionClick();
    c.beginTimelineBox(_timeAtX(d.localPosition.dx), additive: _additive);
  }

  void _onLongPressMove(LongPressMoveUpdateDetails d) {
    if (!_boxing) return;
    c.updateTimelineBox(_timeAtX(d.localPosition.dx));
    _trackDrag(d.localPosition.dx);
  }

  void _onLongPressEnd() {
    if (!_boxing) return;
    _boxing = false;
    _stopEdgeScroll();
    c.endTimelineBox();
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    _stopFling();
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isAltPressed) {
      // lazer: Alt + wheel (Ctrl too), 2% of the zoom range per step.
      c.stepTimelineZoom(e.scrollDelta.dy > 0 ? -1 : 1);
    } else {
      c.pause();
      c.stepBeat(forward: e.scrollDelta.dy > 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth;
        _width = width;
        c.timelineWidth = width;
        return Listener(
          onPointerSignal: _onPointerSignal,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerUp,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: _objectsEditable ? _onTapUp : null,
            onLongPressStart: _objectsEditable ? _onLongPressStart : null,
            onLongPressMoveUpdate: _objectsEditable ? _onLongPressMove : null,
            onLongPressEnd: _objectsEditable ? (_) => _onLongPressEnd() : null,
            onLongPressCancel: _objectsEditable ? _onLongPressEnd : null,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            child: RepaintBoundary(
              child: CustomPaint(
                painter: TimelinePainter(c, objectsInBackground: widget.objectsInBackground),
                size: Size(width, widget.height),
              ),
            ),
          ),
        );
      }),
    );
  }
}
