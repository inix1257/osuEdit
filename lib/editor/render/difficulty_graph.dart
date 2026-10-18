import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import '../../core/core.dart';

/// The difficulty curve of a [StarAnalysis] (aim, speed and reading
/// combined like the star rating, [StarAnalysis.strains]), drawn behind
/// the Compose timelines (the zoomed one at the top, the whole-map overview
/// at the bottom) so difficulty spikes show where they are. Scaled so the
/// hardest moment reaches the top; values are per object (they decay
/// between objects; the curve joins them with straight lines).
abstract final class DifficultyGraph {
  static const colour = Color(0xFFFF66AA);

  static final Expando<Float64List> _normalised = Expando();

  /// Heights in [0, 1] per object, computed once per analysis.
  static Float64List _heights(StarAnalysis a) => _normalised[a] ??= () {
        var peak = 0.0;
        for (final s in a.strains) {
          if (s > peak) peak = s;
        }
        final out = Float64List(a.strains.length);
        if (peak <= 0) return out;
        for (var i = 0; i < out.length; i++) {
          out[i] = (a.strains[i] / peak).clamp(0.0, 1.0);
        }
        return out;
      }();

  /// The objects between [from] and [to] (plus one on each side), at
  /// [x] of their time, between [top] (height 1) and [bottom] (0).
  static void paintRange(Canvas canvas, StarAnalysis a,
      {required double from,
      required double to,
      required double Function(double t) x,
      required double top,
      required double bottom}) {
    final times = a.times;
    if (times.isEmpty) return;
    var lo = _lowerBound(times, from) - 1;
    var hi = _lowerBound(times, to) + 1;
    lo = math.max(0, lo);
    hi = math.min(times.length, hi);
    if (hi - lo < 1) return;
    final values = _heights(a);
    final pts = <Offset>[
      for (var i = lo; i < hi; i++) Offset(x(times[i]), bottom - values[i] * (bottom - top)),
    ];
    _paintCurve(canvas, pts, bottom);
  }

  /// The whole map from [start] to [end] across [width]: the highest
  /// strain in each [step]-pixel column.
  static void paintOverview(Canvas canvas, StarAnalysis a,
      {required double start,
      required double end,
      required double width,
      required double top,
      required double bottom,
      double step = 2,
      double scaleX = 1,
      double shiftX = 0}) {
    // [scaleX] / [shiftX] stretch the finished curve (a magnifier) without
    // resampling it finer, which would leave gaps between the sections.
    final times = a.times;
    if (times.isEmpty || end <= start || width <= 0) return;
    final columns = (width / step).ceil() + 1;
    final values = _heights(a);
    final peak = Float64List(columns);
    for (var i = 0; i < times.length; i++) {
      final col = ((times[i] - start) / (end - start) * width / step).floor();
      if (col < 0 || col >= columns) continue;
      if (values[i] > peak[col]) peak[col] = values[i];
    }
    final pts = <Offset>[
      for (var c = 0; c < columns; c++)
        Offset(math.min(width, c * step) * scaleX + shiftX, bottom - peak[c] * (bottom - top)),
    ];
    _paintCurve(canvas, pts, bottom);
  }

  static void _paintCurve(Canvas canvas, List<Offset> pts, double bottom) {
    if (pts.isEmpty) return;
    final line = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final p in pts.skip(1)) {
      line.lineTo(p.dx, p.dy);
    }
    final fill = Path.from(line)
      ..lineTo(pts.last.dx, bottom)
      ..lineTo(pts.first.dx, bottom)
      ..close();
    canvas.drawPath(fill, Paint()..color = colour.withValues(alpha: 0.22));
    canvas.drawPath(
      line,
      Paint()
        ..color = colour.withValues(alpha: 0.75)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  static int _lowerBound(Float64List list, double t) {
    var lo = 0, hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (list[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}
