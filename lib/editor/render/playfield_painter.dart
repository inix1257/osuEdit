import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../../app_fonts.dart';
import '../../core/core.dart';
import '../../platform/skin_library.dart';
import '../../platform/storyboard_loader.dart';
import '../editor_controller.dart';
import 'playfield_transform.dart';
import 'storyboard_renderer.dart';

/// Draws the playfield at the controller's current time.
///
/// Performance notes:
/// * repaints are driven by `controller.time` (no widget rebuilds);
/// * only objects from `visibleObjectsAt` are touched (binary search);
/// * slider bodies are built once per immutable `SliderObject` as a `ui.Path` in
///   osu!pixel space and drawn under a canvas transform, so resizing or
///   playback never rebuilds them;
/// * combo-number text layouts are cached per number.
class PlayfieldPainter extends CustomPainter {
  final EditorController controller;

  /// The whole playfield at 1x whatever the pinch zoom (the corner preview
  /// shown while zoomed in), with the part [viewport] (the main view's size)
  /// shows outlined. The storyboard is left out to keep it cheap.
  final bool overview;
  final Size? viewport;

  PlayfieldPainter(this.controller, {this.overview = false, this.viewport})
      : super(repaint: Listenable.merge([controller, controller.time, controller.playfieldZoom]));

  static final Expando<ui.Path> _bodyPaths = Expando();

  static const _selectionColour = Color(0xFFFFA726);

  /// The user's skin for this paint (null: the built-in look). Elements the
  /// skin has are drawn from its images; the others keep the built-in look
  /// (osu! would fall back to its default skin, which can't be bundled).
  LoadedSkin? _skin;

  /// Marks a placement that replaces the object starting at its time.
  static const replaceColour = Color(0xFFFFC107);
  static const _playfieldColour = Color(0xFF1B1D22);
  static const _gridColour = Color(0x14FFFFFF);
  static const _snapGridColour = Color(0x24FFFFFF);


  @override
  void paint(Canvas canvas, Size size) {
    final zoom = overview ? PlayfieldZoom.none : controller.playfieldZoom.value;
    final tf = PlayfieldTransform.fit(size, zoom);
    if (!overview) {
      if (!identical(_bodyImagesOwner, controller)) _clearBodyImages(controller);
      final scale = tf.scale * _devicePixelRatio;
      _bodyScaleSettled = scale == _lastBodyScale;
      _lastBodyScale = scale;
    }
    canvas.save();
    // Control points may lie outside the playfield; don't paint over the panels.
    canvas.clipRect(Offset.zero & size);
    final t = controller.time.value;
    _skin = controller.skin;
    final backdrop = _drawBackdrop(canvas, size, tf, t);
    if (!overview) _drawKiaiFlash(canvas, size, t);
    tf.apply(canvas);

    _drawPlayfield(canvas, zoom.factor, translucent: backdrop);

    final objs = controller.visibleObjectsAt(t);
    final r = controller.circleRadius;
    final preempt = controller.preempt;
    final fadeIn = controller.fadeIn;

    _drawHiddenSelection(canvas, t, r, preempt);
    if (!overview && controller.showFollowPoints) _drawFollowPoints(canvas, t, r);

    // Later objects underneath: draw in reverse time order. How each part
    // fades and scales over time follows lazer's editor (ObjectVisuals).
    for (var i = objs.length - 1; i >= 0; i--) {
      final h = objs[i];
      final end = controller.endTimeOf(h);
      if (!ObjectVisuals.isAlive(t, h.time, end, preempt, spinner: h is Spinner)) continue;
      // The circle being placed takes its place (see _drawPlacementCursor).
      if (controller.isBeingReplaced(h)) continue;
      final colour = controller.shownComboColourOf(h);
      final selected = controller.selection.contains(h);
      final stack = h is Spinner ? Vec2.zero : controller.stackOffsetOf(h);
      final stacked = stack != Vec2.zero;
      if (stacked) {
        canvas.save();
        canvas.translate(stack.x, stack.y);
      }

      switch (h) {
        case Spinner():
          _drawSpinner(canvas, h, t, end, preempt, selected);
        case SliderObject():
          _drawSlider(canvas, h, t, end, r, colour, selected, preempt, fadeIn);
        default:
          _drawHitCircle(canvas, h.position, r, colour, t, h.time, preempt, fadeIn, controller.shownComboOf(h).number);
          if (selected) _drawSelectionRing(canvas, h.position, r);
      }
      if (stacked) canvas.restore();
    }

    // Approach circles (and, after the hit time, lazer's hit marker rings) go
    // in a second pass so they are always above every object.
    for (var i = objs.length - 1; i >= 0; i--) {
      final h = objs[i];
      if (h is Spinner || t > h.time + ObjectVisuals.hitFadeOut || controller.isBeingReplaced(h)) continue;
      final alpha = ObjectVisuals.approachAlpha(t, h.time, preempt, fadeIn, hitAnimations: controller.hitAnimations);
      final markerAlpha = ObjectVisuals.hitMarkerAlpha(t, h.time, hitAnimations: controller.hitAnimations);
      if (alpha <= 0 && markerAlpha <= 0) continue;
      final stack = controller.stackOffsetOf(h);
      final stacked = stack != Vec2.zero;
      if (stacked) {
        canvas.save();
        canvas.translate(stack.x, stack.y);
      }
      final colour = controller.shownComboColourOf(h);
      if (alpha > 0) _drawApproach(canvas, h.position, r, colour, ObjectVisuals.approachScale(t, h.time, preempt), alpha);
      if (markerAlpha > 0) _drawHitMarker(canvas, h.position, r, colour, ObjectVisuals.hitMarkerScale(t, h.time), markerAlpha);
      if (stacked) canvas.restore();
    }

    // Control points of the selected slider, above everything else.
    final edited = controller.editedSlider;
    if (edited != null && objs.any((h) => identical(h, edited))) {
      final stack = controller.stackOffsetOf(edited);
      canvas.save();
      canvas.translate(stack.x, stack.y);
      final edge = controller.selectedEdge;
      if (edge != null) _drawEdgeMarker(canvas, edge.isEven ? edited.position : controller.sliderPath(edited).tail, r);
      _drawControlPoints(canvas, controller.editablePoints(edited), controller.selectedPoint, tf.scale,
          typed: controller.editsTyped(edited));
      canvas.restore();
    }
    _drawDraft(canvas, r, tf.scale);
    _drawDistanceGuide(canvas, t, tf.scale);
    _drawSelectionBox(canvas, tf.scale);
    _drawPlacementCursor(canvas, r, tf.scale);
    if (overview) _drawViewport(canvas, tf.scale);
    canvas.restore();
    if (!overview) _drawSelectionFrame(canvas, size, tf);
  }

  /// The selection box on screen for osu!pixel bounds [min]..[max] and its
  /// rotation handle: above the box's top edge, or below it when there is
  /// no room above (shared with the gestures in `PlayfieldView`).
  static (Rect, Offset) selectionBoxGeometry(Vec2 min, Vec2 max, PlayfieldTransform tf, Size area) {
    final rect = Rect.fromPoints(tf.toScreen(min), tf.toScreen(max));
    const gap = 30.0, edge = 16.0;
    final above = rect.top - gap, below = rect.bottom + gap;
    // Above when there is room, else below, else (a box as tall as the
    // view) kept on screen on the stem: it must stay reachable.
    final y = above >= edge
        ? above
        : below <= area.height - edge
            ? below
            : edge + gap;
    final x = rect.center.dx.clamp(edge, math.max(edge, area.width - edge)).toDouble();
    return (rect, Offset(x, y));
  }

  /// A side of the selection box shorter than this on screen (logical
  /// pixels) has no handle in its middle (it would crowd the corners').
  static const edgeHandleMinSide = 48.0;

  /// The handles in the middle of the selection box's sides (scale one
  /// axis, the opposite side staying put): where each is and whether it
  /// scales across (left / right side) rather than down. Only on sides at
  /// least [edgeHandleMinSide] long, and only for an axis the objects
  /// spread along (the box minus its [padding] on each side, screen pixels).
  static List<(Offset, bool)> selectionEdgeHandles(Rect rect, {double padding = 0}) => [
        if (rect.height >= edgeHandleMinSide && rect.width - 2 * padding > 1)
          ...[(rect.centerLeft, true), (rect.centerRight, true)],
        if (rect.width >= edgeHandleMinSide && rect.height - 2 * padding > 1)
          ...[(rect.topCenter, false), (rect.bottomCenter, false)],
      ];

  static TextPainter? _readout;
  static String? _readoutText;

  /// lazer's selection box: an outline around the selected objects,
  /// square corner handles (scale), side handles (scale one axis) and a
  /// round rotation handle, plus the
  /// angle / scale while transforming. Screen space (constant size).
  void _drawSelectionFrame(Canvas canvas, Size size, PlayfieldTransform tf) {
    final b = controller.selectionBounds;
    if (b == null) return;
    final (rect, handle) = selectionBoxGeometry(b.$1, b.$2, tf, size);
    canvas.save();
    canvas.clipRect(Offset.zero & size); // not over the timeline / bars
    _drawFrame(canvas, rect, handle, selectionEdgeHandles(rect, padding: controller.circleRadius * tf.scale));
    canvas.restore();
  }

  void _drawFrame(Canvas canvas, Rect rect, Offset handle, List<(Offset, bool)> edges) {
    final dark = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = const Color(0x99000000);
    final light = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0xE6FFFFFF);
    canvas.drawRect(rect, dark);
    canvas.drawRect(rect, light);
    // Stem to the rotation handle.
    final stemFrom = Offset(handle.dx, handle.dy <= rect.center.dy ? rect.top : rect.bottom);
    canvas.drawLine(stemFrom, handle, dark);
    canvas.drawLine(stemFrom, handle, light);
    final fill = Paint()..color = const Color(0xFFFFFFFF);
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0xFF000000);
    for (final p in [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft]) {
      final sq = Rect.fromCenter(center: p, width: 11, height: 11);
      canvas.drawRect(sq, fill);
      canvas.drawRect(sq, rim);
    }
    // Side handles: small bars along their side.
    for (final (p, across) in edges) {
      final bar = RRect.fromRectAndRadius(
          Rect.fromCenter(center: p, width: across ? 7 : 15, height: across ? 15 : 7), const Radius.circular(2));
      canvas.drawRRect(bar, fill);
      canvas.drawRRect(bar, rim);
    }
    canvas.drawCircle(handle, 9, fill);
    canvas.drawCircle(handle, 9, rim);
    // A small circular arrow inside the rotation handle.
    final arrow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = const Color(0xFF000000);
    canvas.drawArc(Rect.fromCircle(center: handle, radius: 4.5), -math.pi * 0.9, math.pi * 1.4, false, arrow);
    final tip = handle + Offset(4.5 * math.cos(math.pi * 0.5), 4.5 * math.sin(math.pi * 0.5));
    canvas.drawLine(tip, tip + const Offset(-3, -1), arrow);

    final shown = controller.freeTransformShown;
    if (shown == null) return;
    final (deg, sx, sy) = shown;
    // Signed: clockwise positive, counter-clockwise negative. Width ×
    // height when they differ.
    final pct = (sx * 100).round() == (sy * 100).round()
        ? '${(sx * 100).round()}%'
        : '${(sx * 100).round()}% × ${(sy * 100).round()}%';
    final text = '${deg.round()}° · $pct';
    if (text != _readoutText) {
      _readoutText = text;
      _readout = TextPainter(
        text: TextSpan(text: text, style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 13, fontFamily: kUiFont, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
    }
    final tp = _readout!;
    final y = handle.dy < rect.top ? handle.dy - 18 - tp.height : handle.dy + 18;
    final pill = Rect.fromCenter(
        center: Offset(rect.center.dx, y + tp.height / 2), width: tp.width + 16, height: tp.height + 8);
    canvas.drawRRect(RRect.fromRectAndRadius(pill, const Radius.circular(10)), Paint()..color = const Color(0xCC000000));
    tp.paint(canvas, Offset(pill.left + 8, pill.top + 4));
  }

  /// Overview: the part of the playfield the zoomed-in main view shows.
  void _drawViewport(Canvas canvas, double scale) {
    final area = viewport;
    if (area == null || area.isEmpty) return;
    final main = PlayfieldTransform.fit(area, controller.playfieldZoom.value);
    final a = main.toOsu(Offset.zero), b = main.toOsu(Offset(area.width, area.height));
    final rect = Rect.fromLTRB(a.x, a.y, b.x, b.y);
    canvas.drawRect(rect, Paint()..color = const Color(0x1FFFFFFF));
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 / scale
        ..color = const Color(0xFFFFFFFF),
    );
  }

  /// Precision placement: a ghost where the object would go, and a
  /// crosshair at the cursor itself.
  void _drawPlacementCursor(Canvas canvas, double r, double scale) {
    final cursor = controller.placementCursor;
    final at = controller.placementPreview;
    if (cursor == null || at == null) return;
    final c = Offset(at.x, at.y);
    final ghost = controller.placementGhostCombo;
    if (ghost != null) {
      // The circle to be placed, as it will look: its combo colour and
      // number (the others already show theirs as they would become).
      _drawCircle(canvas, at, r, controller.comboColourAt(ghost.colourIndex), 0.6, ghost.number);
      if (controller.placementCollides) {
        // It replaces the object starting at this time (hidden meanwhile).
        canvas.drawCircle(
          c,
          r + 5 / scale,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3 / scale
            ..color = PlayfieldPainter.replaceColour,
        );
      }
    } else {
      // A slider point being placed.
      const colour = Color(0xFF66CCFF);
      canvas.drawCircle(c, r, Paint()..color = colour.withValues(alpha: 0.3));
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 / scale
          ..color = colour,
      );
    }
    final arm = 10 / scale;
    final p = Offset(cursor.x, cursor.y);
    final line = Paint()
      ..strokeWidth = 1.5 / scale
      ..color = const Color(0xFFFFFFFF);
    canvas.drawLine(p - Offset(arm, 0), p + Offset(arm, 0), line);
    canvas.drawLine(p - Offset(0, arm), p + Offset(0, arm), line);
  }

  /// The box being dragged with the Select tool.
  void _drawSelectionBox(Canvas canvas, double scale) {
    final box = controller.selectionBox;
    if (box == null) return;
    final (a, b) = box;
    final rect = Rect.fromPoints(Offset(a.x, a.y), Offset(b.x, b.y));
    canvas.drawRect(rect, Paint()..color = _selectionColour.withValues(alpha: 0.12));
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 / scale
        ..color = _selectionColour,
    );
  }

  /// Distance snap ring around the previous object while placing.
  /// (Or around the object before the selection while dragging it.)
  void _drawDistanceGuide(Canvas canvas, double t, double scale) {
    final tool = controller.tool;
    final placing = tool == EditorTool.circle || (tool == EditorTool.slider && !controller.isDrafting);
    final guide = controller.moveSnapGuide ??
        (placing ? controller.distanceSnapGuide(controller.timing.snap(t, controller.divisor)) : null);
    if (guide == null) return;
    final (c, radius) = guide;
    if (radius <= 0) return;
    canvas.drawCircle(
      Offset(c.x, c.y),
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 / scale
        ..color = const Color(0x99FFFFFF),
    );
  }

  static const _kiaiFlashMs = 700.0;

  /// A soft glow from the left and right edges that fades out after kiai
  /// starts (only while playing, so a paused frame never holds it).
  void _drawKiaiFlash(Canvas canvas, Size size, double t) {
    if (!controller.isPlaying) return;
    final start = controller.timing.lastKiaiStartAt(t);
    if (start == null) return;
    final p = (t - start) / _kiaiFlashMs;
    if (p >= 1) return;
    final a = 0.35 * (1 - p) * (1 - p); // ease-out
    final w = size.width * 0.2;
    final glow = Color.fromRGBO(255, 255, 255, a);
    const clear = Color(0x00FFFFFF);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, size.height),
      Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(w, 0), [glow, clear]),
    );
    canvas.drawRect(
      Rect.fromLTWH(size.width - w, 0, w, size.height),
      Paint()..shader = ui.Gradient.linear(Offset(size.width, 0), Offset(size.width - w, 0), [glow, clear]),
    );
  }

  /// Background image and storyboard under a black layer of the dim
  /// opacity. False if there is neither (the playfield is then opaque).
  bool _drawBackdrop(Canvas canvas, Size size, PlayfieldTransform tf, double t) {
    final sb = controller.storyboard;
    final bg = controller.background;
    if (bg == null && sb == null) return false;
    final dim = controller.backgroundDimAt(t);
    if (dim < 1) {
      if (bg != null && !controller.storyboardReplacesBackground) _drawBackground(canvas, size, bg);
      if (sb != null && !overview) {
        // The map's current setting (Song setup can change it while open).
        _drawStoryboard(canvas, size, tf, sb, t + controller.storyboardLeadMs,
            widescreen: Storyboard.isWidescreen(controller.beatmap));
      }
    }
    if (dim > 0) canvas.drawRect(Offset.zero & size, Paint()..color = Color.fromRGBO(0, 0, 0, dim));
    return true;
  }

  /// The background image scaled to cover the whole area (centred, like
  /// osu!).
  static void _drawBackground(Canvas canvas, Size size, ui.Image img) {
    final iw = img.width.toDouble(), ih = img.height.toDouble();
    final s = math.max(size.width / iw, size.height / ih);
    final w = iw * s, h = ih * s;
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, iw, ih),
      Rect.fromLTWH((size.width - w) / 2, (size.height - h) / 2, w, h),
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  /// Storyboard pixel (0,0) in osu!pixels: the 512x384 playfield sits at
  /// (64, 56) in the 640x480 storyboard area.
  static const storyboardOffset = Offset(-64, -56);

  /// Pass state: the Fail layer is never drawn. All layers (Overlay too)
  /// stay under the hit objects so they never hide what is being edited.
  static void _drawStoryboard(Canvas canvas, Size size, PlayfieldTransform tf, LoadedStoryboard sb, double t,
      {required bool widescreen}) {
    canvas.save();
    tf.apply(canvas);
    canvas.translate(storyboardOffset.dx, storyboardOffset.dy);
    // Masked to the 4:3 area unless the map opts into widescreen.
    final area = widescreen ? const Rect.fromLTRB(-107, 0, 747, 480) : const Rect.fromLTRB(0, 0, 640, 480);
    canvas.clipRect(area);
    // The widget's area in storyboard pixels (less than [area] when zoomed).
    final shown = Rect.fromLTRB(
      -tf.origin.dx / tf.scale - storyboardOffset.dx,
      -tf.origin.dy / tf.scale - storyboardOffset.dy,
      (size.width - tf.origin.dx) / tf.scale - storyboardOffset.dx,
      (size.height - tf.origin.dy) / tf.scale - storyboardOffset.dy,
    );
    StoryboardRenderer.draw(canvas, sb, t, area.intersect(shown));
    canvas.restore();
  }

  void _drawPlayfield(Canvas canvas, double zoom, {bool translucent = false}) {
    const rect = Rect.fromLTWH(0, 0, OsuRules.playfieldWidth, OsuRules.playfieldHeight);
    // Over a background the playfield is only tinted, so the image shows.
    canvas.drawRect(rect, Paint()..color = translucent ? _playfieldColour.withValues(alpha: 0.35) : _playfieldColour);
    final snapping = controller.gridSnap;
    final grid = Paint()
      ..color = snapping ? _snapGridColour : _gridColour
      // Same on-screen width when zoomed in.
      ..strokeWidth = 1 / zoom;
    final step = snapping ? controller.gridSize.toDouble() : 32.0;
    for (var x = step; x < OsuRules.playfieldWidth; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, OsuRules.playfieldHeight), grid);
    }
    for (var y = step; y < OsuRules.playfieldHeight; y += step) {
      canvas.drawLine(Offset(0, y), Offset(OsuRules.playfieldWidth, y), grid);
    }
  }

  /// A hit circle or slider head at [time] (lazer editor, classic skin):
  /// dimmed until close to its time; after it either white and fading out
  /// (hit markers) or the hit animation (grows to 1.4x while fading, the
  /// number goes first) — [ObjectVisuals].
  void _drawHitCircle(Canvas canvas, Vec2 p, double r, Color colour, double t, double time, double preempt,
      double fadeIn, int number, {double parentAlpha = 1, String element = 'hitcircle'}) {
    final anim = controller.hitAnimations;
    final alpha = ObjectVisuals.circleAlpha(t, time, preempt, fadeIn, hitAnimations: anim) * parentAlpha;
    if (alpha <= 0) return;
    final hit = t >= time;
    _drawCircle(canvas, p, r, colour, alpha, number,
        brightness: hit ? 1 : ObjectVisuals.brightness(t, time),
        white: ObjectVisuals.shownWhite(t, time, hitAnimations: anim),
        scale: ObjectVisuals.circleScale(t, time, hitAnimations: anim),
        numberAlpha: ObjectVisuals.numberAlpha(t, time, preempt, fadeIn, hitAnimations: anim) * parentAlpha,
        element: element);
  }

  /// The classic skin's circle: `hitcircle` tinted with [colour] (white
  /// once hit with hit markers: lazer turns the accent colour white) under
  /// the white `hitcircleoverlay` ring, and the number (white with a dark
  /// edge, like the default `default-n` digits; none when [number] is
  /// null). [brightness] multiplies every colour (lazer's dim before an
  /// object is close); [scale] grows it (hit animation).
  void _drawCircle(Canvas canvas, Vec2 p, double r, Color colour, double alpha, int? number,
          {double brightness = 1,
          bool white = false,
          double scale = 1,
          double? numberAlpha,
          String element = 'hitcircle'}) =>
      paintCircle(canvas, _skin, Offset(p.x, p.y), r, colour, alpha, number,
          brightness: brightness, white: white, scale: scale, numberAlpha: numberAlpha, element: element);

  /// [_drawCircle] for other painters (the timeline draws the same circles):
  /// centred on [c] with radius [r] in the canvas' units, from [skin] when
  /// given.
  static void paintCircle(Canvas canvas, LoadedSkin? skin, Offset c, double r, Color colour, double alpha, int? number,
      {double brightness = 1, bool white = false, double scale = 1, double? numberAlpha, String element = 'hitcircle'}) {
    final rr = r * scale;
    final tint = white ? _white : colour;
    if (skin != null && skin['hitcircle'] != null) {
      _drawSkinCircle(canvas, skin, c, r, scale, tint, alpha, brightness, number, numberAlpha ?? alpha, element);
      return;
    }
    final ring = Paint()..style = PaintingStyle.stroke;

    // A soft shadow just outside the circle.
    canvas.drawCircle(c, rr * 1.015, ring
      ..strokeWidth = rr * 0.06
      ..color = Color.fromRGBO(0, 0, 0, 0.22 * alpha));

    // The tinted disc: lit from slightly above, shading off toward the rim.
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.scale(rr);
    canvas.drawCircle(Offset.zero, 0.98, Paint()..shader = _discShader(tint, brightness, alpha));
    canvas.restore();

    // The white overlay ring, with thin dark edges on both sides for depth.
    canvas.drawCircle(c, rr * 0.92, ring
      ..strokeWidth = rr * 0.13
      ..color = _shade(_white, brightness, alpha));
    canvas.drawCircle(c, rr * 0.99, ring
      ..strokeWidth = rr * 0.025
      ..color = Color.fromRGBO(0, 0, 0, 0.45 * alpha));
    canvas.drawCircle(c, rr * 0.85, ring
      ..strokeWidth = rr * 0.02
      ..color = Color.fromRGBO(0, 0, 0, 0.3 * alpha));
    if (number == null) return;
    final na = numberAlpha ?? alpha;
    if (na <= 0) return;
    _BuiltinDigits.instance.paint(canvas, number, c, r, _imagePaint(na, brightness: brightness));
  }

  static const _white = Color(0xFFFFFFFF);

  /// The circle disc's radial gradient for a unit circle at the origin,
  /// cached per tint, brightness and alpha (both in 1/32 steps): a new
  /// gradient per circle per frame is a native object each, and thousands
  /// of them freed together in one GC stalled a frame on the phone.
  static final _discShaders = <(int, int, int), Shader>{};

  static Shader _discShader(Color tint, double brightness, double alpha) {
    final b = (brightness.clamp(0.0, 1.0) * 32).round(), a = (alpha.clamp(0.0, 1.0) * 32).round();
    final key = (tint.toARGB32(), b, a);
    final cached = _discShaders[key];
    if (cached != null) return cached;
    if (_discShaders.length >= 1024) _discShaders.clear();
    final bf = b / 32, af = a / 32 * 0.92;
    return _discShaders[key] = ui.Gradient.radial(
      const Offset(0, -0.25),
      1.25,
      [
        _shade(_lighten(tint, 0.45), bf, af),
        _shade(tint, bf, af),
        _shade(_darken(tint, 0.35), bf, af),
      ],
      const [0, 0.55, 1],
    );
  }

  /// Skin pixels -> osu!pixels for hit objects: a standard-definition
  /// texture of 128 px is one object diameter (lazer `OBJECT_RADIUS` = 64)
  /// at circle size scale 1.
  static double _objectScale(double r) => r / 64;

  /// A paint drawing an image at [alpha], multiplied by [tint] (with
  /// [brightness]); no colour filter when that is plain white.
  static Paint _imagePaint(double alpha, {Color tint = _white, double brightness = 1}) {
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..color = Color.fromRGBO(0, 0, 0, alpha.clamp(0.0, 1.0));
    final c = _shade(tint, brightness, 1);
    if (c != _white) paint.colorFilter = ColorFilter.mode(c, BlendMode.modulate);
    return paint;
  }

  /// Draws [tex] centred on [c], [k] osu!px per skin pixel, shrunk to fit
  /// [maxSize] skin pixels first (lazer's `WithMaximumSize`), rotated by
  /// [rotation] radians.
  static void _drawTexture(Canvas canvas, SkinTexture tex, Offset c, double k, Paint paint,
      {Size maxSize = const Size(256, 256), double rotation = 0}) {
    var w = tex.width, h = tex.height;
    if (w <= 0 || h <= 0 || k <= 0) return;
    final fit = math.min(1.0, math.min(maxSize.width / w, maxSize.height / h));
    w *= fit * k;
    h *= fit * k;
    final src = Rect.fromLTWH(0, 0, tex.image.width.toDouble(), tex.image.height.toDouble());
    if (rotation == 0) {
      canvas.drawImageRect(tex.image, src, Rect.fromCenter(center: c, width: w, height: h), paint);
      return;
    }
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(rotation);
    canvas.drawImageRect(tex.image, src, Rect.fromCenter(center: Offset.zero, width: w, height: h), paint);
    canvas.restore();
  }

  /// lazer `LegacyMainCirclePiece`: the [element] texture (`hitcircle`,
  /// `sliderstartcircle`, `sliderendcircle`; `hitcircle` if the skin lacks
  /// it) tinted with [tint], its `...overlay` untinted, both grown by
  /// [scale]; the number from the skin's digits (0.8x, `HitCircleOverlap`),
  /// above or under the overlay per `HitCircleOverlayAboveNumber`.
  static void _drawSkinCircle(Canvas canvas, LoadedSkin skin, Offset c, double r, double scale, Color tint, double alpha,
      double brightness, int? number, double numberAlpha, String element) {
    final name = skin[element] != null ? element : 'hitcircle';
    final k = _objectScale(r);
    _drawTexture(canvas, skin[name]!, c, k * scale, _imagePaint(alpha, tint: tint, brightness: brightness));
    final overlay = skin['${name}overlay'];
    void drawOverlay() {
      if (overlay != null) _drawTexture(canvas, overlay, c, k * scale, _imagePaint(alpha, brightness: brightness));
    }

    final above = skin.ini.hitCircleOverlayAboveNumber;
    if (!above) drawOverlay();
    if (number != null && numberAlpha > 0) {
      final digits = skin.digits;
      if (digits == null) {
        _BuiltinDigits.instance.paint(canvas, number, c, r, _imagePaint(numberAlpha, brightness: brightness));
      } else {
        _drawSkinNumber(canvas, skin, digits, number, c, k, _imagePaint(numberAlpha, brightness: brightness));
      }
    }
    if (above) drawOverlay();
  }

  /// The combo number in the skin's hit circle font: stable's blanket 0.8x
  /// scale, digits `-HitCircleOverlap` skin pixels apart.
  static void _drawSkinNumber(
      Canvas canvas, LoadedSkin skin, List<SkinTexture> digits, int number, Offset c, double k, Paint paint) {
    const textScale = 0.8, maxGlyph = 256 / textScale;
    final glyphs = [for (final ch in '$number'.codeUnits) digits[ch - 48]];
    double fit(SkinTexture g) => math.min(1.0, math.min(maxGlyph / g.width, maxGlyph / g.height));
    final spacing = -skin.ini.hitCircleOverlap;
    var width = spacing * (glyphs.length - 1);
    for (final g in glyphs) {
      width += g.width * fit(g);
    }
    final s = k * textScale;
    var x = c.dx - width * s / 2;
    for (final g in glyphs) {
      final w = g.width * fit(g);
      _drawTexture(canvas, g, Offset(x + w * s / 2, c.dy), s, paint, maxSize: const Size(maxGlyph, maxGlyph));
      x += (w + spacing) * s;
    }
  }

  /// [c] multiplied by [brightness], with opacity [alpha].
  static Color _shade(Color c, double brightness, double alpha) => brightness == 1
      ? c.withValues(alpha: alpha)
      : Color.from(alpha: alpha, red: c.r * brightness, green: c.g * brightness, blue: c.b * brightness);

  void _drawApproach(Canvas canvas, Vec2 p, double r, Color colour, double scale, double alpha) {
    final tex = _skin?['approachcircle'];
    if (tex != null) {
      _drawTexture(canvas, tex, Offset(p.x, p.y), _objectScale(r) * scale, _imagePaint(alpha, tint: colour));
      return;
    }
    canvas.drawCircle(
      Offset(p.x, p.y),
      r * scale,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = colour.withValues(alpha: alpha),
    );
  }

  /// lazer's editor hit marker (`HitCircleOverlapMarker`): a plain ring the
  /// size of the circle, its border inside the edge; not skinned.
  void _drawHitMarker(Canvas canvas, Vec2 p, double r, Color colour, double scale, double alpha) {
    final outer = r * scale;
    final width = outer * ObjectVisuals.hitMarkerThickness;
    canvas.drawCircle(
      Offset(p.x, p.y),
      outer - width / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = colour.withValues(alpha: alpha),
    );
  }

  /// Orange outlines of selected objects that aren't on screen at [t], so
  /// the selection stays visible while seeking. Drawn under everything, in
  /// one layer: a wide band per object, then its inside cleared.
  void _drawHiddenSelection(Canvas canvas, double t, double r, double preempt) {
    final hidden = [
      for (final h in controller.selection)
        if (!ObjectVisuals.isAlive(t, h.time, controller.endTimeOf(h), preempt, spinner: h is Spinner)) h,
    ];
    if (hidden.isEmpty) return;
    canvas.saveLayer(null, Paint());
    final band = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = _selectionColour;
    final hole = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..blendMode = BlendMode.clear;
    for (final pass in [band, hole]) {
      for (final h in hidden) {
        final stack = h is Spinner ? Vec2.zero : controller.stackOffsetOf(h);
        canvas.save();
        canvas.translate(stack.x, stack.y);
        final outer = identical(pass, band);
        switch (h) {
          case Spinner():
            if (outer) {
              canvas.drawCircle(const Offset(256, 192), 170, Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 6
                ..color = _selectionColour);
            }
          case SliderObject():
            final body = _bodyPaths[h] ??= _buildPath(controller.sliderPath(h).vertices);
            pass
              ..style = PaintingStyle.stroke
              ..strokeWidth = outer ? r * 2 + 8 : r * 2 + 2;
            canvas.drawPath(body, pass);
          default:
            pass
              ..style = outer ? PaintingStyle.stroke : PaintingStyle.fill
              ..strokeWidth = 3;
            canvas.drawCircle(Offset(h.position.x, h.position.y), outer ? r + 4 : r + 2.5, pass);
        }
        canvas.restore();
      }
    }
    canvas.restore();
  }

  static const _followPointSkinScale = 0.625;

  /// Follow points (lazer's): small arrows between the objects of a combo,
  /// under the objects.
  void _drawFollowPoints(Canvas canvas, double t, double r) {
    final pre = FollowPoints.preempt(controller.preempt);
    final fadeIn = controller.fadeIn;
    final size = FollowPoints.arrowSize(r);
    final frames = _skin?.frames('followpoint') ?? const <SkinTexture>[];
    if (frames.isNotEmpty) {
      // lazer: animated at the skin's frame rate, not scaled with the
      // circle size, at most 128 x 64 skin pixels; stable draws a skin
      // pixel at 0.625 osu!pixels (768p reference, like the spinner).
      final tex = frames[_frameIndex(frames.length, t, _skin!.ini.animationFramerate)];
      for (final c in controller.followConnectionsAt(t)) {
        FollowPoints.pointsAt(c, t, pre, fadeIn, (p, angle, alpha, scale) {
          _drawTexture(canvas, tex, Offset(p.x, p.y), scale * _followPointSkinScale, _imagePaint(alpha),
              maxSize: const Size(128, 64), rotation: angle);
        });
      }
      return;
    }
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final c in controller.followConnectionsAt(t)) {
      FollowPoints.pointsAt(c, t, pre, fadeIn, (p, angle, alpha, scale) {
        final s = size * scale;
        final dx = math.cos(angle), dy = math.sin(angle);
        // A chevron pointing along the connection.
        final tip = Offset(p.x + dx * s * 0.6, p.y + dy * s * 0.6);
        Offset wing(double side) =>
            Offset(p.x - dx * s * 0.4 - dy * s * 0.6 * side, p.y - dy * s * 0.4 + dx * s * 0.6 * side);
        paint
          ..strokeWidth = s * 0.32
          ..color = Color.fromRGBO(255, 255, 255, alpha * 0.9);
        // A polyline with round caps (round joins): no per-arrow Path.
        canvas.drawPoints(ui.PointMode.polygon, [wing(1), tip, wing(-1)], paint);
      });
    }
  }

  /// Frame of an [n]-frame skin animation at [ms]: [framerate] frames per
  /// second, or the whole animation in a second when it is <= 0 (stable's
  /// `AnimationFramerate` default).
  static int _frameIndex(int n, double ms, double framerate) {
    if (n <= 1) return 0;
    final frameMs = framerate > 0 ? 1000 / framerate : 1000 / n;
    return (ms / frameMs).floor() % n;
  }

  /// The slider edge whose hitsounds the toolbox edits: a bright ring.
  void _drawEdgeMarker(Canvas canvas, Vec2 p, double r) {
    final o = Offset(p.x, p.y);
    canvas.drawCircle(
      o,
      r + 7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..color = const Color(0xFF000000),
    );
    canvas.drawCircle(
      o,
      r + 7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = _edgeColour,
    );
  }

  static const _edgeColour = Color(0xFF40C4FF);

  void _drawSelectionRing(Canvas canvas, Vec2 p, double r) {
    canvas.drawCircle(
      Offset(p.x, p.y),
      r + 4,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = _selectionColour,
    );
  }

  static final Expando<ui.PathMetric> _bodyMetrics = Expando();

  /// The body path's bounds (the stroke reaches r further): every layer a
  /// slider uses is limited to them. A layer without bounds is as big as
  /// the whole view — one per slider on screen per frame.
  static final Expando<Rect> _bodyBounds = Expando();

  void _drawSlider(Canvas canvas, SliderObject s, double t, double end, double r, Color colour, bool selected,
      double preempt, double fadeIn) {
    final path = controller.sliderPath(s);
    final body = _bodyPaths[s] ??= _buildPath(path.vertices);
    final bounds = _bodyBounds[s] ??= body.getBounds();

    // The selection outline isn't snaked (lazer draws it separately).
    // Only the border band: the inside is cleared so the orange never shows
    // through the (translucent) body, whatever the time.
    if (selected) {
      canvas.saveLayer(bounds.inflate(r + 6), Paint());
      canvas.drawPath(
        body,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 2 + 8
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = _selectionColour,
      );
      canvas.drawPath(
        body,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 2 + 2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..blendMode = BlendMode.clear,
      );
      canvas.restore();
    }
    final dim = ObjectVisuals.brightness(t, s.time);
    final bodyAlpha = ObjectVisuals.sliderBodyAlpha(t, s.time, end, preempt, fadeIn);
    if (bodyAlpha > 0) {
      // Snakes in over the first third of the preempt.
      final snake = ObjectVisuals.snakeProgress(t, s.time, preempt);
      final track = controller.sliderTrackColour ?? colour, border = controller.sliderBorderColour;
      if (snake < 1 || !_drawCachedBody(canvas, s, body, bounds, r, track, border, dim, bodyAlpha)) {
        var drawn = body;
        if (snake < 1) {
          final metric = _bodyMetrics[s] ??= body.computeMetrics().firstOrNull ?? _emptyMetric;
          drawn = metric.extractPath(0, metric.length * snake);
        }
        paintSliderBody(canvas, drawn, r, track, border, dim: dim, alpha: bodyAlpha, bounds: bounds.inflate(r + 2));
      }
    }

    final span = controller.timing.sliderSpanDuration(s, controller.beatmap.sliderMultiplier);
    final pulse = _drawTicks(canvas, s, t, end, r, span, preempt);

    // End circles: the tail, then repeats (earlier ones on top). Span k ends
    // at the tail for even k, at the head for odd k.
    final tail = path.tail;
    final tailArrow = path.positionAtDistance(path.distance - r);
    final headArrow = path.positionAtDistance(r);
    final anim = controller.hitAnimations;
    final whole = ObjectVisuals.sliderAlpha(t, end, hitAnimations: anim);
    for (var k = s.slides - 1; k >= 0; k--) {
      final time = s.time + span * (k + 1);
      final atTail = k.isEven;
      final at = atTail ? tail : s.position;
      final repeat = k != s.slides - 1; // the last end is the tail: no arrow
      final alpha = ObjectVisuals.endCircleAlpha(t, k, time, s.time, span, preempt, fadeIn,
              hitAnimations: anim, repeat: repeat) *
          whole;
      if (alpha > 0) {
        // `sliderendcircle`: the default skin has none, so a hit circle
        // without its number.
        _drawCircle(canvas, at, r, colour, alpha, null,
            brightness: t >= time ? 1 : dim,
            white: ObjectVisuals.shownWhite(t, time, hitAnimations: anim),
            scale: ObjectVisuals.circleScale(t, time, hitAnimations: anim),
            element: 'sliderendcircle');
      }
      if (!repeat) continue;
      final arrow = ObjectVisuals.repeatArrowAlpha(t, k, time, s.time, span, preempt, hitAnimations: anim) * whole;
      if (arrow > 0) {
        final arrowScale = ObjectVisuals.repeatArrowScale(t, k, time, s.time, span, preempt, hitAnimations: anim);
        paintRepeatArrow(canvas, _skin, at, atTail ? tailArrow : headArrow, r, colour, arrow, scale: arrowScale);
      }
    }

    _drawHitCircle(canvas, s.position, r, colour, t, s.time, preempt, fadeIn, controller.shownComboOf(s).number,
        parentAlpha: whole, element: 'sliderstartcircle');

    final ballAlpha = ObjectVisuals.ballAlpha(t, s.time, end);
    final follow = ObjectVisuals.followCircle(t, s.time, end, pulse);
    if (ballAlpha <= 0 && follow == null) return;
    final ball = path.ballPositionAt(math.min(t, end), s.time, span, s.slides);
    final c = Offset(ball.x, ball.y);
    final skin = _skin;
    if (skin != null) {
      final balls = skin.frames('sliderb', separator: '');
      final follows = skin.frames('sliderfollowcircle');
      if (balls.isNotEmpty || follows.isNotEmpty) {
        _drawSkinBall(canvas, skin, s, path, c, t, end, span, r, colour, ballAlpha * whole, follow, whole, balls, follows);
        return;
      }
    }
    if (ballAlpha > 0) {
      canvas.drawCircle(c, r * 0.85, Paint()..color = _white.withValues(alpha: 0.85 * ballAlpha * whole));
    }
    if (follow != null) {
      final (scale, a) = follow;
      final alpha = a * whole;
      canvas.drawCircle(c, r * scale, Paint()..color = colour.withValues(alpha: 0.15 * alpha));
      canvas.drawCircle(
        c,
        r * scale,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.12
          ..color = colour.withValues(alpha: 0.9 * alpha),
      );
    }
  }

  /// lazer `LegacySliderBall` (`sliderb-nd` shadow, the `sliderb` frames
  /// facing along the path, tinted with `SliderBall` or the combo colour
  /// with `AllowSliderBallTint`, `sliderb-spec` added on top) and
  /// `LegacyFollowCircle` (its texture at half size, x the follow scale).
  /// Parts the skin lacks keep the built-in look.
  void _drawSkinBall(Canvas canvas, LoadedSkin skin, SliderObject s, SliderPath path, Offset c, double t, double end,
      double span, double r, Color colour, double ballAlpha, (double, double)? follow, double whole,
      List<SkinTexture> balls, List<SkinTexture> follows) {
    final k = _objectScale(r);
    const maxArea = Size(128 * 2.4, 128 * 2.4); // lazer MAX_FOLLOW_CIRCLE_AREA_SIZE
    if (ballAlpha > 0) {
      if (balls.isEmpty) {
        canvas.drawCircle(c, r * 0.85, Paint()..color = _white.withValues(alpha: 0.85 * ballAlpha));
      } else {
        final now = math.min(t, end);
        final ahead = path.ballPositionAt(math.min(now + 1, end), s.time, span, s.slides);
        final behind = path.ballPositionAt(math.max(now - 1, s.time), s.time, span, s.slides);
        final dir = ahead - behind;
        final angle = dir.lengthSquared == 0 ? 0.0 : math.atan2(dir.y, dir.x);
        // Frames last longer on slow sliders (lazer: 0.15 / velocity
        // sixtieths of a second, at least one).
        const sixtieth = 1000 / 60;
        final velocity = span > 0 ? path.distance / span : 0.0;
        final frameMs = velocity > 0 ? math.max(0.15 / velocity * sixtieth, sixtieth) : sixtieth;
        final frame = balls[((now - s.time) / frameMs).floor() % balls.length];
        final nd = skin['sliderb-nd'];
        if (nd != null) {
          _drawTexture(canvas, nd, c, k, _imagePaint(ballAlpha, tint: const Color(0xFF050505)), maxSize: maxArea);
        }
        final ini = skin.ini;
        final tint = ini.allowSliderBallTint
            ? colour
            : ini.sliderBall == null
                ? _white
                : EditorController.colourOf(ini.sliderBall!);
        _drawTexture(canvas, frame, c, k, _imagePaint(ballAlpha, tint: tint), maxSize: maxArea, rotation: angle);
        final spec = skin['sliderb-spec'];
        if (spec != null) {
          _drawTexture(canvas, spec, c, k, _imagePaint(ballAlpha)..blendMode = BlendMode.plus, maxSize: maxArea);
        }
      }
    }
    if (follow == null) return;
    final (scale, a) = follow;
    final alpha = a * whole;
    if (follows.isEmpty) {
      canvas.drawCircle(c, r * scale, Paint()..color = colour.withValues(alpha: 0.15 * alpha));
      canvas.drawCircle(
        c,
        r * scale,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.12
          ..color = colour.withValues(alpha: 0.9 * alpha),
      );
      return;
    }
    final tex = follows[_frameIndex(follows.length, t - s.time, skin.ini.animationFramerate)];
    _drawTexture(canvas, tex, c, k * 0.5 * scale, _imagePaint(alpha), maxSize: maxArea);
  }

  static final ui.PathMetric _emptyMetric = (ui.Path()..lineTo(0, 0)).computeMetrics().first;

  /// Whole (not snaking) slider bodies, each rendered once into an image at
  /// the device resolution it is shown at, then drawn as one textured quad
  /// with the body's opacity and dim. Drawing the body itself is a layer
  /// plus ten wide path strokes per slider per frame — the bulk of the GPU
  /// time with many sliders on screen. Least recently drawn first; made
  /// again when the zoom, circle size or colours change.
  static final _bodyImages = LinkedHashMap<SliderObject, _BodyImage>.identity();
  static int _bodyImagePixels = 0;
  static EditorController? _bodyImagesOwner;

  /// Pixels kept in [_bodyImages] (4 bytes each), and the largest image.
  static const _bodyImageBudget = 12 << 20;
  static const _maxBodyImageSide = 4096;

  /// Device pixels per osu!pixel in the last main-view paint, and whether
  /// it was the same in the one before: images are only made at a scale
  /// that holds (not on every frame of a pinch).
  static double _lastBodyScale = 0;
  static bool _bodyScaleSettled = false;

  /// Tests: draw every body as paths (to compare with the images).
  @visibleForTesting
  static bool debugNoBodyImages = false;

  static double get _devicePixelRatio => ui.PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 1;

  static void _clearBodyImages(EditorController? owner) {
    for (final e in _bodyImages.values) {
      e.image.dispose();
    }
    _bodyImages.clear();
    _bodyImagePixels = 0;
    _bodyImagesOwner = owner;
  }

  /// Draws slider [s]'s whole body from [_bodyImages] (rendering it first
  /// if needed). False when it can't (the overview, a rotated canvas, a
  /// scale still changing, an image too big): draw the path instead.
  bool _drawCachedBody(Canvas canvas, SliderObject s, ui.Path body, Rect bounds, double r, Color track, Color? border,
      double dim, double alpha) {
    if (overview || debugNoBodyImages) return false;
    final m = canvas.getTransform();
    if (m[1] != 0 || m[4] != 0 || m[0] != m[5] || m[0] <= 0) return false;
    final dpr = _devicePixelRatio;
    final k = m[0] * dpr; // device pixels per osu!pixel
    var e = _bodyImages.remove(s);
    if (e != null && (e.scale != k || e.r != r || e.track != track || e.border != border)) {
      _bodyImagePixels -= e.image.width * e.image.height;
      e.image.dispose();
      e = null;
    }
    if (e == null) {
      if (!_bodyScaleSettled) return false;
      final area = bounds.inflate(r + 2);
      // Pixel (0, 0) on a whole device pixel, so the image lands 1:1.
      final left = ((m[0] * area.left + m[12]) * dpr).floorToDouble();
      final top = ((m[0] * area.top + m[13]) * dpr).floorToDouble();
      final w = ((m[0] * area.right + m[12]) * dpr).ceil() - left.toInt();
      final h = ((m[0] * area.bottom + m[13]) * dpr).ceil() - top.toInt();
      if (w <= 0 || h <= 0 || w > _maxBodyImageSide || h > _maxBodyImageSide || w * h > _bodyImageBudget ~/ 2) {
        return false;
      }
      final origin = Offset((left / dpr - m[12]) / m[0], (top / dpr - m[13]) / m[0]);
      final recorder = ui.PictureRecorder();
      final c = Canvas(recorder);
      c.scale(k);
      c.translate(-origin.dx, -origin.dy);
      paintSliderBody(c, body, r, track, border, bounds: area);
      final picture = recorder.endRecording();
      e = _BodyImage(picture.toImageSync(w, h), origin, k, r, track, border);
      picture.dispose();
      _bodyImagePixels += w * h;
      while (_bodyImagePixels > _bodyImageBudget && _bodyImages.isNotEmpty) {
        final oldest = _bodyImages.keys.first;
        final old = _bodyImages.remove(oldest)!;
        _bodyImagePixels -= old.image.width * old.image.height;
        old.image.dispose();
      }
    }
    _bodyImages[s] = e; // now the most recently drawn
    final img = e.image;
    final x = ((m[0] * e.origin.dx + m[12]) * dpr).roundToDouble();
    final y = ((m[0] * e.origin.dy + m[13]) * dpr).roundToDouble();
    // Bilinear: exact at 1:1, smooth when the frame is scaled (screenshots).
    final paint = Paint()
      ..filterQuality = FilterQuality.low
      ..color = Color.fromRGBO(0, 0, 0, alpha.clamp(0.0, 1.0));
    // The body's colours times [dim] (its shadow is black either way).
    if (dim < 1) paint.colorFilter = ColorFilter.mode(Color.from(alpha: 1, red: dim, green: dim, blue: dim), BlendMode.modulate);
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH((x / dpr - m[12]) / m[0], (y / dpr - m[13]) / m[0], img.width / k, img.height / k),
      paint,
    );
    return true;
  }

  /// Slider ticks of every span, each with its own lifetime (they pop in
  /// before their time and burst when passed). Returns the latest tick or
  /// repeat time at or before `min(t, end)`, for the follow circle's pulse.
  double? _drawTicks(Canvas canvas, SliderObject s, double t, double end, double r, double span, double preempt) {
    final now = math.min(t, end);
    double? pulse;
    var current = -1; // the span `now` is in
    if (span > 0 && now > s.time) {
      current = math.min(((now - s.time) / span).floor(), s.slides - 1);
      if (current > 0) pulse = s.time + span * current; // the repeat that started it
    }
    final positions = controller.sliderTickPositions(s);
    if (positions.isEmpty || span <= 0) return pulse;
    final progress = controller.sliderTickProgress(s);
    final paint = Paint();
    final tickTex = _skin?['sliderscorepoint'];
    final k = _objectScale(r);
    for (var j = 0; j < s.slides; j++) {
      final spanStart = s.time + span * j;
      // Earliest a tick of this span can appear, latest it can still show.
      if (j != current &&
          (t < spanStart - (j == 0 ? preempt * 0.66 : 200) || t > spanStart + span + ObjectVisuals.tickAnim)) {
        continue;
      }
      for (var i = 0; i < positions.length; i++) {
        final time = spanStart + (j.isEven ? progress[i] : 1 - progress[i]) * span;
        if (time <= now && (pulse == null || time > pulse)) pulse = time;
        final v = ObjectVisuals.tick(t, time, ObjectVisuals.tickPreempt(time, spanStart, j, preempt));
        if (v == null || v.$1 <= 0) continue;
        if (tickTex != null) {
          _drawTexture(canvas, tickTex, Offset(positions[i].x, positions[i].y), k * v.$2, _imagePaint(v.$1),
              maxSize: const Size(128, 128));
          continue;
        }
        paint.color = _white.withValues(alpha: v.$1 * 0.9);
        canvas.drawCircle(Offset(positions[i].x, positions[i].y), r * 0.13 * v.$2, paint);
      }
    }
    return pulse;
  }

  /// The slider being drawn with the slider tool, or the stroke of the
  /// Draw tool (as a translucent slider body along the finger's path).
  void _drawDraft(Canvas canvas, double r, double scale) {
    final stroke = controller.freehandStroke;
    if (stroke != null && stroke.isNotEmpty) {
      const colour = Color(0xFF66CCFF);
      final head = stroke.first;
      if (stroke.length > 1) {
        canvas.drawPath(
          _buildPath(stroke),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = r * 2
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..color = colour.withValues(alpha: 0.35),
        );
      }
      canvas.drawCircle(Offset(head.x, head.y), r, Paint()..color = colour.withValues(alpha: 0.6));
      return;
    }
    if (!controller.isDrafting) return;
    final s = controller.draftSlider;
    const colour = Color(0xFF66CCFF);
    if (s == null) {
      final head = controller.draftHead!;
      canvas.drawCircle(Offset(head.x, head.y), r, Paint()..color = colour.withValues(alpha: 0.5));
      _drawControlPoints(canvas, controller.draftPoints, null, scale);
      return;
    }
    final path = SliderPath.cached(s);
    final body = _buildPath(path.vertices);
    canvas.drawPath(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = colour.withValues(alpha: 0.35),
    );
    canvas.drawCircle(Offset(s.position.x, s.position.y), r, Paint()..color = colour.withValues(alpha: 0.6));
    // The drawn points, not the slider's: a red tail shows before it counts.
    final pts = controller.draftPoints;
    _drawControlPoints(canvas, pts, pts.length - 1, scale);
  }

  /// The repeat arrow on a slider end at [at] pointing toward [toward]:
  /// the [skin]'s `reversearrow` if it has one, else [_drawRepeatArrow]
  /// (dark on a bright [colour]).
  static void paintRepeatArrow(Canvas canvas, LoadedSkin? skin, Vec2 at, Vec2 toward, double r, Color colour,
      double alpha, {double scale = 1}) {
    final tex = skin?['reversearrow'];
    if (tex != null) {
      // A skin's own arrow is never darkened (lazer: only the default skin's).
      final dir = toward - at;
      _drawTexture(canvas, tex, Offset(at.x, at.y), _objectScale(r) * scale, _imagePaint(alpha),
          rotation: dir.lengthSquared == 0 ? 0 : math.atan2(dir.y, dir.x));
    } else {
      _drawRepeatArrow(canvas, at, toward, r, alpha, scale: scale, dark: _isBright(colour));
    }
  }

  /// The classic `reversearrow` on a slider end, pointing back along the
  /// path (toward [toward]): white, black on bright combo colours ([dark],
  /// like lazer with the default skin), [scale]d by its pulse.
  static void _drawRepeatArrow(Canvas canvas, Vec2 at, Vec2 toward, double r, double alpha,
      {double scale = 1, bool dark = false}) {
    final dir = toward - at;
    final angle = dir.lengthSquared == 0 ? 0.0 : math.atan2(dir.y, dir.x);
    final w = r * 0.5 * scale;
    canvas.save();
    canvas.translate(at.x, at.y);
    canvas.rotate(angle);
    // A polyline with round caps (round joins): no per-arrow Path.
    canvas.drawPoints(
      ui.PointMode.polygon,
      [Offset(-w * 0.45, -w), Offset(w * 0.55, 0), Offset(-w * 0.45, w)],
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.2 * scale
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = dark ? Color.fromRGBO(0, 0, 0, alpha) : Color.fromRGBO(255, 255, 255, alpha),
    );
    canvas.restore();
  }

  /// lazer's test for the black default arrow: R + G + B over 600 / 255.
  static bool _isBright(Color c) => c.r + c.g + c.b > 600 / 255;

  /// The classic slider body (lazer `LegacySliderBody`, stable's slider
  /// renderer): from the edge in, a faint shadow, the border
  /// ([Colours] SliderBorder, else white) and the track — [track] at 70 %
  /// opacity, from slightly darker at the border to lighter in the middle.
  /// Drawn as nested strokes in one layer, each replacing the one under it.
  /// [border] null: white. [bounds] limits the layer (whole canvas if null).
  static void paintSliderBody(Canvas canvas, ui.Path path, double r, Color track, Color? border,
      {double dim = 1, double alpha = 1, Rect? bounds}) {
    const shadowPortion = 5 / 64; // 1 − LEGACY_CIRCLE_RADIUS / OBJECT_RADIUS
    const borderPortion = 0.1875;
    const steps = 8;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..blendMode = BlendMode.src;
    double width(double portion) => 2 * r * (1 - portion);
    canvas.saveLayer(bounds, Paint()..color = Color.fromRGBO(0, 0, 0, alpha));
    canvas.drawPath(path, stroke
      ..strokeWidth = width(0)
      ..color = const Color(0x20000000));
    canvas.drawPath(path, stroke
      ..strokeWidth = width(shadowPortion)
      ..color = _shade(border ?? _white, dim, 1));
    final outer = _darken(track, 0.1), inner = _lighten(track, 0.5);
    for (var i = 0; i < steps; i++) {
      final f = i / (steps - 1);
      canvas.drawPath(path, stroke
        ..strokeWidth = width(borderPortion + (1 - borderPortion) * i / steps)
        ..color = _shade(Color.lerp(outer, inner, f)!, dim, 0.7));
    }
    canvas.restore();
  }

  /// Pill images for [paintStraightBody], per device radius and colours.
  static final _pillImages = <(double, int, int?), ui.Image>{};

  /// [paintSliderBody] of a straight horizontal body from [x0] to [x1] at
  /// height [y] (the timeline's): a body rendered once per radius and
  /// colours into a small image, stretched along its middle (nine-slice)
  /// — no layer and no path strokes per object per frame.
  static void paintStraightBody(Canvas canvas, double x0, double x1, double y, double r, Color track, Color? border) {
    final m = canvas.getTransform();
    final dpr = _devicePixelRatio;
    final k = m[0] * dpr;
    if (debugNoBodyImages || m[1] != 0 || m[4] != 0 || m[0] != m[5] || k <= 0 || (x1 - x0) * k < 1) {
      paintSliderBody(canvas, ui.Path()..moveTo(x0, y)..lineTo(x1, y), r, track, border,
          bounds: Rect.fromLTRB(x0 - r, y - r, x1 + r, y + r));
      return;
    }
    final rp = r * k;
    final half = (rp + 2).ceilToDouble(); // the stroke plus its antialiasing
    final key = (rp, track.toARGB32(), border?.toARGB32());
    var img = _pillImages[key];
    if (img == null) {
      if (_pillImages.length >= 64) {
        for (final i in _pillImages.values) {
          i.dispose();
        }
        _pillImages.clear();
      }
      final recorder = ui.PictureRecorder();
      paintSliderBody(Canvas(recorder), ui.Path()..moveTo(half, half)..lineTo(half + 1, half), rp, track, border);
      final picture = recorder.endRecording();
      img = _pillImages[key] = picture.toImageSync(2 * half.toInt() + 1, 2 * half.toInt());
      picture.dispose();
    }
    canvas.save();
    canvas.scale(1 / k); // one unit = one device pixel
    // On whole device pixels vertically (it only moves sideways).
    final top = ((m[0] * y + m[13]) * dpr - half).roundToDouble() - m[13] * dpr;
    canvas.drawImageNine(img, Rect.fromLTWH(half, half, 1, 1),
        Rect.fromLTRB(x0 * k - half, top, x1 * k + half, top + 2 * half), Paint()..filterQuality = FilterQuality.low);
    canvas.restore();
  }

  /// osu!framework `Color4.Darken`.
  static Color _darken(Color c, double amount) {
    final k = 1 / (1 + amount);
    return Color.from(alpha: c.a, red: c.r * k, green: c.g * k, blue: c.b * k);
  }

  /// `LegacySliderBody.lighten` (friendlier to dark / strong colours).
  static Color _lighten(Color c, double amount) {
    final a = amount * 0.5;
    double ch(double v) => math.min(1.0, v * (1 + 0.5 * a) + a);
    return Color.from(alpha: c.a, red: ch(c.r), green: ch(c.g), blue: ch(c.b));
  }

  /// Handle colour of a point starting a segment of [type] in osu!lazer's
  /// model (lazer's hues; inheriting points stay white).
  static Color pointTypeColour(PathType? type) => switch (type) {
        null => const Color(0xFFFFFFFF),
        PathType(kind: CurveType.linear) => const Color(0xFFFF3B3B),
        PathType(kind: CurveType.perfectCircle) => const Color(0xFF9070FF),
        PathType(kind: CurveType.catmull) => const Color(0xFF05FFA2),
        PathType(kind: CurveType.bezier, degree: null) => const Color(0xFFFFA8D4),
        PathType(kind: CurveType.bezier) => const Color(0xFFFF4FA0),
      };

  /// Control polygon + handles. Handles keep a constant on-screen size
  /// (they're touch targets), so they are sized by 1 / [scale]. [typed]:
  /// colours by lazer segment type instead of red anchors.
  static void _drawControlPoints(Canvas canvas, List<PathPoint> pts, int? selected, double scale,
      {bool typed = false}) {
    final line = Paint()
      ..color = const Color(0xAAFFFFFF)
      ..strokeWidth = 1.5 / scale;
    for (var i = 1; i < pts.length; i++) {
      final a = pts[i - 1].position, b = pts[i].position;
      canvas.drawLine(Offset(a.x, a.y), Offset(b.x, b.y), line);
    }
    final size = 12 / scale;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 / scale
      ..color = const Color(0xFF000000);
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i].position;
      final rect = Rect.fromCenter(center: Offset(p.x, p.y), width: size, height: size);
      if (i == selected) {
        canvas.drawRect(rect.inflate(4 / scale), Paint()..color = _selectionColour);
      }
      final colour = typed
          ? pointTypeColour(pts[i].type)
          : pts[i].red
              ? const Color(0xFFFF3B3B)
              : const Color(0xFFFFFFFF);
      canvas.drawRect(rect, Paint()..color = colour);
      canvas.drawRect(rect, outline);
    }
  }

  static ui.Path _buildPath(List<Vec2> v) {
    final p = ui.Path();
    if (v.isEmpty) return p;
    p.moveTo(v.first.x, v.first.y);
    for (var i = 1; i < v.length; i++) {
      p.lineTo(v[i].x, v[i].y);
    }
    return p;
  }

  void _drawSpinner(Canvas canvas, Spinner s, double t, double end, double preempt, bool selected) {
    const centre = Offset(256, 192);
    // The selection ring keeps its size while the spinner grows.
    if (selected) {
      canvas.drawCircle(
        centre,
        170,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..color = _selectionColour,
      );
    }
    final (scale, alpha) = ObjectVisuals.spinner(t, s.time, end, preempt, controller.fadeIn);
    if (alpha <= 0) return;
    // Skin spinners ignore the grow-in scale, so they fade in from the start.
    final skin = _skin;
    if (skin != null && _drawSkinSpinner(canvas, skin, s, t, end, alpha)) return;
    if (scale <= 0) return;
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.scale(scale);
    if (!selected) {
      canvas.drawCircle(
        Offset.zero,
        170,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..color = _white.withValues(alpha: alpha * 0.8),
      );
    }
    if (t >= s.time && end > s.time) {
      final progress = ((t - s.time) / (end - s.time)).clamp(0.0, 1.0);
      canvas.drawArc(
        Rect.fromCircle(center: Offset.zero, radius: 150),
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10
          ..color = Color.fromRGBO(120, 200, 255, alpha),
      );
    }
    canvas.restore();
  }

  /// A classic spinner from the skin, if it has one: new style
  /// (`spinner-bottom` / `-top` / `-middle2` / `-middle`) or old style
  /// (`spinner-background`, `-circle`, `-approachcircle`), lazer's
  /// `LegacyNewStyleSpinner` / `LegacyOldStyleSpinner` at their 0.625 sprite
  /// scale, spun at a steady rate (the editor's autoplay). Returns whether
  /// it drew.
  bool _drawSkinSpinner(Canvas canvas, LoadedSkin skin, Spinner s, double t, double end, double alpha) {
    const centre = Offset(256, 192), k = 0.625;
    final background = skin['spinner-background'];
    final top = skin['spinner-top'];
    final circle = skin['spinner-circle'];
    if (background == null && top == null && circle == null) return false;
    final spun = math.max(0.0, math.min(t, end) - s.time);
    final rotation = spun / 1000 * 2 * math.pi * 2; // two turns a second
    final progress = end > s.time ? (spun / (end - s.time)).clamp(0.0, 1.0) : 0.0;
    final paint = _imagePaint(alpha);
    const big = Size(4096, 4096);
    if (top != null && background == null) {
      final bottom = skin['spinner-bottom'], middle2 = skin['spinner-middle2'], middle = skin['spinner-middle'];
      if (bottom != null) _drawTexture(canvas, bottom, centre, k, paint, maxSize: big, rotation: rotation / 3);
      _drawTexture(canvas, top, centre, k, paint, maxSize: big, rotation: rotation);
      if (middle2 != null) _drawTexture(canvas, middle2, centre, k, paint, maxSize: big);
      if (middle != null) {
        // Turns red as the spin completes.
        final red = Color.lerp(_white, const Color(0xFFFF0000), progress)!;
        _drawTexture(canvas, middle, centre, k, _imagePaint(alpha, tint: red), maxSize: big);
      }
    } else {
      if (background != null) _drawTexture(canvas, background, centre, k, paint, maxSize: big);
      if (circle != null) _drawTexture(canvas, circle, centre, k, paint, maxSize: big, rotation: rotation);
    }
    final approach = skin['spinner-approachcircle'];
    if (approach != null && t >= s.time && t <= end) {
      _drawTexture(canvas, approach, centre, k * 1.86 * (1 - progress), paint, maxSize: big);
    }
    return true;
  }

  @override
  bool shouldRepaint(covariant PlayfieldPainter old) =>
      old.controller != controller || old.overview != overview || old.viewport != viewport;
}

/// A slider body rendered by [PlayfieldPainter._drawCachedBody]: [image]'s
/// pixel (0, 0) is at osu!pixel [origin], [scale] device pixels per osu!pixel.
class _BodyImage {
  final ui.Image image;
  final Offset origin;
  final double scale;
  final double r;
  final Color track;
  final Color? border;

  _BodyImage(this.image, this.origin, this.scale, this.r, this.track, this.border);
}

/// The built-in combo number font: digits 0–9 as images, white with a soft
/// dark edge baked in, made once and drawn like a skin's `default-n`
/// (fading and dimming through the paint). Text shadows instead would be
/// an offscreen blur pass per shadow per number every frame — with dozens
/// of numbers on screen (streams, the timeline) that took the phone's GPU
/// 100–400 ms a frame.
class _BuiltinDigits {
  static final instance = _BuiltinDigits._();

  /// Font size the digits are baked at (sharp up to ~2x zoom on a phone).
  static const _size = 128.0;
  final _images = <ui.Image>[];
  final _advances = <double>[];
  late final double _height;
  late final double _pad;

  _BuiltinDigits._() {
    // The look of the former text: weight 600 at 0.8 r, and four shadows of
    // grey 40 at 80 % offset r / 40 diagonally, blurred r / 30.
    const offset = _size / 0.8 / 40, blur = _size / 0.8 / 30;
    _pad = (offset + blur * 2).ceilToDouble();
    for (var d = 0; d < 10; d++) {
      final tp = TextPainter(
        text: TextSpan(
          text: '$d',
          style: TextStyle(
            color: const Color(0xFFFFFFFF),
            fontSize: _size,
            fontFamily: kUiFont,
            fontWeight: FontWeight.w600,
            shadows: [
              for (final o in const [Offset(1, 1), Offset(-1, 1), Offset(1, -1), Offset(-1, -1)])
                Shadow(color: const Color.fromRGBO(40, 40, 40, 0.8), offset: o * offset, blurRadius: blur),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final recorder = ui.PictureRecorder();
      tp.paint(Canvas(recorder), Offset(_pad, _pad));
      final picture = recorder.endRecording();
      _images.add(picture.toImageSync((tp.width + 2 * _pad).ceil(), (tp.height + 2 * _pad).ceil()));
      picture.dispose();
      _advances.add(tp.width);
      if (d == 0) _height = tp.height;
      tp.dispose();
    }
  }

  /// [number] centred on [c] for a circle of radius [r] (text size 0.8 r).
  void paint(Canvas canvas, int number, Offset c, double r, Paint paint) {
    final s = r * 0.8 / _size;
    final digits = [for (final ch in '$number'.codeUnits) ch - 48];
    var width = 0.0;
    for (final d in digits) {
      width += _advances[d];
    }
    var x = c.dx - width * s / 2;
    final top = c.dy - (_height / 2 + _pad) * s;
    for (final d in digits) {
      final img = _images[d];
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Rect.fromLTWH(x - _pad * s, top, img.width * s, img.height * s),
        paint,
      );
      x += _advances[d] * s;
    }
  }
}
