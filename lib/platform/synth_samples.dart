import 'dart:math' as math;
import 'dart:typed_data';

/// Built-in hitsounds, synthesized at startup so the app ships no
/// third-party (osu! skin) samples. Each bank imitates the character of
/// osu!'s default skin (measured, not copied — see [_normal], [_soft],
/// [_drum]): `hitnormal`, `hitwhistle`, `hitfinish`, `hitclap`, `slidertick`
/// and two seamless loops for slider bodies (`sliderslide`,
/// `sliderwhistle`). normal and soft are different instruments, not just
/// louder / quieter (e.g. normal whistle = a pea whistle, soft whistle = a
/// metallic "ching").
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
    return bank == 'soft' ? _soft(name, noise) : _normal(name, noise);
  }

  // The banks follow the partials, decay times, envelopes and peak levels
  // of osu! stable's default skin samples (measured, not copied; peaks
  // scaled by 0.6). Loops last exactly 0.5 s and use whole numbers of
  // periods (even Hz) so they are seamless.

  /// normal: a short pop (the app's original, kept by request), a pea whistle, a
  /// deep crash, a short handclap, a bright metallic tick, a resonant
  /// noise slide and a sustained whistle.
  static Float64List _normal(String name, double Function() noise) {
    switch (name) {
      case 'hitnormal':
        // The original short pop (kept by request, not matched to the
        // skin): a 520 Hz thump plus a noise click.
        return _render(0.09, (t, i) {
          final body = math.sin(2 * math.pi * 520 * t) * math.exp(-t * 45);
          final click = noise() * math.exp(-t * 250) * 0.6;
          return body * 0.8 + click;
        });
      case 'hitwhistle':
        // Held for ~185 ms, then cut off, leaving a faint tail.
        return _normalize(_render(0.5, (t, i) {
          final env = t < 0.185
              ? math.min(1.0, t / 0.004) * (1 - 0.15 * t / 0.185)
              : 0.79 * math.exp(-(t - 0.185) / 0.008) + 0.06 * math.exp(-(t - 0.185) / 0.25);
          return _whistle(2668, 80, t) * env;
        }), 0.34);
      case 'hitfinish':
        // A 58→50 Hz boom held ~220 ms under a crash whose 4–10 kHz
        // partials ring ~0.8 s.
        var p = 0.0;
        final crash = _ring([
          (4412, 0.5, 0.35), (4710, 0.7, 0.26), (8345, 0.5, 0.32), (8441, 0.6, 0.17),
          (8712, 0.5, 0.33), (9971, 0.6, 0.33), (10238, 0.6, 0.25),
        ], noise);
        final hp = _Biquad.highPass(3500, 0.7), lp = _Biquad.lowPass(12000, 0.7);
        return _normalize(_render(1.8, (t, i) {
          p += (50 + 8 * math.exp(-t / 0.15)) / sampleRate;
          final boom = (math.sin(2 * math.pi * p) + 0.28 * math.sin(2 * math.pi * 83 * t)) *
              math.min(1.0, t / 0.01) *
              (t < 0.22 ? 1.0 : math.exp(-(t - 0.22) / 0.05));
          final stick = noise() * math.exp(-t / 0.01) * 0.4;
          final cymbal = (crash(t) * 0.6 + lp.process(hp.process(noise())) * 1.5) * math.min(1.0, t / 0.03) * math.exp(-t / 0.45);
          return boom + stick + cymbal;
        }), 0.32);
      case 'hitclap':
        // ~100 ms: three quick claps through 0.9–1.8 kHz resonances, cut
        // off sharply.
        return _normalize(_clap(0.11, [(1211, 2, 1), (967, 3, 0.6), (1757, 4, 0.5), (1450, 4, 0.4)], noise, (t) {
          final ms = t * 1000;
          final burst = 0.6 + 0.4 * math.exp(-(ms % 12) / 4);
          return ms < 60 ? burst : burst * math.exp(-(ms - 60) / 12);
        }), 0.6);
      case 'slidertick':
        return _normalize(_partials(0.48, 0.002, [
          (7433, 0.75, 0.058), (7521, 0.78, 0.063), (7578, 0.72, 0.05), (7618, 1, 0.058), (7656, 0.76, 0.056),
          (7726, 0.97, 0.063), (9971, 0.93, 0.06), (12554, 0.78, 0.067), (12610, 0.8, 0.063), (12683, 0.82, 0.042),
        ], noise), 0.29);
      case 'sliderslide':
        // Broadband noise (rolled off above 8 kHz) with 180–785 Hz and
        // 2.2 kHz resonances.
        final lp = _Biquad.lowPass(9000, 0.7);
        final res = [
          for (final (f, a) in [(180.0, 0.7), (227.0, 0.6), (353.0, 0.6), (419.0, 0.7), (500.0, 1.2), (785.0, 0.7), (2194.0, 0.3)])
            (_Biquad.bandPass(f, 15), a * 4),
        ];
        return _loop(_normalize(_render(0.55, (t, i) {
          final n = noise();
          var s = lp.process(n);
          for (final (bp, a) in res) {
            s += bp.process(n) * a;
          }
          return s;
        }), 0.21));
      case 'sliderwhistle':
      default:
        return _normalize(_render(0.5, (t, i) => _whistle(2622, 80, t), fadeOut: false), 0.19);
    }
  }

  /// soft: a high, glassy tap, a metallic "ching", a knock into a bright
  /// shimmering cymbal, a woody double clap, a high tick, a low humming
  /// slide and a shimmering metallic drone.
  static Float64List _soft(String name, double Function() noise) {
    switch (name) {
      case 'hitnormal':
        final ring = _ring([
          (5356, 0.65, 0.12), (6776, 0.45, 0.15), (6922, 1, 0.12), (8249, 0.45, 0.1), (8465, 0.45, 0.13),
          (8675, 0.55, 0.12), (8758, 1, 0.13), (8891, 0.45, 0.12), (9448, 0.5, 0.19), (13828, 0.45, 0.12),
        ], noise);
        final hp = _Biquad.highPass(9000, 0.7);
        return _normalize(_render(0.8, (t, i) {
          final n = noise();
          return (ring(t) + n * 0.4 * math.exp(-t / 0.15)) * (1 - math.exp(-t / 0.015)) + hp.process(n) * math.exp(-t / 0.008) * 2;
        }), 0.2);
      case 'hitwhistle':
        // A 7.1 kHz cluster and a 2.7 kHz partial: rings ~0.2 s, faint tail.
        return _normalize(_partials(0.8, 0.006, [
          (7100, 1, 0.1), (7055, 0.8, 0.1), (7026, 0.42, 0.08), (7360, 0.53, 0.05), (7404, 0.4, 0.05),
          (7537, 0.48, 0.1), (6165, 0.4, 0.12), (2681, 0.57, 0.09), (10701, 0.51, 0.06), (10783, 0.46, 0.07),
          (7048, 0.1, 0.35), (2690, 0.06, 0.3), (10765, 0.25, 0.2), (10794, 0.2, 0.2), (9483, 0.15, 0.2),
        ], noise), 0.41);
      case 'hitfinish':
        // 0.45–1 kHz knock, then 3.5–9 kHz partials and a broad wash swell
        // and ring ~0.45 s.
        final knock = _ring([(614, 1, 0.02), (457, 0.6, 0.02), (787, 0.7, 0.02), (1008, 0.55, 0.02)], noise);
        final ring = _ring([
          (3570, 0.8, 0.27), (4046, 0.9, 0.26), (4078, 1, 0.21), (4605, 0.7, 0.24), (4763, 0.6, 0.11),
          (4971, 0.6, 0.26), (5401, 0.6, 0.14), (5444, 0.6, 0.19), (8006, 0.8, 0.21), (8905, 0.55, 0.21),
        ], noise);
        final hp = _Biquad.highPass(300, 0.7), lp = _Biquad.lowPass(11000, 0.7);
        return _normalize(_render(1.2, (t, i) {
          final swell = 1 - math.exp(-t / 0.02);
          return knock(t) * math.min(1.0, t / 0.001) * 2.5 +
              ring(t) * swell +
              lp.process(hp.process(noise())) * swell * math.exp(-t / 0.3) * 0.9;
        }), 0.4);
      case 'hitclap':
        // Woodier (506 Hz) clap, with a quieter second clap at 115 ms.
        return _normalize(_clap(0.22, [(540, 6, 1.2), (666, 3, 1.5), (1133, 3, 0.6), (1307, 3, 0.6), (1773, 4, 0.45), (2200, 3, 0.3)], noise, (t) {
          final ms = t * 1000;
          final first = ms < 50 ? 0.6 + 0.4 * math.exp(-(ms % 20) / 5) : 0.97 * math.exp(-(ms - 50) / 15) + 0.03 * math.exp(-(ms - 50) / 40);
          final second = ms < 115 ? 0.0 : 0.22 * math.exp(-(ms - 115) / 8);
          return first + second;
        }), 0.6);
      case 'slidertick':
        return _normalize(_partials(0.6, 0.002, [
          (4807, 0.45, 0.08), (5346, 0.48, 0.035), (7254, 0.53, 0.06), (7360, 0.94, 0.05), (7404, 0.65, 0.045),
          (7447, 0.5, 0.035), (7537, 1, 0.095), (7576, 0.68, 0.08), (13033, 0.46, 0.08), (13068, 0.52, 0.09),
        ], noise), 0.15);
      case 'sliderslide':
        // A 238 Hz hum with overtones and a 16 Hz flutter over faint noise.
        final hum = _render(0.5, (t, i) {
          var s = 0.0;
          for (final (f, a) in [(238.0, 1.0), (334.0, 0.27), (448.0, 0.18), (642.0, 0.11), (132.0, 0.15)]) {
            s += a * math.sin(2 * math.pi * f * t);
          }
          return s * (0.65 + 0.35 * math.sin(2 * math.pi * 16 * t));
        }, fadeOut: false);
        final lp = _Biquad.lowPass(12000, 0.7);
        final hiss = _loop(_render(0.55, (t, i) => lp.process(noise()) * 0.25));
        for (var i = 0; i < hum.length; i++) {
          hum[i] += hiss[i];
        }
        return _normalize(hum, 0.16);
      case 'sliderwhistle':
      default:
        // Close partials beat against each other: a shimmering drone over
        // faint noise.
        final drone = _render(0.5, (t, i) {
          var s = 0.0;
          for (final (f, a) in [
            (3772.0, 0.47), (4564.0, 1.0), (4908.0, 0.98), (5062.0, 0.68), (5310.0, 0.55), (5548.0, 0.54),
            (6044.0, 0.52), (6160.0, 0.74), (7216.0, 0.54), (8398.0, 0.46), (746.0, 0.2),
          ]) {
            s += a * math.sin(2 * math.pi * f * t + f);
          }
          return s;
        }, fadeOut: false);
        final hiss = _loop(_render(0.55, (t, i) => noise() * 0.1));
        for (var i = 0; i < drone.length; i++) {
          drone[i] += hiss[i];
        }
        return _normalize(drone, 0.1);
    }
  }

  /// A pea whistle: a tone at [fc] that the pea rattles at [fm] Hz (FM plus
  /// a little AM, so the sidebands lean low), with weak 2nd/3rd harmonics.
  static double _whistle(double fc, double fm, double t) {
    final m = 2 * math.pi * fm * t;
    final ph = 2 * math.pi * fc * t + 0.9 * math.sin(m);
    return (math.sin(ph) + 0.14 * math.sin(2 * ph) + 0.1 * math.sin(3 * ph)) * (1 - 0.3 * math.cos(m));
  }

  /// Sum of exponentially decaying sine partials (Hz, amplitude, decay time
  /// constant in s), with random start phases.
  static double Function(double t) _ring(List<(double, double, double)> partials, double Function() noise) {
    final phase = [for (final _ in partials) noise() * math.pi];
    return (t) {
      var s = 0.0;
      for (var k = 0; k < partials.length; k++) {
        final (f, a, tau) = partials[k];
        s += a * math.sin(2 * math.pi * f * t + phase[k]) * math.exp(-t / tau);
      }
      return s;
    };
  }

  /// [_ring] with a linear [attack] (s), rendered for [seconds].
  static Float64List _partials(double seconds, double attack, List<(double, double, double)> partials, double Function() noise) {
    final ring = _ring(partials, noise);
    return _render(seconds, (t, i) => ring(t) * math.min(1.0, t / attack));
  }

  /// Noise through band-passes (Hz, Q, gain) under the envelope [env].
  static Float64List _clap(double seconds, List<(double, double, double)> bands, double Function() noise, double Function(double t) env) {
    final bps = [for (final (f, q, a) in bands) (_Biquad.bandPass(f, q), a)];
    return _render(seconds, (t, i) {
      final n = noise();
      var s = 0.0;
      for (final (bp, a) in bps) {
        s += bp.process(n) * a;
      }
      return s * env(t);
    });
  }

  /// drum: a snare-like hit (thump plus a ringing shimmer), a woody knock
  /// with metallic overtones, deep toms under a short noise burst for
  /// finish/clap, a short 210 Hz tom tick, a pulsing 230 Hz hum and the
  /// normal bank's whistle loop (stable ships the same file for both).
  static Float64List _drum(String name, double Function() noise) {
    switch (name) {
      case 'hitnormal':
        // 208/180 Hz thump, then 4–14 kHz partials that ring ~0.4 s.
        final thump = _ring([
          (208, 1, 0.028), (180, 0.6, 0.028), (230, 0.7, 0.02), (330, 0.45, 0.05), (488, 0.35, 0.05), (820, 0.2, 0.04), (1748, 0.2, 0.07),
          (207, 0.04, 0.25), (330, 0.04, 0.2), (488, 0.04, 0.25), (612, 0.03, 0.25), (1748, 0.03, 0.3),
        ], noise);
        final low = _Biquad.highPass(140, 0.7);
        final ring = _ring([
          (4286, 0.1, 0.09), (4770, 0.1, 0.13), (5355, 0.18, 0.14), (5421, 0.15, 0.15), (5949, 0.12, 0.13), (6776, 0.12, 0.13),
          (6920, 0.18, 0.15), (7681, 0.12, 0.12), (8342, 0.12, 0.12), (8752, 0.18, 0.1), (9436, 0.12, 0.18), (13876, 0.1, 0.1),
        ], noise);
        final hp = _Biquad.highPass(9000, 0.7);
        return _normalize(_render(0.8, (t, i) {
          final n = noise();
          return low.process(thump(t) * math.min(1.0, t / 0.001)) +
              n * math.exp(-t / 0.003) * 0.6 +
              (ring(t) + n * 0.08 * math.exp(-t / 0.12)) * (1 - math.exp(-t / 0.015)) +
              hp.process(n) * 0.45 * math.exp(-t / 0.14);
        }), 0.6);
      case 'hitwhistle':
        // A 400–700 Hz knock with 1–1.5 kHz overtones over a bright hiss.
        final hp = _Biquad.highPass(5000, 0.7);
        final knock = _ring([
          (206, 0.3, 0.085), (402, 0.3, 0.096), (422, 0.55, 0.1), (452, 1, 0.08), (486, 0.35, 0.067), (506, 0.35, 0.07),
          (542, 0.5, 0.08), (600, 0.6, 0.055), (646, 0.9, 0.07), (692, 0.4, 0.09), (974, 0.35, 0.08), (1018, 0.5, 0.095),
          (1486, 0.45, 0.06), (1552, 0.55, 0.048), (3940, 0.5, 0.08),
        ], noise);
        return _normalize(_render(0.4, (t, i) {
          return knock(t) * math.min(1.0, t / 0.002) + hp.process(noise()) * 1.5 * math.exp(-t / 0.09);
        }), 0.49);
      case 'hitfinish':
        return _drumHit(0.65, noise,
            kick: 62, kickFrom: 73, knock: [(112, 0.4, 0.03), (340, 0.25, 0.05), (544, 0.07, 0.04)],
            tom: (t) => 93 + 28 * math.exp(-t / 0.14), tomGain: 0.3, tomDecay: 0.25,
            burst: (t) => 1.8 * math.exp(-t / 0.006) + 1.1 * (t < 0.06 ? 1.0 : math.exp(-(t - 0.06) / 0.03)), burstEnd: 0.15, drive: 1.5, peak: 0.5);
      case 'hitclap':
        return _drumHit(0.65, noise,
            kick: 60, kickFrom: 88, knock: [(190, 1.2, 0.05), (316, 0.6, 0.03), (486, 0.8, 0.018), (1202, 0.3, 0.04)],
            tom: (t) => 117 + 33 * math.exp(-t / 0.12), tomGain: 0.35, tomDecay: 0.28,
            burst: (t) => 2.1 * math.exp(-t / 0.008) + 1.5 * math.exp(-t / 0.05), burstEnd: 0.13, drive: 1.5, peak: 0.5);
      case 'slidertick':
        // A 210/238 Hz tom (beating) with a stick noise peaking at ~25 ms.
        final tom = _ring([
          (210, 1, 0.052), (238, 0.85, 0.055), (224, 0.8, 0.012), (338, 0.4, 0.014), (154, 0.2, 0.045), (290, 0.12, 0.094),
          (568, 0.18, 0.08), (598, 0.12, 0.029), (700, 0.08, 0.06), (814, 0.08, 0.06), (976, 0.07, 0.05),
        ], noise);
        final hp = _Biquad.highPass(1000, 0.7), lp = _Biquad.lowPass(9000, 0.7);
        return _normalize(_render(0.39, (t, i) {
          final stick = math.min(1.0, t / 0.02) * math.exp(-math.max(0.0, t - 0.02) / 0.035);
          return _tanh(0.6 * (tom(t) * math.min(1.0, t / 0.003) + lp.process(hp.process(noise())) * 0.8 * stick));
        }), 0.21);
      case 'sliderslide':
        // Two tones 20 Hz apart (plus sidebands and overtones) pulse at
        // 20 Hz over faint broadband noise.
        final hum = _render(0.5, (t, i) {
          var s = 0.0;
          for (final (f, a) in [
            (220.0, 1.0), (240.0, 0.65), (200.0, 0.25), (260.0, 0.25), (110.0, 0.06), (130.0, 0.14), (166.0, 0.14),
            (300.0, 0.07), (334.0, 0.22), (360.0, 0.09), (458.0, 0.18), (480.0, 0.14), (640.0, 0.1),
          ]) {
            s += a * math.sin(2 * math.pi * f * t + f);
          }
          return s;
        }, fadeOut: false);
        final lp = _Biquad.lowPass(8000, 0.7);
        final hiss = _loop(_render(0.55, (t, i) => lp.process(noise()) * 0.8));
        for (var i = 0; i < hum.length; i++) {
          hum[i] += hiss[i];
        }
        return _normalize(hum, 0.22);
      case 'sliderwhistle':
      default:
        return _normal('sliderwhistle', noise);
    }
  }

  /// A drum hit: a short [kick] (gliding down from [kickFrom] Hz, gone by
  /// ~70 ms), a [knock] of fast-decaying partials, a [tom] whose pitch
  /// glides down and decays with [tomDecay] (s), and a bright noise
  /// [burst] cut off at [burstEnd] (s).
  static Float64List _drumHit(double seconds, double Function() noise,
      {required double kick, required double kickFrom, required List<(double, double, double)> knock,
      required double Function(double t) tom, required double tomGain, required double tomDecay,
      required double Function(double t) burst, required double burstEnd, required double drive, required double peak}) {
    final knocks = _ring(knock, noise);
    final lp = _Biquad.lowPass(4500, 0.6), hp = _Biquad.highPass(800, 0.7);
    var pk = 0.0, pt = 0.0;
    // Driven into a soft clip, as the dense, loud originals are.
    return _normalize(_render(seconds, (t, i) {
      pk += (kick + (kickFrom - kick) * math.exp(-t / 0.015)) / sampleRate;
      pt += tom(t) / sampleRate;
      final kickEnv = math.min(1.0, t / 0.01) * (t < 0.045 ? 1.0 : math.exp(-(t - 0.045) / 0.012));
      final tomEnv = math.min(1.0, t / 0.02) * math.exp(-t / tomDecay);
      final n = noise();
      final noiseEnv = burst(t) * (t < burstEnd ? 1.0 : math.exp(-(t - burstEnd) / 0.004));
      final x = _tanh(3 * math.sin(2 * math.pi * pk)) / _tanh(3) * kickEnv +
          (math.sin(2 * math.pi * pt) + 0.15 * math.sin(4 * math.pi * pt) + 0.05 * math.sin(6 * math.pi * pt) + 0.03 * math.sin(10 * math.pi * pt)) * tomEnv * tomGain +
          knocks(t) * math.min(1.0, t / 0.001) +
          (hp.process(lp.process(n)) + n * 0.1) * noiseEnv * 0.5;
      return _tanh(drive * x);
    }), peak);
  }

  /// Soft clip.
  static double _tanh(double x) => 1 - 2 / (math.exp(2 * x) + 1);

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

/// RBJ biquad: band-pass (constant 0 dB peak gain), high-pass or low-pass.
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

  _Biquad.lowPass(double f, double q) {
    final w = 2 * math.pi * f / SynthSamples.sampleRate, alpha = math.sin(w) / (2 * q), a0 = 1 + alpha, c = math.cos(w);
    _b0 = (1 - c) / 2 / a0;
    _b1 = (1 - c) / a0;
    _b2 = (1 - c) / 2 / a0;
    _a1 = -2 * c / a0;
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
