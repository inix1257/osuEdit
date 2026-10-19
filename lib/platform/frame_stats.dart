import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Frame-time logging for profiling on a phone (`dumpsys gfxinfo` sees no
/// Flutter frames). Off unless built with `--dart-define=OSUEDIT_FRAMESTATS=true`;
/// then every [_window] it prints one `FRAMESTATS` line to logcat
/// (`adb logcat -s flutter`): frame count, build / raster p50 · p90 · max
/// (ms), frames over the display's budget, frames the display had to repeat
/// (`dropped`), the UI-thread frames over 6 ms (`buildSpikes`, with their
/// vsync time: a regular period points at GC) and, in the editor, how
/// unevenly the playback time steps from frame to frame (`jitter`).
abstract final class FrameStats {
  static const enabled = bool.fromEnvironment('OSUEDIT_FRAMESTATS');
  static const _window = Duration(seconds: 2);

  static final _build = <double>[];
  static final _raster = <double>[];
  static final _total = <double>[];
  static DateTime _since = DateTime.now();
  static int _lastVsync = 0;
  static int _dropped = 0;
  static double _worstGap = 0;

  /// The editor's playback time (ms) and rate while it is open: each frame
  /// its step is compared with the vsync step ("jitter" = uneven motion
  /// even without dropped frames).
  static (double, double) Function()? timeSource;
  static Duration? _lastTs;
  static double? _lastTime;
  static final _jitter = <double>[];
  static final _spikes = <String>[];

  static void install() {
    if (!enabled) return;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
  }

  static void _onFrame(Duration ts) {
    final src = timeSource;
    if (src == null) {
      _lastTime = null;
      return;
    }
    final (t, rate) = src();
    final last = _lastTime, lastTs = _lastTs;
    _lastTime = t;
    _lastTs = ts;
    if (last == null || lastTs == null || t == last) return;
    final dv = (ts - lastTs).inMicroseconds / 1000;
    if (dv <= 0 || dv > 100) return;
    _jitter.add(((t - last) / rate - dv).abs());
  }

  static void _onTimings(List<ui.FrameTiming> timings) {
    final hz = ui.PlatformDispatcher.instance.views.firstOrNull?.display.refreshRate ?? 60;
    final budget = 1000 / hz;
    for (final t in timings) {
      // Vsync-to-vsync gap between consecutive frames: more than one
      // budget = frames the display repeated (only while animating; a gap
      // over 100 ms is an idle pause, not a drop).
      final vsync = t.timestampInMicroseconds(ui.FramePhase.vsyncStart);
      final gap = (vsync - _lastVsync) / 1000;
      _lastVsync = vsync;
      if (gap > 1.5 * budget && gap < 100) {
        _dropped += (gap / budget).round() - 1;
        if (gap > _worstGap) _worstGap = gap;
      }
      final b = t.buildDuration.inMicroseconds / 1000;
      if (b > 6) _spikes.add('${(vsync ~/ 1000) % 100000}:${b.toStringAsFixed(1)}');
      _build.add(b);
      _raster.add(t.rasterDuration.inMicroseconds / 1000);
      _total.add(t.totalSpan.inMicroseconds / 1000);
    }
    final now = DateTime.now();
    if (now.difference(_since) < _window) return;
    final secs = now.difference(_since).inMilliseconds / 1000;
    _since = now;
    final slow = _total.where((v) => v > budget).length;
    final verySlow = _total.where((v) => v > 2 * budget).length;
    debugPrint('FRAMESTATS n=${_build.length} fps=${(_build.length / secs).toStringAsFixed(1)} '
        'hz=${hz.toStringAsFixed(0)} build=${_fmt(_build)} raster=${_fmt(_raster)} '
        'total=${_fmt(_total)} over=$slow over2x=$verySlow dropped=$_dropped worstGap=${_worstGap.toStringAsFixed(1)}');
    if (_spikes.isNotEmpty) {
      debugPrint('FRAMESTATS buildSpikes(ms@vsync) ${_spikes.join(' ')}');
      _spikes.clear();
    }
    if (_jitter.isNotEmpty) {
      debugPrint('FRAMESTATS jitter=${_fmt(_jitter)} over1ms=${_jitter.where((v) => v > 1).length} '
          'over3ms=${_jitter.where((v) => v > 3).length} of ${_jitter.length}');
      _jitter.clear();
    }
    _dropped = 0;
    _worstGap = 0;
    _build.clear();
    _raster.clear();
    _total.clear();
  }

  static String _fmt(List<double> v) {
    if (v.isEmpty) return '-';
    final s = [...v]..sort();
    String p(double q) => s[((s.length - 1) * q).round()].toStringAsFixed(1);
    return '${p(0.5)}/${p(0.9)}/${s.last.toStringAsFixed(1)}';
  }
}
