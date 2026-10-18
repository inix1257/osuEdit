import 'dart:math' as math;
import 'dart:typed_data';

/// One column of a [DetailedWaveform]: the lowest / highest sample (−1..1)
/// and the loudness of the low / mid / high frequency bands (0..1) over a
/// time range. Reused between queries (no allocation per column).
class WaveColumn {
  double min = 0, max = 0, low = 0, mid = 0, high = 0;

  bool get isSilent => max - min < 1e-3;
}

/// A song's waveform close to sample resolution, for the Timing mode's BPM
/// view (the timeline's [Waveform] is a 5 ms loudness envelope):
/// * min / max sample per [binFrames] frames (~0.1 ms), with max-pooled
///   coarser levels (×4 each) so a zoomed-out view touches only a few
///   values per pixel;
/// * the peak of three frequency bands (low < ~200 Hz, mid, high > ~2 kHz)
///   per [bandFrames] frames, for lazer-style colouring: kicks read as low,
///   hats / claps as high.
class DetailedWaveform {
  /// Frames per second of the source samples.
  final double sampleRate;

  /// Frames per level-0 min / max bin.
  final int binFrames;

  /// `mins[k]` / `maxs[k]`: level k pools 4^k level-0 bins (samples ×32767).
  final List<Int16List> mins, maxs;

  /// Frames per level-0 band bin.
  final int bandFrames;

  /// Band peaks (0..255, each band normalised on its own), pooled like
  /// [mins].
  final List<Uint8List> lows, mids, highs;

  /// Maps sample values to the display range (from a high percentile of
  /// the peaks, so one spike doesn't flatten the rest).
  final double scale;

  /// Number of source frames.
  final int frames;

  DetailedWaveform._(this.sampleRate, this.frames, this.binFrames, this.mins, this.maxs, this.bandFrames,
      this.lows, this.mids, this.highs, this.scale);

  /// Builds from mono [samples] at [sampleRate] frames per second.
  factory DetailedWaveform.fromSamples(Float32List samples, double sampleRate,
      {int binFrames = 4, int bandFrames = 32}) {
    final n = samples.length;
    final bins = (n + binFrames - 1) ~/ binFrames;
    final mn = Int16List(bins), mx = Int16List(bins);
    for (var b = 0; b < bins; b++) {
      final from = b * binFrames, to = math.min(n, from + binFrames);
      var lo = samples[from], hi = lo;
      for (var i = from + 1; i < to; i++) {
        final s = samples[i];
        if (s < lo) lo = s;
        if (s > hi) hi = s;
      }
      mn[b] = _toInt16(lo);
      mx[b] = _toInt16(hi);
    }

    // Bands: one-pole low-passes split the signal into < 200 Hz, 200 Hz ..
    // 2 kHz and the rest; each band keeps its peak per band bin.
    final bandBins = (n + bandFrames - 1) ~/ bandFrames;
    final lowF = Float32List(bandBins), midF = Float32List(bandBins), highF = Float32List(bandBins);
    final aLow = 1 - math.exp(-2 * math.pi * 200 / sampleRate);
    final aMid = 1 - math.exp(-2 * math.pi * 2000 / sampleRate);
    var lp1 = 0.0, lp2 = 0.0;
    for (var b = 0; b < bandBins; b++) {
      final from = b * bandFrames, to = math.min(n, from + bandFrames);
      var l = 0.0, m = 0.0, h = 0.0;
      for (var i = from; i < to; i++) {
        final s = samples[i];
        lp1 += aLow * (s - lp1);
        lp2 += aMid * (s - lp2);
        final vl = lp1.abs(), vm = (lp2 - lp1).abs(), vh = (s - lp2).abs();
        if (vl > l) l = vl;
        if (vm > m) m = vm;
        if (vh > h) h = vh;
      }
      lowF[b] = l;
      midF[b] = m;
      highF[b] = h;
    }

    final mins = <Int16List>[mn], maxs = <Int16List>[mx];
    while (mins.last.length > 64) {
      final pmn = mins.last, pmx = maxs.last;
      final len = (pmn.length + 3) ~/ 4;
      final nmn = Int16List(len), nmx = Int16List(len);
      for (var j = 0; j < len; j++) {
        final a = j * 4, e = math.min(pmn.length, a + 4);
        var lo = pmn[a], hi = pmx[a];
        for (var i = a + 1; i < e; i++) {
          if (pmn[i] < lo) lo = pmn[i];
          if (pmx[i] > hi) hi = pmx[i];
        }
        nmn[j] = lo;
        nmx[j] = hi;
      }
      mins.add(nmn);
      maxs.add(nmx);
    }

    // Scale from the 99.9th percentile of ~10 ms peaks (loud masters
    // mostly reach full scale and keep their shape).
    var level = 0;
    var frames = binFrames;
    while (level + 1 < maxs.length && frames * 4 <= sampleRate / 100) {
      level++;
      frames *= 4;
    }
    final peaks = Float32List(maxs[level].length);
    for (var i = 0; i < peaks.length; i++) {
      peaks[i] = math.max(maxs[level][i], -mins[level][i]) / 32767;
    }
    final ref = _percentile(peaks, 0.999);
    final scale = ref > 1e-4 ? math.min(8.0, 1 / ref) : 1.0;

    return DetailedWaveform._(sampleRate, n, binFrames, mins, maxs, bandFrames, _bandLevels(lowF),
        _bandLevels(midF), _bandLevels(highF), scale);
  }

  static int _toInt16(double v) => (v * 32767).round().clamp(-32767, 32767);

  static double _percentile(Float32List values, double p) {
    if (values.isEmpty) return 0;
    final sorted = Float32List.fromList(values)..sort();
    return sorted[math.min(sorted.length - 1, (sorted.length * p).floor())];
  }

  /// A band's peaks as 0..255 (relative to its 99th percentile), pooled.
  static List<Uint8List> _bandLevels(Float32List peaks) {
    final ref = _percentile(peaks, 0.99);
    final k = ref > 1e-6 ? 255 / ref : 0.0;
    final base = Uint8List(peaks.length);
    for (var i = 0; i < peaks.length; i++) {
      base[i] = (peaks[i] * k).round().clamp(0, 255);
    }
    final levels = <Uint8List>[base];
    while (levels.last.length > 64) {
      final prev = levels.last;
      final next = Uint8List((prev.length + 3) ~/ 4);
      for (var i = 0; i < prev.length; i++) {
        final j = i >> 2;
        if (prev[i] > next[j]) next[j] = prev[i];
      }
      levels.add(next);
    }
    return levels;
  }

  /// Audio length covered, in ms.
  double get duration => frames / sampleRate * 1000;

  /// Fills [out] with the waveform over the audio time range [from, to) ms;
  /// false (and a silent [out]) outside the audio.
  bool column(double from, double to, WaveColumn out) {
    out
      ..min = 0
      ..max = 0
      ..low = 0
      ..mid = 0
      ..high = 0;
    final f0 = from * sampleRate / 1000, f1 = to * sampleRate / 1000;
    if (f1 <= 0 || f0 >= frames || f1 <= f0) return false;

    // The finest level whose bins are no wider than the range (at least
    // one bin even when zoomed in past level 0).
    var level = 0;
    var bin = binFrames.toDouble();
    while (level + 1 < mins.length && bin * 4 <= f1 - f0) {
      level++;
      bin *= 4;
    }
    final mn = mins[level], mx = maxs[level];
    final a = math.max(0, (f0 / bin).floor());
    final b = math.min(mn.length - 1, math.max(a, (f1 / bin).ceil() - 1));
    var lo = mn[a], hi = mx[a];
    for (var i = a + 1; i <= b; i++) {
      if (mn[i] < lo) lo = mn[i];
      if (mx[i] > hi) hi = mx[i];
    }
    final k = scale / 32767;
    out
      ..min = math.max(-1.0, lo * k)
      ..max = math.min(1.0, hi * k);

    var bl = 0;
    var bb = bandFrames.toDouble();
    while (bl + 1 < lows.length && bb * 4 <= f1 - f0) {
      bl++;
      bb *= 4;
    }
    final l = lows[bl], m = mids[bl], h = highs[bl];
    final c = math.max(0, (f0 / bb).floor());
    final d = math.min(l.length - 1, math.max(c, (f1 / bb).ceil() - 1));
    var vl = 0, vm = 0, vh = 0;
    for (var i = c; i <= d; i++) {
      if (l[i] > vl) vl = l[i];
      if (m[i] > vm) vm = m[i];
      if (h[i] > vh) vh = h[i];
    }
    out
      ..low = vl / 255
      ..mid = vm / 255
      ..high = vh / 255;
    return true;
  }
}

/// The sample rate an audio file decodes at, read from its first bytes
/// ([head] starts at the file start or right after an ID3v2 tag, see
/// [id3v2Size]): MP3, OGG Vorbis / Opus, WAV, FLAC. Null if unrecognised.
int? audioSampleRate(Uint8List head) {
  int u32le(int i) => head[i] | head[i + 1] << 8 | head[i + 2] << 16 | head[i + 3] << 24;
  bool at(int i, String s) {
    if (i < 0 || i + s.length > head.length) return false;
    for (var k = 0; k < s.length; k++) {
      if (head[i + k] != s.codeUnitAt(k)) return false;
    }
    return true;
  }

  int find(String s, int limit) {
    for (var i = 0; i + s.length <= math.min(head.length, limit); i++) {
      if (at(i, s)) return i;
    }
    return -1;
  }

  if (at(0, 'OggS')) {
    final v = find('\x01vorbis', 4096);
    if (v >= 0 && v + 16 <= head.length) return u32le(v + 12);
    if (find('OpusHead', 4096) >= 0) return 48000;
    return null;
  }
  if (at(0, 'RIFF') && at(8, 'WAVE')) {
    var i = 12;
    while (i + 8 <= head.length) {
      final size = u32le(i + 4);
      if (at(i, 'fmt ')) return i + 16 <= head.length ? u32le(i + 12) : null;
      i += 8 + size + (size & 1);
    }
    return null;
  }
  if (at(0, 'fLaC')) {
    if (head.length < 21) return null;
    return head[18] << 12 | head[19] << 4 | head[20] >> 4;
  }
  // MPEG audio: the first plausible frame header.
  for (var i = 0; i + 3 < head.length; i++) {
    if (head[i] != 0xFF || head[i + 1] & 0xE0 != 0xE0) continue;
    final version = head[i + 1] >> 3 & 3, layer = head[i + 1] >> 1 & 3;
    final bitrate = head[i + 2] >> 4, rate = head[i + 2] >> 2 & 3;
    if (version == 1 || layer == 0 || bitrate == 0 || bitrate == 15 || rate == 3) continue;
    const base = [44100, 48000, 32000];
    return switch (version) { 3 => base[rate], 2 => base[rate] ~/ 2, _ => base[rate] ~/ 4 };
  }
  return null;
}

/// Bytes taken by an ID3v2 tag at the start of [head] (0 without one).
int id3v2Size(Uint8List head) {
  if (head.length < 10 || head[0] != 0x49 || head[1] != 0x44 || head[2] != 0x33) return 0;
  final size = (head[6] & 0x7F) << 21 | (head[7] & 0x7F) << 14 | (head[8] & 0x7F) << 7 | (head[9] & 0x7F);
  final footer = head[5] & 0x10 != 0 ? 10 : 0;
  return 10 + size + footer;
}
