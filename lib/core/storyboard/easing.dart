import 'dart:math' as math;

/// osu! storyboard easing ids (0..34), as written in command lines.
///
/// Standard Penner curves; the tiny endpoint corrections osu!framework adds
/// to the expo/elastic curves are left out (they differ by < 0.001).
abstract final class StoryboardEasing {
  static const count = 35;

  static const _backC = 1.70158;
  static const _backC2 = _backC * 1.525;
  static const _bounceC = 1 / 2.75;
  static const _elasticC = 2 * math.pi / 0.3;
  static const _elasticC2 = 0.3 / 4;

  /// Eased progress for [easing] at linear progress [t] (0..1). Unknown ids
  /// are linear.
  static double apply(int easing, double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    switch (easing) {
      case 1 || 4: // Out, OutQuad
        return t * (2 - t);
      case 2 || 3: // In, InQuad
        return t * t;
      case 5:
        return t < 0.5 ? t * t * 2 : 1 - _p(1 - t, 2) * 2;
      case 6:
        return _p(t, 3);
      case 7:
        return 1 - _p(1 - t, 3);
      case 8:
        return t < 0.5 ? _p(t, 3) * 4 : 1 - _p(1 - t, 3) * 4;
      case 9:
        return _p(t, 4);
      case 10:
        return 1 - _p(1 - t, 4);
      case 11:
        return t < 0.5 ? _p(t, 4) * 8 : 1 - _p(1 - t, 4) * 8;
      case 12:
        return _p(t, 5);
      case 13:
        return 1 - _p(1 - t, 5);
      case 14:
        return t < 0.5 ? _p(t, 5) * 16 : 1 - _p(1 - t, 5) * 16;
      case 15:
        return 1 - math.cos(t * math.pi / 2);
      case 16:
        return math.sin(t * math.pi / 2);
      case 17:
        return 0.5 - 0.5 * math.cos(math.pi * t);
      case 18:
        return _pow2(10 * (t - 1));
      case 19:
        return 1 - _pow2(-10 * t);
      case 20:
        return t < 0.5
            ? 0.5 * _pow2(20 * t - 10)
            : 1 - 0.5 * _pow2(-20 * t + 10);
      case 21:
        return 1 - math.sqrt(1 - t * t);
      case 22:
        return math.sqrt(1 - _p(t - 1, 2));
      case 23:
        final u = t * 2;
        return u < 1 ? 0.5 - 0.5 * math.sqrt(1 - u * u) : 0.5 * math.sqrt(1 - _p(u - 2, 2)) + 0.5;
      case 24:
        return -_pow2(-10 + 10 * t) * math.sin((1 - _elasticC2 - t) * _elasticC);
      case 25:
        return _pow2(-10 * t) * math.sin((t - _elasticC2) * _elasticC) + 1;
      case 26:
        return _pow2(-10 * t) * math.sin((0.5 * t - _elasticC2) * _elasticC) + 1;
      case 27:
        return _pow2(-10 * t) * math.sin((0.25 * t - _elasticC2) * _elasticC) + 1;
      case 28:
        final u = t * 2;
        if (u < 1) return -0.5 * _pow2(-10 + 10 * u) * math.sin((1 - _elasticC2 * 1.5 - u) * _elasticC / 1.5);
        return 0.5 * _pow2(-10 * (u - 1)) * math.sin((u - 1 - _elasticC2 * 1.5) * _elasticC / 1.5) + 1;
      case 29:
        return t * t * ((_backC + 1) * t - _backC);
      case 30:
        final u = t - 1;
        return u * u * ((_backC + 1) * u + _backC) + 1;
      case 31:
        final u = t * 2;
        if (u < 1) return 0.5 * u * u * ((_backC2 + 1) * u - _backC2);
        final v = u - 2;
        return 0.5 * (v * v * ((_backC2 + 1) * v + _backC2) + 2);
      case 32:
        return 1 - _outBounce(1 - t);
      case 33:
        return _outBounce(t);
      case 34:
        return t < 0.5 ? 0.5 - 0.5 * _outBounce(1 - t * 2) : _outBounce((t - 0.5) * 2) * 0.5 + 0.5;
      default:
        return t;
    }
  }

  static double _pow2(double x) => math.pow(2, x).toDouble();

  static double _p(double x, int n) {
    var r = x;
    for (var i = 1; i < n; i++) {
      r *= x;
    }
    return r;
  }

  static double _outBounce(double t) {
    if (t < _bounceC) return 7.5625 * t * t;
    if (t < 2 * _bounceC) {
      final u = t - 1.5 * _bounceC;
      return 7.5625 * u * u + 0.75;
    }
    if (t < 2.5 * _bounceC) {
      final u = t - 2.25 * _bounceC;
      return 7.5625 * u * u + 0.9375;
    }
    final u = t - 2.625 * _bounceC;
    return 7.5625 * u * u + 0.984375;
  }
}
