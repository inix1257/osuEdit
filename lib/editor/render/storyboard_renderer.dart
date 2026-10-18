import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import '../../core/core.dart';
import '../../platform/storyboard_loader.dart';

/// Draws a storyboard frame in storyboard pixels (the canvas must already
/// map 640x480 storyboard space and clip to it).
///
/// Performance (big storyboards have ~100k sprites, ~2k on screen at once):
/// * only sprites alive at the time are visited ([Storyboard.forEachAlive]);
/// * states go into one reused [SpriteState]; frame textures are looked up
///   by index ([LoadedStoryboard.textureAt]);
/// * sprites off the visible area are skipped;
/// * consecutive sprites with the same image and blend mode are drawn with
///   one [Canvas.drawRawAtlas] (colour and opacity as per-sprite colours);
///   only flipped or non-uniformly scaled sprites take a draw call each.
abstract final class StoryboardRenderer {
  static final _state = SpriteState();

  // Atlas batch being collected.
  static Float32List _xforms = Float32List(4 * 256);
  static Float32List _rects = Float32List(4 * 256);
  static Int32List _colors = Int32List(256);
  static int _n = 0;
  static Image? _image;
  static bool _additive = false;

  /// Draw calls / sprites of the last frame (benchmarks).
  static int debugDrawCalls = 0, debugSprites = 0, debugSingles = 0;

  static final _atlasPaint = Paint()..filterQuality = FilterQuality.low;
  static final _onePaint = Paint()..filterQuality = FilterQuality.low;

  /// Draws [sb] at [time]; [visible] is the part of storyboard space on
  /// screen (sprites entirely outside it are skipped). Pass state: the Fail
  /// layer is never drawn.
  static void draw(Canvas canvas, LoadedStoryboard sb, double time, Rect visible) {
    _n = 0;
    _image = null;
    debugDrawCalls = 0;
    debugSprites = 0;
    debugSingles = 0;
    final st = _state;
    sb.storyboard.forEachAlive(time, (i, s) {
      if (s.layer == StoryboardLayer.fail) return;
      final tex = sb.textureAt(i, s, time);
      if (tex == null || !s.stateInto(time, st)) return;
      final sx = st.scaleX, sy = st.scaleY;
      if (sx == 0 || sy == 0) return;
      // Anchor-to-corner distance bounds the sprite whatever its rotation.
      final r = tex.width * sx.abs() + tex.height * sy.abs();
      if (st.x + r < visible.left || st.x - r > visible.right || st.y + r < visible.top || st.y - r > visible.bottom) {
        return;
      }
      final img = tex.image;
      debugSprites++;
      if (!st.flipH && !st.flipV && sx > 0 && (sx - sy).abs() <= sx * 1e-4) {
        if (_n > 0 && (!identical(img, _image) || st.additive != _additive)) _flush(canvas);
        _add(img, tex, s.origin, st);
      } else {
        _flush(canvas);
        _drawOne(canvas, tex, s.origin, st);
      }
    });
    _flush(canvas);
    _image = null;
  }

  static void _add(Image img, StoryboardTexture tex, StoryboardOrigin origin, SpriteState st) {
    _image = img;
    _additive = st.additive;
    if (_n == _colors.length) {
      _xforms = Float32List(_xforms.length * 2)..setAll(0, _xforms);
      _rects = Float32List(_rects.length * 2)..setAll(0, _rects);
      _colors = Int32List(_colors.length * 2)..setAll(0, _colors);
    }
    final iw = img.width.toDouble(), ih = img.height.toDouble();
    // Image pixels -> storyboard pixels (the image may be downscaled).
    final k = st.scaleX * tex.width / iw;
    final ax = origin.x * iw, ay = origin.y * ih;
    final rot = st.rotation;
    final c = rot == 0 ? k : math.cos(rot) * k, s = rot == 0 ? 0.0 : math.sin(rot) * k;
    final o = _n * 4;
    _xforms
      ..[o] = c
      ..[o + 1] = s
      ..[o + 2] = st.x - c * ax + s * ay
      ..[o + 3] = st.y - s * ax - c * ay;
    _rects
      ..[o] = 0
      ..[o + 1] = 0
      ..[o + 2] = iw
      ..[o + 3] = ih;
    _colors[_n] = _argb(st);
    _n++;
  }

  static int _argb(SpriteState st) {
    int ch(double v) => v <= 0 ? 0 : (v >= 255 ? 255 : v.round());
    final a = ch(st.opacity * 255);
    return (a << 24) | (ch(st.r) << 16) | (ch(st.g) << 8) | ch(st.b);
  }

  static void _flush(Canvas canvas) {
    final img = _image;
    if (_n == 0 || img == null) return;
    debugDrawCalls++;
    _atlasPaint.blendMode = _additive ? BlendMode.plus : BlendMode.srcOver;
    canvas.drawRawAtlas(
      img,
      Float32List.sublistView(_xforms, 0, _n * 4),
      Float32List.sublistView(_rects, 0, _n * 4),
      Int32List.sublistView(_colors, 0, _n),
      BlendMode.modulate,
      null,
      _atlasPaint,
    );
    _n = 0;
  }

  /// A flipped or non-uniformly scaled sprite (RSTransform can't express it).
  static void _drawOne(Canvas canvas, StoryboardTexture tex, StoryboardOrigin origin, SpriteState st) {
    debugDrawCalls++;
    debugSingles++;
    canvas.save();
    canvas.translate(st.x, st.y);
    if (st.rotation != 0) canvas.rotate(st.rotation);
    canvas.scale(st.scaleX, st.scaleY);
    // A flip mirrors the image in place: the anchor moves to the opposite
    // side (osu!), unlike a negative V scale, which mirrors around it.
    var ox = origin.x, oy = origin.y;
    if (st.flipH || st.flipV) {
      canvas.scale(st.flipH ? -1 : 1, st.flipV ? -1 : 1);
      if (st.flipH) ox = 1 - ox;
      if (st.flipV) oy = 1 - oy;
    }
    _onePaint
      ..color = Color.fromRGBO(255, 255, 255, st.opacity)
      ..blendMode = st.additive ? BlendMode.plus : BlendMode.srcOver
      ..colorFilter = st.isTinted
          ? ColorFilter.mode(Color(_argb(st) | 0xFF000000), BlendMode.modulate)
          : null;
    final img = tex.image;
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(-ox * tex.width, -oy * tex.height, tex.width, tex.height),
      _onePaint,
    );
    canvas.restore();
  }
}
