import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/core.dart';
import '../editor_controller.dart';
import '../render/playfield_painter.dart';
import '../render/playfield_transform.dart';

/// Playfield canvas + touch/mouse interaction.
///
/// * Select tool: tap selects (shift/ctrl = additive), drag on a selected or
///   hit object moves the selection (one undo step per drag); a drag on empty
///   playfield draws a selection box (shift/ctrl = additive). With a single
///   slider selected, its control points can be tapped (selects the point)
///   and dragged. Long-press on a line joining two of its points opens a
///   small "Add point" menu (Ctrl+click with a mouse adds directly);
///   long-press on a point opens "Remove point". A long-press anywhere else
///   acts like a drag started there.
/// * Circle tool: tap places a circle at the current snapped time.
/// * Slider tool: each tap adds a point; tapping a point again toggles it
///   red (a segment boundary). Create / Enter creates the slider.
/// * Spinner tool: tap places a spinner at the current snapped time.
/// * Circle / slider tool, touch drag: precision placement. A cursor and a
///   ghost follow the finger; releasing places there.
/// * Two-finger tap undoes, three-finger tap redoes.
/// * Selection box (lazer's, Select tool, two or more objects or a slider):
///   drag a corner to scale from the opposite corner, a side's middle to
///   stretch one axis from the opposite side, the round handle above
///   it to rotate around its centre; two fingers placed on the box rotate,
///   scale and move the selection directly (each gesture one undo step;
///   angles near a right angle and scales near 100% snap). The lock button
///   beside the rotation handle (shared with the Scale panel) unlocks the
///   aspect: corners then follow the finger in both axes and two fingers
///   stretch width and height with their spread across / down, without
///   turning.
/// * Two-finger pinch / drag elsewhere zooms and pans the view (Ctrl+wheel
///   with a mouse). A second finger cancels a one-finger drag already under way.
///   While zoomed in, a pill at the top shows the zoom and resets it.
class PlayfieldView extends StatefulWidget {
  final EditorController controller;
  const PlayfieldView({super.key, required this.controller});

  /// Touch target radius of control points, in logical pixels.
  static const handleHitRadius = 22.0;

  /// Touch target radius of the selection box's handles.
  static const boxHandleHitRadius = 24.0;

  /// How far outside the selection box two fingers still grab it.
  static const boxGrabMargin = 24.0;

  /// How close (logical pixels) a long-press must be to a line joining two
  /// control points to offer "Add point" there.
  static const legHitRadius = 16.0;

  @override
  State<PlayfieldView> createState() => _PlayfieldViewState();
}

class _PlayfieldViewState extends State<PlayfieldView> {
  Vec2? _dragStart;
  bool _draggingPoint = false;
  bool _boxing = false;

  /// Pinch in progress: the zoom at its start and the osu!pixel point
  /// under the fingers, which stays under them.
  (PlayfieldZoom, Vec2)? _pinch;
  Size _size = Size.zero;

  /// Where the latest pointer went down. Scale gestures report their start
  /// where the slop was crossed; boxes and moves start at the finger.
  Offset? _lastDown;

  /// Every pointer down on the view and where it is now, and the focal point
  /// (their mean) when one last went down or up. The scale gesture measures
  /// its scale / rotation / focal movement from that moment (fingers down,
  /// [DragStartBehavior.down]), not from where it reports its start (after
  /// the slop), so pinches anchor there to keep the map under the fingers.
  final Map<int, Offset> _pointerAt = {};
  Offset? _configFocal;

  /// The fingers' mean distance from [_configFocal] across and down at that
  /// moment (the gesture's horizontal / vertical scale are relative to it).
  Offset _configSpan = Offset.zero;

  void _reconfigurePointers() {
    if (_pointerAt.isEmpty) return;
    final focal = _configFocal = _pointerAt.values.reduce((a, b) => a + b) / _pointerAt.length.toDouble();
    var sx = 0.0, sy = 0.0;
    for (final p in _pointerAt.values) {
      sx += (p.dx - focal.dx).abs();
      sy += (p.dy - focal.dy).abs();
    }
    _configSpan = Offset(sx, sy) / _pointerAt.length.toDouble();
  }

  /// Selection box drag with one finger: a corner (scale from the opposite
  /// corner), a side (one axis, from the opposite side) or the rotation
  /// handle (around the centre).
  _BoxDrag? _boxDrag;

  /// Two-finger transform of the selection: the box centre and the
  /// osu!pixel point under the fingers at the start, the box's and the
  /// objects' extent along its longer side, and the gesture's scale at the
  /// start (it may have begun with one finger). With the aspect unlocked
  /// ([_TwoFinger.free]) each axis on its own.
  _TwoFinger? _twoFinger;

  /// Fingers closer together than this across (down) when two-finger
  /// stretching starts leave the width (height) alone: their spread along
  /// that axis is too small to measure.
  static const _minStretchSpan = 16.0;

  /// The selection box on screen and where its rotation handle is.
  (Rect, Offset)? _boxOnScreen(PlayfieldTransform tf) {
    final b = c.selectionBounds;
    if (b == null) return null;
    return PlayfieldPainter.selectionBoxGeometry(b.$1, b.$2, tf, _size);
  }

  /// Angles within this of a right angle snap to it, scales within
  /// [_scaleSnap] of 1 to 1 (so a two-finger move doesn't wobble).
  static const _scaleSnap = 0.03;

  /// Whether the last angle shown was snapped to a right angle (a light
  /// tick when it locks on).
  bool _angleSnapped = false;

  // The turn so far, followed continuously (clockwise positive): raw
  // angles jump by a full turn at ±180°, which would flip the sign of a
  // long counter-clockwise turn.
  double _turnLast = 0;
  double _turnTotal = 0;

  void _startTurn(double raw) {
    _turnLast = raw;
    _turnTotal = 0;
    _angleSnapped = false;
  }

  /// Adds the change from the last raw angle (taken the short way round)
  /// and returns the total turn.
  double _turnTo(double raw) {
    var d = raw - _turnLast;
    while (d > math.pi) {
      d -= 2 * math.pi;
    }
    while (d < -math.pi) {
      d += 2 * math.pi;
    }
    _turnLast = raw;
    return _turnTotal += d;
  }

  double _snapAngle(double a) {
    final deg = a * 180 / math.pi;
    final snapped = EditorController.snapRightAngle(deg);
    final locked = snapped != deg;
    if (locked && !_angleSnapped) HapticFeedback.selectionClick();
    _angleSnapped = locked;
    return snapped * math.pi / 180;
  }

  static double _snapScale(double s) => (s - 1).abs() <= _scaleSnap ? 1 : s;

  /// The smallest scale a box drag gives (the box can't be made smaller
  /// than its padding).
  static const _minScale = 0.05;

  /// Starts a one-finger box drag at [local] if it is on a handle.
  bool _startBoxDrag(Offset local, PlayfieldTransform tf) {
    final g = _boxOnScreen(tf);
    if (g == null) return false;
    final (rect, rotHandle) = g;
    const reach = PlayfieldView.boxHandleHitRadius;
    // The nearest handle within reach: rotation, corners (both axes), then
    // the sides' middles (one axis; true = across).
    final corners = [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft];
    final handles = <(Offset, bool?)>[
      (rotHandle, null),
      for (final p in corners) (p, null),
      for (final (p, across) in PlayfieldPainter.selectionEdgeHandles(rect, padding: c.circleRadius * tf.scale))
        (p, across),
    ];
    var best = -1;
    var bestDist = reach + 1e-9; // ties: the earlier handle
    for (var i = 0; i < handles.length; i++) {
      final d = (local - handles[i].$1).distance;
      if (d < bestDist) {
        best = i;
        bestDist = d;
      }
    }
    if (best < 0) return false;
    if (best == 0) {
      if (!c.beginTransform(label: 'Rotate')) return false;
      c.pause();
      final centre = tf.toOsu(rect.center);
      final v = tf.toOsu(local) - centre;
      _startTurn(math.atan2(v.y, v.x));
      _boxDrag = _BoxDrag.rotate(centre);
      return true;
    }
    // The box is the objects' bounds plus a circle radius, which doesn't
    // scale: scale from the objects' opposite corner (side) and fit their
    // corner (side) plus that padding to the finger, so both box corners
    // (sides) stay put / follow. A side's handle has no padding or span
    // along the side, so only its axis counts.
    final (at, axis) = handles[best];
    final far = tf.toOsu(at), near = tf.toOsu(rect.center * 2 - at);
    final pad = Vec2((far.x - near.x).sign, (far.y - near.y).sign) * c.circleRadius;
    final pivot = near + pad, span = far - pad - pivot;
    if (span.lengthSquared < 1e-6 || !c.beginTransform(label: 'Scale')) return false;
    c.pause();
    _boxDrag = _BoxDrag.scale(pivot, pad, span, axis);
    return true;
  }

  void _updateBoxDrag(Offset local, PlayfieldTransform tf) {
    final d = _boxDrag!;
    final p = tf.toOsu(local);
    if (d.rotating) {
      final v = p - d.pivot;
      c.updateFreeTransform(pivot: d.pivot, radians: _snapAngle(_turnTo(math.atan2(v.y, v.x))));
    } else {
      final s = _snapScale(math.max(_minScale, (p - d.pad - d.pivot).dot(d.span) / d.span.lengthSquared));
      // Unlocked, a corner follows the finger in both axes (an axis the
      // objects don't spread along stays).
      double axis(double to, double span) => span.abs() < 1 ? 1 : _snapScale(math.max(_minScale, to / span));
      final to = p - d.pad - d.pivot;
      switch (d.across) {
        case null when !c.scaleLocksAspect:
          c.updateFreeTransform(
              pivot: d.pivot, scale: axis(to.x, d.span.x), scaleY: axis(to.y, d.span.y), shiftToFit: false);
        case null:
          c.updateFreeTransform(pivot: d.pivot, scale: s, shiftToFit: false);
        case true:
          c.updateFreeTransform(pivot: d.pivot, scale: s, scaleY: 1, shiftToFit: false);
        case false:
          c.updateFreeTransform(pivot: d.pivot, scale: 1, scaleY: s, shiftToFit: false);
      }
    }
  }

  /// Two fingers on the selection box: starts transforming it.
  /// [scale], [horizontal] and [vertical] are the gesture's scales then.
  bool _startTwoFinger(Offset focal, double scale, double rotation, PlayfieldTransform tf,
      {double horizontal = 1, double vertical = 1}) {
    final g = _boxOnScreen(tf);
    if (g == null || !g.$1.inflate(PlayfieldView.boxGrabMargin).contains(focal)) return false;
    final free = !c.scaleLocksAspect;
    if (!c.beginTransform(label: free ? 'Scale' : 'Rotate / scale')) return false;
    c.pause();
    _startTurn(rotation);
    final (min, max) = c.selectionBounds!;
    final size = max - min;
    final box = math.max(size.x, size.y);
    final pad = 2 * c.circleRadius;
    _twoFinger = _TwoFinger(
      centre: (min + max) / 2,
      focal: tf.toOsu(focal),
      box: box,
      objects: box - pad,
      scale0: scale,
      free: free,
      size: size,
      objectSize: size - Vec2(pad, pad),
      horizontal0: _configSpan.dx * horizontal >= _minStretchSpan ? horizontal : null,
      vertical0: _configSpan.dy * vertical >= _minStretchSpan ? vertical : null,
    );
    return true;
  }

  /// The box (not just the objects in it) follows the fingers: its centre
  /// moves and turns with them and its longer side grows with their spread.
  /// The box keeps a circle radius around the objects, so they scale more.
  void _updateTwoFinger(ScaleUpdateDetails d, PlayfieldTransform tf) {
    final t = _twoFinger!;
    if (t.free) return _updateTwoFingerStretch(t, d, tf);
    final k = d.scale / t.scale0;
    final radians = _snapAngle(_turnTo(d.rotation));
    final s = t.objects > 1e-6 ? math.max(_minScale, (k * t.box - (t.box - t.objects)) / t.objects) : 1.0;
    final v = (t.centre - t.focal) * k;
    final cos = math.cos(radians), sin = math.sin(radians);
    final centre = tf.toOsu(d.localFocalPoint) + Vec2(v.x * cos - v.y * sin, v.x * sin + v.y * cos);
    c.updateFreeTransform(pivot: t.centre, radians: radians, scale: _snapScale(s), offset: centre - t.centre);
  }

  /// Aspect unlocked: no turn; the box's width grows with the fingers'
  /// spread across and its height with their spread down (an axis they
  /// started too close along stays), and its centre moves with them.
  void _updateTwoFingerStretch(_TwoFinger t, ScaleUpdateDetails d, PlayfieldTransform tf) {
    final h0 = t.horizontal0, v0 = t.vertical0;
    final kx = h0 == null ? 1.0 : d.horizontalScale / h0;
    final ky = v0 == null ? 1.0 : d.verticalScale / v0;
    double axis(double k, double box, double objects) =>
        objects > 1e-6 ? _snapScale(math.max(_minScale, (k * box - (box - objects)) / objects)) : 1.0;
    final v = t.centre - t.focal;
    final centre = tf.toOsu(d.localFocalPoint) + Vec2(v.x * kx, v.y * ky);
    c.updateFreeTransform(
      pivot: t.centre,
      scale: axis(kx, t.size.x, t.objectSize.x),
      scaleY: axis(ky, t.size.y, t.objectSize.y),
      offset: centre - t.centre,
    );
  }

  void _endTwoFinger() {
    _twoFinger = null;
    c.endTransform(apply: true);
  }

  /// Precision placement: the cursor in local coordinates, or null.
  Offset? _cursor;

  // Multi-finger taps: pointers of the current touch sequence.
  final Map<int, Offset> _down = {};
  int _maxPointers = 0;
  bool _moved = false;
  Duration _sequenceStart = Duration.zero;

  /// Movement (logical pixels) / duration within which fingers count as a tap.
  static const _tapSlop = 20.0;
  static const _tapTime = Duration(milliseconds: 400);

  EditorController get c => widget.controller;

  void _onPointerDown(PointerDownEvent e) {
    _lastDown = e.localPosition;
    _pointerAt[e.pointer] = e.localPosition;
    _reconfigurePointers();
    // Circle tool: show the circle to be placed as soon as the finger (or
    // button) is down, not only once it moves; releasing places it.
    if (c.tool == EditorTool.circle && _down.isEmpty && e.buttons & kSecondaryMouseButton == 0) {
      _moveCursor(e.localPosition, _tf);
    }
    if (e.kind != PointerDeviceKind.touch) return;
    if (_down.isEmpty) {
      _maxPointers = 0;
      _moved = false;
      _sequenceStart = e.timeStamp;
    }
    _down[e.pointer] = e.localPosition;
    if (_down.length > _maxPointers) _maxPointers = _down.length;
    if (_down.length == 2) _cancelOneFingerDrag();
  }

  /// A second finger turns the touch into a pinch: undo what the first
  /// finger started (the gesture callbacks for it are ignored from here on).
  void _cancelOneFingerDrag() {
    if (_cursor != null) {
      setState(() => _cursor = null);
      c.placementCursor = null;
    }
    if (_draggingPoint) {
      _draggingPoint = false;
      c.endPointDrag(cancel: true);
    }
    if (_boxing) {
      _boxing = false;
      c.endBoxSelect();
    }
    if (_dragStart != null) {
      _dragStart = null;
      c.endMoveSelection(cancel: true);
    }
    if (_boxDrag != null) {
      _boxDrag = null;
      c.endTransform(apply: false);
    }
  }

  /// Ctrl+wheel zooms around the mouse.
  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || !HardwareKeyboard.instance.isControlPressed) return;
    final zoom = c.playfieldZoom.value;
    final at = e.localPosition;
    final p = PlayfieldTransform.fit(_size, zoom).toOsu(at);
    c.playfieldZoom.value = PlayfieldTransform.zoomKeeping(
      _size,
      p,
      at,
      zoom.factor * math.pow(1.0015, -e.scrollDelta.dy),
    );
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_pointerAt.containsKey(e.pointer)) _pointerAt[e.pointer] = e.localPosition;
    final start = _down[e.pointer];
    if (start != null && (e.localPosition - start).distance > _tapSlop) _moved = true;
  }

  void _onPointerUp(PointerEvent e, {bool cancelled = false}) {
    if (_pointerAt.remove(e.pointer) != null) _reconfigurePointers();
    // A press that ended in neither a tap nor a drag (the gesture went
    // elsewhere): drop the preview. Taps and drags handle it first (they
    // run after this, in the same event).
    if (_cursor != null) {
      Future.microtask(() {
        if (!mounted || _cursor == null || _down.isNotEmpty) return;
        setState(() => _cursor = null);
        c.placementCursor = null;
      });
    }
    if (_down.remove(e.pointer) == null) return;
    // The system took the touch away: drop the drag instead of applying it.
    if (cancelled) _cancelOneFingerDrag();
    if (_down.isNotEmpty) return;
    if (cancelled || _moved || e.timeStamp - _sequenceStart > _tapTime) return;
    if (_maxPointers == 2) {
      c.undo();
    } else if (_maxPointers == 3) {
      c.redo();
    }
  }

  /// Taps that are part of a multi-finger gesture don't place or select.
  bool get _multiTouch => _maxPointers >= 2;

  bool get _additiveModifier {
    final keys = HardwareKeyboard.instance;
    return keys.isShiftPressed || keys.isControlPressed || keys.isMetaPressed;
  }

  void _onTapUp(TapUpDetails d, PlayfieldTransform tf) {
    if (_multiTouch) return;
    final pos = tf.toOsu(d.localPosition);
    final handle = PlayfieldView.handleHitRadius / tf.scale;
    switch (c.tool) {
      case EditorTool.circle:
        // Where the preview showed it (the press position, not moved).
        if (_cursor != null) {
          setState(() => _cursor = null);
          c.placementCursor = null;
        }
        c.placeCircle(pos);
      case EditorTool.slider:
        c.sliderToolTap(pos, tolerance: handle);
      case EditorTool.spinner:
        c.placeSpinner();
      case EditorTool.select:
        final point = c.hitTestControlPoint(pos, handle);
        if (point != null) {
          c.selectedPoint = point;
        } else if (HardwareKeyboard.instance.isControlPressed &&
            c.insertControlPointAt(pos, tolerance: PlayfieldView.legHitRadius / tf.scale) != null) {
          // lazer's Ctrl+click: a control point on the selected slider.
        } else {
          c.select(c.hitTest(pos, c.time.value), additive: _additiveModifier);
        }
    }
  }

  void _onScaleStart(ScaleStartDetails d, PlayfieldTransform tf) {
    if (d.pointerCount >= 2) {
      // Scale 1 / rotation 0 / this focal point are where the fingers were
      // when the last of them went down, not where the slop was crossed.
      final focal = _configFocal ?? d.localFocalPoint;
      if (_startTwoFinger(focal, 1, 0, tf)) return;
      _pinch = (c.playfieldZoom.value, tf.toOsu(focal));
      return;
    }
    // The finger left over after a pinch doesn't start editing.
    if (_multiTouch) return;
    _onPanStart(_lastDown ?? d.localFocalPoint, d.kind, tf);
  }

  void _onScaleUpdate(ScaleUpdateDetails d, PlayfieldTransform tf) {
    // A second finger while drawing: it was a pinch, not a stroke.
    if (_freehand && d.pointerCount >= 2) {
      _freehand = false;
      c.cancelFreehand();
    }
    if (_twoFinger != null) {
      // A finger lifted: keep what was done, ignore the rest.
      if (d.pointerCount < 2) return _endTwoFinger();
      _updateTwoFinger(d, tf);
      return;
    }
    // The second finger came after the first one had started moving.
    if (d.pointerCount >= 2 &&
        _pinch == null &&
        _startTwoFinger(d.localFocalPoint, d.scale, d.rotation, tf,
            horizontal: d.horizontalScale, vertical: d.verticalScale)) {
      return;
    }
    final pinch = _pinch;
    if (pinch != null) {
      final (start, anchor) = pinch;
      c.playfieldZoom.value = PlayfieldTransform.zoomKeeping(_size, anchor, d.localFocalPoint, start.factor * d.scale);
      return;
    }
    if (d.pointerCount >= 2) return;
    _onPanUpdate(d.localFocalPoint, tf);
  }

  void _onScaleEnd() {
    if (_twoFinger != null) return _endTwoFinger();
    if (_pinch != null) {
      _pinch = null;
      return;
    }
    _onPanEnd();
  }

  // Long-press (Select tool): on a point of the edited slider it offers
  // "Remove point", on a line joining two points "Add point" with a
  // see-through preview of the new point (the edit happens only when the
  // menu's button is tapped); anywhere else — or on a point that can't be
  // removed — it does what a drag starting there would (so holding still
  // before dragging doesn't lose the drag).
  bool _longPressing = false;

  /// The open point menu, or null.
  _PointMenu? _menu;

  void _onLongPressStart(LongPressStartDetails d, PlayfieldTransform tf) {
    if (_multiTouch) return;
    _longPressing = true;
    final pos = tf.toOsu(d.localPosition);
    final slider = c.editedSlider;
    if (slider != null) {
      final point = c.hitTestControlPoint(pos, PlayfieldView.handleHitRadius / tf.scale);
      final legTolerance = PlayfieldView.legHitRadius / tf.scale;
      final pointMenu = point != null &&
          (c.canDeleteControlPoint || c.canSetPointType(point) || c.canSetCurveType || c.canToggleRedAnchor(point));
      if (point != null ? pointMenu : c.canInsertControlPointAt(pos, tolerance: legTolerance)) {
        if (point != null) c.selectedPoint = point;
        final leg = point == null ? c.controlLegAt(pos, tolerance: legTolerance) : null;
        HapticFeedback.selectionClick();
        setState(
          () => _menu = _PointMenu(
            d.localPosition,
            slider,
            point: point,
            at: pos,
            tolerance: legTolerance,
            preview: leg == null ? null : leg.$2 + c.stackOffsetOf(slider),
            canRemove: point != null && c.canDeleteControlPoint,
            types: point == null ? const [] : c.pointTypeChoices(point),
            type: point == null ? null : c.pointType(point),
            curveTypes: point == null || !c.canSetCurveType ? const [] : c.curveTypeChoices,
            curveType: c.curveTypeState,
            canToggleRed: point != null && c.canToggleRedAnchor(point),
            red: point != null && c.isRedAnchor(point),
          ),
        );
        return;
      }
    }
    _onPanStart(d.localPosition, null, tf);
  }

  void _closeMenu() {
    if (_menu != null) setState(() => _menu = null);
  }

  /// A curve type button of the menu (lazer's "Curve type"), same staleness
  /// rule as [_applyMenu].
  void _applyType(PathType? type) {
    final m = _menu;
    _closeMenu();
    final point = m?.point;
    if (m == null || point == null || !identical(c.editedSlider, m.slider)) return;
    c.setPointType(point, type);
  }

  /// The stable menu's curve type buttons (the whole slider).
  void _applyCurveType(CurveType type) {
    final m = _menu;
    _closeMenu();
    if (m == null || !identical(c.editedSlider, m.slider)) return;
    c.setCurveType(type);
  }

  /// The stable menu's "Red anchor" toggle.
  void _applyRedAnchor() {
    final m = _menu;
    _closeMenu();
    final point = m?.point;
    if (m == null || point == null || !identical(c.editedSlider, m.slider)) return;
    c.toggleRedAnchor(point);
  }

  /// The menu's button: applies the edit if the slider is still the one the
  /// menu was opened on (an undo meanwhile makes it stale).
  void _applyMenu() {
    final m = _menu;
    _closeMenu();
    if (m == null || !identical(c.editedSlider, m.slider)) return;
    final point = m.point;
    if (point != null) {
      c.deleteControlPoint(point);
    } else {
      c.insertControlPointAt(m.at, tolerance: m.tolerance);
    }
  }

  void _onLongPressEnd() {
    _longPressing = false;
    _onPanEnd();
  }

  /// Placement tools keep their tap-and-hold behaviour (no long-press). A
  /// long-press under way keeps its callbacks even if the tool changes.
  bool get _longPressable => c.tool == EditorTool.select || _longPressing;

  /// A freehand stroke (a Slider tool drag) is under way.
  bool _freehand = false;

  void _onPanStart(Offset local, PointerDeviceKind? kind, PlayfieldTransform tf) {
    // Slider tool: only a short in-place tap places the start point; a drag
    // draws the slider along the finger (unless a slider is being built).
    if (c.tool == EditorTool.slider && !c.isDrafting) {
      _freehand = true;
      c.beginFreehand(tf.toOsu(local));
      return;
    }
    if (c.tool == EditorTool.circle || c.tool == EditorTool.slider) {
      _moveCursor(local, tf);
      return;
    }
    if (c.tool != EditorTool.select) return;
    final pos = tf.toOsu(local);
    final point = c.hitTestControlPoint(pos, PlayfieldView.handleHitRadius / tf.scale);
    if (point != null) {
      c.pause();
      _draggingPoint = true;
      c.beginPointDrag(point);
      return;
    }
    if (_startBoxDrag(local, tf)) return;
    final hit = c.hitTest(pos, c.time.value);
    if (hit == null) {
      _boxing = true;
      c.beginBoxSelect(pos, additive: _additiveModifier);
      return;
    }
    if (!c.selection.contains(hit)) c.select(hit, additive: _additiveModifier);
    c.pause();
    _dragStart = pos;
    c.beginMoveSelection();
  }

  void _moveCursor(Offset finger, PlayfieldTransform tf) {
    setState(() => _cursor = finger);
    c.placementCursor = tf.toOsu(finger);
  }

  void _onPanUpdate(Offset local, PlayfieldTransform tf) {
    if (_freehand) {
      c.updateFreehand(tf.toOsu(local));
      return;
    }
    if (_cursor != null) {
      _moveCursor(local, tf);
      return;
    }
    final pos = tf.toOsu(local);
    if (_boxDrag != null) return _updateBoxDrag(local, tf);
    if (_draggingPoint) {
      c.updatePointDrag(pos);
      return;
    }
    if (_boxing) {
      c.updateBoxSelect(pos);
      return;
    }
    final start = _dragStart;
    if (start == null) return;
    c.updateMoveSelection(pos - start);
  }

  void _onPanEnd() {
    if (_freehand) {
      _freehand = false;
      // A second finger joined: it was a pinch, not a stroke.
      if (_multiTouch) {
        c.cancelFreehand();
      } else {
        c.endFreehand();
      }
      return;
    }
    if (_cursor != null) {
      final at = c.placementCursor;
      setState(() => _cursor = null);
      c.placementCursor = null;
      if (at == null || _multiTouch) return;
      if (c.tool == EditorTool.circle) {
        c.placeCircle(at);
      } else if (c.tool == EditorTool.slider) {
        c.sliderToolTap(at, tolerance: 0);
      }
      return;
    }
    if (_boxDrag != null) {
      _boxDrag = null;
      c.endTransform(apply: true);
      return;
    }
    if (_draggingPoint) {
      _draggingPoint = false;
      c.endPointDrag();
      return;
    }
    if (_boxing) {
      _boxing = false;
      c.endBoxSelect();
      return;
    }
    if (_dragStart == null) return;
    _dragStart = null;
    c.endMoveSelection();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = _size = constraints.biggest;
        // Rebuilt when the tool changes (long-press is only wanted with the
        // Select tool); the canvas itself is never rebuilt.
        final gestures = ListenableBuilder(
          listenable: c,
          builder: (context, canvas) {
            final longPress = _longPressable;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              // Hit-test and anchor drags where the finger went down, not where
              // the touch slop was exceeded (boxes and moves would start off).
              dragStartBehavior: DragStartBehavior.down,
              // Zoom changes without a rebuild: read the transform per event.
              onTapUp: (d) => _onTapUp(d, _tf),
              onScaleStart: (d) => _onScaleStart(d, _tf),
              onScaleUpdate: (d) => _onScaleUpdate(d, _tf),
              onScaleEnd: (_) => _onScaleEnd(),
              onLongPressStart: longPress ? (d) => _onLongPressStart(d, _tf) : null,
              onLongPressMoveUpdate: longPress ? (d) => _onPanUpdate(d.localPosition, _tf) : null,
              onLongPressEnd: longPress ? (_) => _onLongPressEnd() : null,
              child: canvas,
            );
          },
          child: RepaintBoundary(
            child: CustomPaint(painter: PlayfieldPainter(c), size: Size.infinite),
          ),
        );
        return Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: (e) => _onPointerUp(e, cancelled: true),
          onPointerSignal: _onPointerSignal,
          child: Stack(
            children: [
              Positioned.fill(child: gestures),
              ListenableBuilder(
                listenable: Listenable.merge([c, c.playfieldZoom]),
                builder: (context, _) => _aspectLock(size) ?? const SizedBox.shrink(),
              ),
              if (_menu != null) ...[
                // Any touch outside the menu closes it (and does nothing else).
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (_) => _closeMenu(),
                    onScaleStart: (_) => _closeMenu(),
                  ),
                ),
                if (_menu!.preview != null) _previewPoint(_menu!.preview!),
                _pointMenu(_menu!, size),
              ],
              Positioned(
                top: 6,
                left: 0,
                right: 0,
                child: Center(child: _ZoomPill(controller: c)),
              ),
            ],
          ),
        );
      },
    );
  }

  PlayfieldTransform get _tf => PlayfieldTransform.fit(_size, c.playfieldZoom.value);

  /// Size of the selection box's aspect lock button.
  static const aspectLockSize = 30.0;

  /// The selection box's aspect lock: beside its rotation handle (the
  /// other side when that runs off the view), toggling
  /// `EditorController.scaleLocksAspect` (shared with the Scale panel).
  /// Null without a box.
  Widget? _aspectLock(Size area) {
    final g = _boxOnScreen(_tf);
    if (g == null) return null;
    final (_, handle) = g;
    const size = aspectLockSize, gap = 40.0; // clear of the handle's reach
    var x = handle.dx + gap;
    if (x + size / 2 > area.width - 4) x = handle.dx - gap;
    final locked = c.scaleLocksAspect;
    return Positioned(
      left: x - size / 2,
      top: handle.dy - size / 2,
      width: size,
      height: size,
      child: Tooltip(
        message: locked ? 'Unlock width / height' : 'Lock width / height',
        child: Material(
          color: locked ? const Color(0xFFFFFFFF) : const Color(0xCC000000),
          shape: const CircleBorder(side: BorderSide(color: Color(0xFF000000), width: 1.5)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () {
              c.scaleLocksAspect = !locked;
              ScaffoldMessenger.maybeOf(context)
                ?..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(
                  content: Text(locked ? 'Aspect ratio unlocked: width and height scale separately' : 'Aspect ratio locked'),
                  behavior: SnackBarBehavior.floating,
                  width: 300,
                  duration: const Duration(seconds: 2),
                ));
            },
            child: Icon(locked ? Icons.link : Icons.link_off,
                size: 18, color: locked ? const Color(0xFF000000) : const Color(0xFFFFFFFF)),
          ),
        ),
      ),
    );
  }

  static const _menuSize = Size(148, 44);

  /// Where "Add point" will put the new point: a see-through handle (the
  /// same 12 dp square as the real ones, see `PlayfieldPainter`).
  Widget _previewPoint(Vec2 at) {
    const size = 14.0;
    final p = _tf.toScreen(at);
    return Positioned(
      left: p.dx - size / 2,
      top: p.dy - size / 2,
      width: size,
      height: size,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0x80FFFFFF),
            border: Border.all(color: const Color(0x99000000), width: 1.5),
          ),
        ),
      ),
    );
  }

  /// The Add / Remove point button, above the finger (clear of it), kept
  /// inside the playfield area. With curve types (lazer's slider format) it
  /// is a panel: a row of type buttons, plus Remove point.
  Widget _pointMenu(_PointMenu m, Size area) {
    if (m.types.isNotEmpty || m.curveTypes.isNotEmpty || m.canToggleRed) return _typeMenu(m, area);
    final w = _menuSize.width, h = _menuSize.height;
    const gap = 40.0;
    var top = m.anchor.dy - gap - h;
    if (top < 4) top = m.anchor.dy + gap;
    final left = (m.anchor.dx - w / 2).clamp(4.0, math.max(4.0, area.width - w - 4)).toDouble();
    final remove = m.point != null;
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: left,
      top: top.clamp(4.0, math.max(4.0, area.height - h - 4)).toDouble(),
      width: _menuSize.width,
      height: _menuSize.height,
      child: Material(
        color: scheme.surfaceContainerHighest,
        elevation: 6,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _applyMenu,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    remove ? Icons.remove_circle_outline : Icons.add_circle_outline,
                    size: 20,
                    color: remove ? scheme.error : scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(remove ? 'Remove point' : 'Add point'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The control point menu, above the finger like [_pointMenu]: a row of
  /// "Curve type" buttons (the current one highlighted) — lazer's per point
  /// types, or for stable-format sliders the whole slider's type — then
  /// the stable Red anchor toggle and Remove point.
  Widget _typeMenu(_PointMenu m, Size area) {
    final scheme = Theme.of(context).colorScheme;
    const buttonHeight = 34.0, pad = 6.0;
    final typeCount = m.types.isNotEmpty ? m.types.length : m.curveTypes.length;
    final hasActions = m.canRemove || m.canToggleRed;
    final rows = (typeCount > 0 ? 1 : 0) + (hasActions ? 1 : 0);
    final h = pad * 2 + buttonHeight * rows + (rows - 1) * pad;
    final actionsWidth = m.canRemove && m.canToggleRed ? 320.0 : 180.0;
    final w = math.min(area.width - 8, math.max(64.0 * typeCount, hasActions ? actionsWidth : 0) + pad * 2);
    const gap = 40.0;
    var top = m.anchor.dy - gap - h;
    if (top < 4) top = m.anchor.dy + gap;
    final left = (m.anchor.dx - w / 2).clamp(4.0, math.max(4.0, area.width - w - 4)).toDouble();
    Widget typeButton(String label, Color edge, bool current, VoidCallback onTap) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Material(
            color: current ? scheme.primaryContainer : scheme.surfaceContainerHigh,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: edge, width: 2),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: current ? _closeMenu : onTap,
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: current ? FontWeight.bold : FontWeight.normal,
                        color: current ? scheme.onPrimaryContainer : scheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget action(IconData icon, Color iconColour, String label, VoidCallback onTap, {bool on = false}) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Material(
              color: on ? scheme.errorContainer : scheme.surfaceContainerHigh,
              shape: const StadiumBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 18, color: iconColour),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(label, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

    final typeRow = m.types.isNotEmpty
        ? [
            for (final t in m.types)
              typeButton(_typeName(t), PlayfieldPainter.pointTypeColour(t), t == m.type, () => _applyType(t)),
          ]
        : [
            for (final t in m.curveTypes)
              typeButton(_curveName(t), PlayfieldPainter.pointTypeColour(PathType(t)), t == m.curveType,
                  () => _applyCurveType(t)),
          ];

    return Positioned(
      left: left,
      top: top.clamp(4.0, math.max(4.0, area.height - h - 4)).toDouble(),
      width: w,
      height: h,
      child: Material(
        color: scheme.surfaceContainerHighest,
        elevation: 6,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(pad),
          child: Column(
            children: [
              if (typeCount > 0) SizedBox(height: buttonHeight, child: Row(children: typeRow)),
              if (typeCount > 0 && hasActions) const SizedBox(height: pad),
              if (hasActions)
                SizedBox(
                  height: buttonHeight,
                  child: Row(
                    children: [
                      if (m.canToggleRed)
                        action(Icons.circle, const Color(0xFFFF4040), m.red ? 'Unset red anchor' : 'Red anchor',
                            _applyRedAnchor),
                      if (m.canRemove)
                        action(Icons.remove_circle_outline, scheme.error, 'Remove point', _applyMenu),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Short names for the curve type buttons.
String _typeName(PathType? t) => switch (t) {
      null => 'Inherit',
      PathType(kind: CurveType.perfectCircle) => 'Perfect',
      _ => t.label,
    };

/// Names for the stable menu's curve type buttons.
String _curveName(CurveType t) => switch (t) {
      CurveType.bezier => 'Bezier',
      CurveType.perfectCircle => 'Perfect',
      CurveType.catmull => 'Catmull',
      CurveType.linear => 'Linear',
    };

/// A two-finger transform of the selection box (see `_twoFinger`).
class _TwoFinger {
  final Vec2 centre, focal;
  final double box, objects, scale0;

  /// Aspect unlocked: stretch the axes separately, without turning.
  final bool free;

  /// The box's and the objects' width / height at the start.
  final Vec2 size, objectSize;

  /// The gesture's horizontal / vertical scale at the start, or null when
  /// the fingers were too close along that axis to stretch it.
  final double? horizontal0, vertical0;

  const _TwoFinger({
    required this.centre,
    required this.focal,
    required this.box,
    required this.objects,
    required this.scale0,
    required this.free,
    required this.size,
    required this.objectSize,
    required this.horizontal0,
    required this.vertical0,
  });
}

/// A one-finger drag of a selection box handle.
class _BoxDrag {
  /// Rotation handle: around [pivot] (the box centre). Corner: from [pivot]
  /// (the objects' opposite corner), [span] = from it to the objects' dragged
  /// corner, [pad] = from that to the box's corner. Side: the same with the
  /// opposite side, scaling only across ([across] true) or down (false).
  final bool rotating;
  final Vec2 pivot;
  final Vec2 pad, span;
  final bool? across;
  const _BoxDrag.rotate(this.pivot)
      : rotating = true,
        pad = Vec2.zero,
        span = Vec2.zero,
        across = null;
  const _BoxDrag.scale(this.pivot, this.pad, this.span, [this.across]) : rotating = false;
}

/// A long-press menu on [slider]: remove [point], or (null) add one at [at].
class _PointMenu {
  /// Where the finger was (local coordinates); the menu sits above it.
  final Offset anchor;
  final SliderObject slider;
  final int? point;
  final Vec2 at;
  final double tolerance;

  /// Add only: where the new point goes (osu!pixels, as displayed).
  final Vec2? preview;

  /// Point menus: whether the point can be removed, the curve types it can
  /// be given (lazer's slider format; empty otherwise) and its current one.
  final bool canRemove;
  final List<PathType?> types;
  final PathType? type;

  /// Stable-format sliders: the whole slider's curve type choices and
  /// current type, and whether the point can be toggled as a red anchor
  /// (and is one).
  final List<CurveType> curveTypes;
  final CurveType? curveType;
  final bool canToggleRed;
  final bool red;

  const _PointMenu(this.anchor, this.slider,
      {this.point,
      required this.at,
      this.tolerance = 8,
      this.preview,
      this.canRemove = true,
      this.types = const [],
      this.type,
      this.curveTypes = const [],
      this.curveType,
      this.canToggleRed = false,
      this.red = false});
}

/// Shown while zoomed in: the magnification; tapping it resets the zoom.
class _ZoomPill extends StatelessWidget {
  final EditorController controller;
  const _ZoomPill({required this.controller});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PlayfieldZoom>(
      valueListenable: controller.playfieldZoom,
      builder: (context, zoom, _) {
        if (!zoom.isZoomed) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Material(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: Tooltip(
            message: 'Reset zoom',
            child: InkWell(
              onTap: controller.resetPlayfieldZoom,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${zoom.factor.toStringAsFixed(1)}×',
                      style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.zoom_out_map, size: 18, color: scheme.primary),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Shown in a corner while the playfield is zoomed in: the whole playfield
/// at 1x with the zoomed-in part outlined. Tapping or dragging on it moves
/// the zoomed view there.
///
/// Rebuilds only when zooming starts or ends; the preview itself repaints
/// through [PlayfieldPainter] like the main view.
class PlayfieldOverview extends StatefulWidget {
  final EditorController controller;

  /// Size of the main playfield view (for the outline).
  final Size viewport;
  const PlayfieldOverview({super.key, required this.controller, required this.viewport});

  /// Preview size for a main view of [viewport]: a fraction of its width,
  /// with the playfield's fitted aspect ratio.
  static Size sizeFor(Size viewport) {
    const aspect =
        (OsuRules.playfieldWidth + PlayfieldTransform.marginX * 2) /
        (OsuRules.playfieldHeight + PlayfieldTransform.marginY * 2);
    final w = (viewport.width * 0.24).clamp(120.0, 200.0).toDouble();
    return Size(w, w / aspect);
  }

  @override
  State<PlayfieldOverview> createState() => _PlayfieldOverviewState();
}

class _PlayfieldOverviewState extends State<PlayfieldOverview> {
  late bool _zoomed = widget.controller.playfieldZoom.value.isZoomed;

  @override
  void initState() {
    super.initState();
    widget.controller.playfieldZoom.addListener(_onZoom);
  }

  @override
  void didUpdateWidget(PlayfieldOverview old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.playfieldZoom.removeListener(_onZoom);
      widget.controller.playfieldZoom.addListener(_onZoom);
      _onZoom();
    }
  }

  @override
  void dispose() {
    widget.controller.playfieldZoom.removeListener(_onZoom);
    super.dispose();
  }

  void _onZoom() {
    final z = widget.controller.playfieldZoom.value.isZoomed;
    if (z != _zoomed) setState(() => _zoomed = z);
  }

  void _moveTo(Offset local, Size size) {
    final zoom = widget.controller.playfieldZoom;
    final p = PlayfieldTransform.fit(size).toOsu(local);
    zoom.value = PlayfieldZoom.clamped(zoom.value.factor, p);
  }

  @override
  Widget build(BuildContext context) {
    if (!_zoomed || widget.viewport.isEmpty) return const SizedBox.shrink();
    final size = PlayfieldOverview.sizeFor(widget.viewport);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Zoom overview',
      child: SizedBox.fromSize(
        size: size,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(6),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanDown: (d) => _moveTo(d.localPosition, size),
              onPanUpdate: (d) => _moveTo(d.localPosition, size),
              child: ColoredBox(
                color: Colors.black,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: PlayfieldPainter(widget.controller, overview: true, viewport: widget.viewport),
                    size: size,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
