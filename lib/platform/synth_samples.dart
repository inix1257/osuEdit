import 'dart:math' as math;
import 'dart:typed_data';

/// Built-in hitsounds, synthesized at startup so the app ships no
/// third-party (osu! skin) samples. The normal / soft banks are deliberately
/// simple and only need to be distinguishable (the drum bank imitates
/// osu!'s default, see [_drum]): per bank a click
/// (`hitnormal`), a tone (`hitwhistle`), a long noise wash (`hitfinish`), a
/// noise burst (`hitclap`), a short quiet blip (`slidertick`) and two
/// seamless loops for slider bodies (`sliderslide`, `sliderwhistle`).
/// Plus the Timing mode metronome: `metronome-accent` (first beat of a
/// measure) and `metronome-beat`.
///
/// Output: 16-bit mono PCM WAV at [sampleRate].
abstract final class SynthSamples {
  static const sampleRate = 44100;
  static const banks = ['normal', 'soft', 'drum'];
  static const names = ['hitnormal', 'hitwhistle', 'hitfinish', 'hitclap', 'slidertick', 'sliderslide', 'sliderwhistle'];

  /// Bank of the metronome clicks (not a hitsound bank: no beatmap sample
  /// can name it).
  static const metronomeBank = 'metronome';
  static const metronomeNames = ['accent', 'beat'];

  /// `bank-name` → WAV bytes for every combination, and the metronome.
  static Map<String, Uint8List> all() => {
        for (final b in banks)
          for (final n in names) '$b-$n': wav(generate(b, n)),
        for (final n in metronomeNames) '$metronomeBank-$n': wav(metronome(accent: n == 'accent')),
      };

  /// A short woodblock-like click; the accent is higher and louder.
  static Float64List metronome({required bool accent}) {
    final f = accent ? 1760.0 : 1320.0;
    return _render(0.06, (t, i) {
      final env = math.min(1.0, t * 2000) * math.exp(-t * 70);
      return (math.sin(2 * math.pi * f * t) + 0.3 * math.sin(4 * math.pi * f * t)) * env * (accent ? 0.75 : 0.55);
    });
  }

  static Float64List generate(String bank, String name) {
    // Deterministic noise so the samples are identical on every run.
    final rnd = math.Random('$bank-$name'.codeUnits.fold<int>(17, (h, c) => (h * 31 + c) & 0x7fffffff));
    double noise() => rnd.nextDouble() * 2 - 1;
    if (bank == 'drum') return _drum(name, noise);
    final soft = bank == 'soft';

    switch (name) {
      case 'hitnormal':
        // Pitched thump plus a short noise transient.
        final f = soft ? 330.0 : 520.0;
        return _render(0.09, (t, i) {
          final body = math.sin(2 * math.pi * f * t) * math.exp(-t * 45);
          final click = noise() * math.exp(-t * (soft ? 400 : 250)) * (soft ? 0.3 : 0.6);
          return body * 0.8 + click;
        });
      case 'hitwhistle':
        final f = soft ? 1250.0 : 1750.0;
        return _render(0.22, (t, i) {
          final vib = 1 + 0.01 * math.sin(2 * math.pi * 30 * t);
          final env = math.min(1.0, t * 200) * math.exp(-t * 14);
          return math.sin(2 * math.pi * f * vib * t) * env * 0.6;
        });
      case 'hitfinish':
        var prev = 0.0;
        return _render(0.9, (t, i) {
          // First difference of white noise = bright, cymbal-like wash.
          final n = noise();
          final hp = n - prev;
          prev = n;
          return hp * math.exp(-t * 4.5) * (soft ? 0.3 : 0.45);
        });
      case 'slidertick':
        final f = soft ? 1500.0 : 2200.0;
        return _render(0.05, (t, i) => math.sin(2 * math.pi * f * t) * math.exp(-t * 90) * 0.35);
      case 'sliderslide':
        // Low filtered noise; 0.5 s, faded at both ends by _loop so the seam
        // is inaudible.
        var lp = 0.0;
        return _loop(_render(0.5, (t, i) {
          lp += (noise() - lp) * (soft ? 0.03 : 0.08);
          return lp * 1.6;
        }));
      case 'sliderwhistle':
        // Whole number of periods in 0.5 s, so the loop is seamless.
        final f = soft ? 1250.0 : 1750.0;
        return _render(0.5, (t, i) => math.sin(2 * math.pi * f * t) * 0.3, fadeOut: false);
      case 'hitclap':
      default:
        var lp = 0.0;
        return _render(0.14, (t, i) {
          // Three quick bursts, then a decaying tail; mildly low-passed.
          final ms = t * 1000;
          final burst = ms < 30 ? (math.exp(-(ms % 10) / 2.5)) : math.exp(-(ms - 30) / 35);
          lp += (noise() - lp) * (soft ? 0.35 : 0.6);
          return lp * burst * 0.7;
        });
    }
  }

  /// The drum bank, shaped after the band envelopes of osu!'s default drum
  /// samples (measured, not copied), then tuned by ear on the phone:
  /// `hitclap`/`hitfinish` a deep boom (~82→70 Hz / ~67→55 Hz) under a
  /// short noise snap (longer for finish), `hitwhistle` a closed hi-hat,
  /// `hitnormal` the original simple thump, `slidertick` a
  /// short 210 Hz tom, and band-passed noise loops for the slider body.
  static Float64List _drum(String name, double Function() noise) {
    // Phase accumulators, so the pitch glides stay continuous.
    var p1 = 0.0, p2 = 0.0, prev = 0.0;
    // Bright noise: white plus its first difference (tilted up ~3 dB/oct).
    double hiss() {
      final n = noise(), d = n - prev;
      prev = n;
      return n * 0.35 + d * 0.4;
    }

    // One sample of a tone at frequency f (may change per sample) with a
    // linear attack.
    double tone(double f, double attack, double t, {bool second = false}) {
      final phase = second ? (p2 += f / sampleRate) : (p1 += f / sampleRate);
      return math.sin(2 * math.pi * phase) * math.min(1.0, t / attack);
    }

    switch (name) {
      case 'hitnormal':
        // The original synthetic drum thump (kept by request).
        return _render(0.16, (t, i) {
          final f = 160 * math.exp(-t * 18) + 50;
          final body = math.sin(2 * math.pi * f * t) * math.exp(-t * 22);
          final click = noise() * math.exp(-t * 250) * 0.6;
          return body * 0.8 + click;
        });
      case 'hitclap':
        return _normalize(_render(0.55, (t, i) {
          final knock = math.sin(2 * math.pi * 120 * t) * math.exp(-t / 0.015) * 0.6;
          final boom = tone(70 + 12 * math.exp(-t * 15), 0.035, t) * math.min(1.0, t / 0.035) * math.exp(-t / 0.14);
          final snap = hiss() * (t < 0.03 ? 1.0 : math.exp(-(t - 0.03) / 0.02)) * 0.4;
          return knock + boom + snap;
        }), 0.6);
      case 'hitfinish':
        return _normalize(_render(0.8, (t, i) {
          final knock = math.sin(2 * math.pi * 110 * t) * math.exp(-t / 0.015) * 0.5;
          final boom = tone(55 + 12 * math.exp(-t * 12), 0.04, t) * math.min(1.0, t / 0.04) * (0.5 * math.exp(-t / 0.06) + 0.5 * math.exp(-t / 0.2));
          final wash = hiss() * (t < 0.06 ? 1.0 : math.exp(-(t - 0.06) / 0.04)) * 0.3;
          return knock + boom * 1.2 + wash;
        }), 0.6);
      case 'hitwhistle':
        // Closed hi-hat, 808 style: six detuned square waves plus noise,
        // high-passed so only the metallic sizzle is left.
        const metal = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0];
        final hp1 = _Biquad.highPass(6000, 0.7), hp2 = _Biquad.highPass(6000, 0.7);
        return _normalize(_render(0.3, (t, i) {
          var sq = 0.0;
          for (final f in metal) {
            sq += math.sin(2 * math.pi * f * 1.6 * t) >= 0 ? 1 : -1;
          }
          final x = hp2.process(hp1.process(sq / 6 * 0.7 + noise() * 0.5));
          return x * math.min(1.0, t / 0.001) * (math.exp(-t / 0.03) + 0.12 * math.exp(-t / 0.12));
        }), 0.6);
      case 'slidertick':
        return _normalize(_render(0.15, (t, i) {
          final body = math.sin(2 * math.pi * 210 * t) * math.min(1.0, t / 0.002) * math.exp(-t / 0.025);
          return body + hiss() * math.exp(-t / 0.01) * 0.5;
        }), 0.6);
      case 'sliderslide':
        final bp = _Biquad.bandPass(750, 0.7);
        return _loop(_render(0.55, (t, i) => bp.process(noise()) * 0.45));
      case 'sliderwhistle':
      default:
        final lo = _Biquad.bandPass(2800, 6), hi = _Biquad.bandPass(4600, 6);
        return _loop(_render(0.55, (t, i) {
          final n = noise();
          return (lo.process(n) + hi.process(n) * 0.8) * 0.55;
        }));
    }
  }

  /// Scales [x] so its peak is [peak].
  static Float64List _normalize(Float64List x, double peak) {
    var m = 0.0;
    for (final v in x) {
      m = math.max(m, v.abs());
    }
    if (m == 0) return x;
    for (var i = 0; i < x.length; i++) {
      x[i] *= peak / m;
    }
    return x;
  }

  /// Crossfades the last 50 ms into the start so [x] loops without a click
  /// (the result is 50 ms shorter).
  static Float64List _loop(Float64List x) {
    const fade = sampleRate ~/ 20;
    final n = x.length - fade;
    final out = Float64List.sublistView(Float64List.fromList(x), 0, n);
    for (var i = 0; i < fade; i++) {
      final a = i / fade;
      out[i] = x[i] * a + x[n + i] * (1 - a);
    }
    return Float64List.fromList(out);
  }

  static Float64List _render(double seconds, double Function(double t, int i) f, {bool fadeOut = true}) {
    final n = (seconds * sampleRate).round();
    final out = Float64List(n);
    for (var i = 0; i < n; i++) {
      out[i] = f(i / sampleRate, i);
    }
    if (!fadeOut) return out;
    // Short fade-out so nothing clicks at the end.
    final fade = math.min(n, sampleRate ~/ 200);
    for (var i = 0; i < fade; i++) {
      out[n - 1 - i] *= i / fade;
    }
    return out;
  }

  static Uint8List wav(Float64List samples) {
    final dataLen = samples.length * 2;
    final b = ByteData(44 + dataLen);
    void str(int at, String s) {
      for (var i = 0; i < s.length; i++) {
        b.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    b.setUint32(4, 36 + dataLen, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    b.setUint32(16, 16, Endian.little); // PCM chunk size
    b.setUint16(20, 1, Endian.little); // PCM
    b.setUint16(22, 1, Endian.little); // mono
    b.setUint32(24, sampleRate, Endian.little);
    b.setUint32(28, sampleRate * 2, Endian.little); // byte rate
    b.setUint16(32, 2, Endian.little); // block align
    b.setUint16(34, 16, Endian.little); // bits
    str(36, 'data');
    b.setUint32(40, dataLen, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      final v = (samples[i].clamp(-1.0, 1.0) * 32767).round();
      b.setInt16(44 + i * 2, v, Endian.little);
    }
    return b.buffer.asUint8List();
  }
}

/// RBJ biquad: band-pass (constant 0 dB peak gain) or high-pass.
class _Biquad {
  _Biquad.bandPass(double f, double q) {
    final w = 2 * math.pi * f / SynthSamples.sampleRate, alpha = math.sin(w) / (2 * q), a0 = 1 + alpha;
    _b0 = alpha / a0;
    _b1 = 0;
    _b2 = -alpha / a0;
    _a1 = -2 * math.cos(w) / a0;
    _a2 = (1 - alpha) / a0;
  }

  _Biquad.highPass(double f, double q) {
    final w = 2 * math.pi * f / SynthSamples.sampleRate, alpha = math.sin(w) / (2 * q), a0 = 1 + alpha, c = math.cos(w);
    _b0 = (1 + c) / 2 / a0;
    _b1 = -(1 + c) / a0;
    _b2 = (1 + c) / 2 / a0;
    _a1 = -2 * math.cos(w) / a0;
    _a2 = (1 - alpha) / a0;
  }

  late final double _b0, _b1, _b2, _a1, _a2;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  double process(double x) {
    final y = _b0 * x + _b1 * _x1 + _b2 * _x2 - _a1 * _y1 - _a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }
}
