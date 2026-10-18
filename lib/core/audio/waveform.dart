import 'dart:math' as math;
import 'dart:typed_data';

/// Loudness envelope of a song for the timeline: one RMS value per
/// [binMs] of audio, plus max-pooled coarser levels (×4 each) so drawing a
/// zoomed-out timeline touches only a few values per pixel.
class Waveform {
  /// Width of one level-0 bin in ms (audio time).
  final double binMs;

  /// `levels[0]` = the raw RMS bins; `levels[k]` pools 4^k bins by max.
  final List<Float32List> levels;

  /// Multiplier that maps values to 0..1 (from a high percentile, so a
  /// single spike doesn't flatten everything else).
  final double scale;

  Waveform._(this.binMs, this.levels, this.scale);

  factory Waveform(Float32List rms, double binMs) {
    final levels = <Float32List>[rms];
    while (levels.last.length > 64) {
      final prev = levels.last;
      final next = Float32List((prev.length + 3) ~/ 4);
      for (var i = 0; i < prev.length; i++) {
        final j = i >> 2;
        if (prev[i] > next[j]) next[j] = prev[i];
      }
      levels.add(next);
    }
    var ref = 0.0;
    if (rms.isNotEmpty) {
      final sorted = Float32List.fromList(rms)..sort();
      ref = sorted[math.min(sorted.length - 1, (sorted.length * 0.995).floor())];
    }
    return Waveform._(binMs, levels, ref > 1e-6 ? 1 / ref : 1);
  }

  /// Audio length covered, in ms.
  double get duration => levels.first.length * binMs;

  /// Loudest value (0..1, clamped) in the audio time range [from, to).
  /// [to] − [from] picks the level: the finest one whose bins are no wider
  /// than the range.
  double peak(double from, double to) {
    if (to <= 0 || from >= duration || to <= from) return 0;
    var level = 0;
    var bin = binMs;
    while (level + 1 < levels.length && bin * 4 <= to - from) {
      level++;
      bin *= 4;
    }
    final data = levels[level];
    final a = math.max(0, (from / bin).floor());
    final b = math.min(data.length - 1, math.max(a, (to / bin).ceil() - 1));
    var m = 0.0;
    for (var i = a; i <= b; i++) {
      if (data[i] > m) m = data[i];
    }
    return math.min(1.0, m * scale);
  }
}
