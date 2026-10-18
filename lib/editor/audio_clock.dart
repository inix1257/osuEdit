import '../core/core.dart';
import 'editor_clock.dart';

/// Plays individual hitsound samples (implemented on the audio engine).
abstract class HitsoundOutput {
  /// [volume] is the user's hitsound volume (0–1), applied on top of the
  /// sample's own volume.
  void play(SamplePlay sample, double volume);

  /// Whether [playAt] can schedule sounds on the engine's clock (then
  /// hitsounds are scheduled slightly ahead instead of fired per frame).
  bool get canSchedule;

  /// Plays [sample] at engine time [engineMs] (the clock of
  /// [AudioTrack.engineAnchor]), sample-accurately. Returns a handle for
  /// [cancel], or null if there's nothing to play.
  Object? playAt(SamplePlay sample, double volume, double engineMs);

  /// Drops a [playAt] sound (stops it if it already started).
  void cancel(Object handle);

  /// [startLoop] on the engine clock: starts looping at [startEngineMs]
  /// (a past time starts now), stops at [endEngineMs], and goes to each
  /// `(engineMs, volume)` of [volumeChanges] (volume 0–1, final, i.e.
  /// sample × user volume) at its time. [volume] is the final start volume;
  /// a silent start is kept when changes follow. Stop early with [stopLoop].
  Object? startLoopAt(SamplePlay sample, double volume, double startEngineMs, double endEngineMs,
      List<(double, double)> volumeChanges);

  /// Sets a running loop's final volume (0–1) now.
  void setLoopVolume(Object handle, double volume);

  /// Stops one-shot sounds still ringing that are long (storyboard
  /// sounds, over about a second): on pause / seek they would otherwise
  /// play on. Short hitsounds ring out.
  void stopLongSounds();

  /// Starts [sample] looping (slider bodies) at final volume [volume]
  /// (sample × user volume, 0–1); returns a handle for [stopLoop], or null
  /// if there's nothing to play ([keepSilent]: start even at volume 0, a
  /// later [setLoopVolume] raises it).
  Object? startLoop(SamplePlay sample, double volume, {bool keepSilent = false});
  void stopLoop(Object handle);

  /// Loads extra sample files (storyboard sounds: paths relative to
  /// [setPath]) so [play] finds them by [SamplePlay.filename].
  Future<void> loadFiles(String setPath, Iterable<String> paths);

  /// Default hitsounds come from the skin folder at [path] (its
  /// `normal-hitnormal.wav` …) where it has them; null: the built-in ones.
  /// The map's own samples still win.
  Future<void> useSkin(String? path);

  void dispose();
}

/// One loaded music track in an audio engine. Positions are in ms of the
/// audio file.
abstract class AudioTrack {
  /// Engine-reported play position. Typically coarse: it only advances once
  /// per mixed buffer (tens of ms).
  double get position;
  double get length;

  /// The engine's mixing clock and [position] read at the same mixed
  /// buffer: `(engineMs, position)`. Sounds scheduled at
  /// `engineMs + (t - position) / speed` are heard together with the music
  /// at file time t. Null when unknown (no voice, no engine clock).
  (double, double)? get engineAnchor;

  /// False once the engine stopped by itself (end of track).
  bool get isPlaying;

  void play();
  void pause();
  void seek(double ms);

  /// Relative speed; implementations should keep the pitch.
  set speed(double rate);

  /// 0–1.
  set volume(double v);

  void dispose();
}

/// Time source for interpolation (ms, monotonic). Injected in tests.
typedef MonotonicNow = double Function();

/// [EditorClock] driven by real audio: the **audio position is the master**.
///
/// The engine position only moves in buffer-sized steps, so each frame we
/// extrapolate from the last moment it changed (anchor + elapsed × rate)
/// and ease toward that estimate. While playing, time never runs backwards
/// (a backwards jitter of a few ms would make the playhead shiver): if the
/// engine is behind, the playhead holds until it catches up (up to
/// [maxHold]); if it is ahead by more than [snapThreshold], it jumps.
///
/// [offset] (ms) compensates output latency: with offset L, the displayed
/// time is `audioPosition - L`, i.e. the playhead shows what is *heard*.
/// Seek / pause keep that relationship, so the editor only ever sees
/// displayed time. Times before 0 (and before the audio starts) run on the
/// stopwatch and start the track when they reach 0.
class AudioClock implements EditorClock {
  final AudioTrack track;
  final MonotonicNow _now;

  /// If the engine is ahead of the estimate by more than this, jump to it.
  static const snapThreshold = 60.0;

  /// If the engine is *behind* the estimate, hold the playhead (never run
  /// backwards) until it catches up — e.g. while a latency-compensated track
  /// is still silent after starting. Only a lag beyond this snaps back.
  static const maxHold = 250.0;

  /// Fraction of the remaining error corrected per frame.
  static const correction = 0.15;

  double _offset;
  double _rate = 1;
  bool _playing = false;

  /// Current estimate of the *audio* position (not offset-adjusted).
  double _audioTime = 0;
  double _lastNow = 0;

  // Last observed change of the engine position.
  double _anchorPos = double.nan;
  double _anchorNow = 0;

  AudioClock(this.track, {this._offset = 0, MonotonicNow? now}) : _now = now ?? _stopwatchNow() {
    // The track may have been left at another speed by a previous owner.
    track.speed = _rate;
  }

  static MonotonicNow _stopwatchNow() {
    final sw = Stopwatch()..start();
    return () => sw.elapsedMicroseconds / 1000;
  }

  /// Output latency compensation in ms (positive = audio is heard late).
  double get offset => _offset;
  set offset(double v) {
    final shown = currentTime;
    _offset = v;
    seek(shown);
  }

  @override
  double? get duration => track.length;

  @override
  bool get isPlaying => _playing;

  @override
  double get rate => _rate;

  @override
  set rate(double value) {
    _sync();
    _rate = value;
    track.speed = value;
    _resetAnchor();
  }

  /// Position in the audio file the editor time maps to (used to trigger
  /// hitsounds, which share the music's output latency).
  double get audioTime {
    _sync();
    return _audioTime;
  }

  /// The engine time (ms) at which audio-file time [audioMs] is heard while
  /// playing: from the engine's own anchor, not the smoothed playhead, so
  /// scheduled hitsounds land exactly on the music. Null before the music
  /// started (pre-roll), while paused or without an engine clock.
  double? engineTimeAt(double audioMs) {
    if (!_playing || _audioTime < 0) return null;
    final a = track.engineAnchor;
    if (a == null) return null;
    return a.$1 + (audioMs - a.$2) / _rate;
  }

  @override
  double get currentTime {
    _sync();
    return _audioTime - _offset;
  }

  @override
  void play() {
    if (_playing) return;
    if (track.length > 0 && _audioTime >= track.length) return;
    _playing = true;
    _lastNow = _now();
    _resetAnchor();
    if (_audioTime >= 0) track.play();
  }

  @override
  void pause() {
    if (!_playing) return;
    _sync();
    _playing = false;
    track.pause();
    // Park the engine exactly where the playhead stopped, so resuming
    // continues from what the user sees.
    track.seek(_audioTime.clamp(0, double.infinity));
  }

  @override
  void seek(double ms) {
    _audioTime = ms + _offset;
    _lastNow = _now();
    _resetAnchor();
    if (_audioTime >= 0) {
      track.seek(_audioTime);
      if (_playing && !track.isPlaying) track.play();
    } else {
      track.pause();
      track.seek(0);
    }
  }

  void _resetAnchor() => _anchorPos = double.nan;

  void _sync() {
    if (!_playing) return;
    final now = _now();
    final dt = now - _lastNow;
    _lastNow = now;
    var t = _audioTime + dt * _rate;

    if (_audioTime < 0) {
      // Pre-roll on the stopwatch; start the music when we reach 0.
      if (t >= 0) {
        track.seek(t);
        track.play();
        _anchorPos = double.nan;
      }
      _audioTime = t;
      return;
    }

    final pos = track.position;
    if (pos != _anchorPos) {
      _anchorPos = pos;
      _anchorNow = now;
    }
    final estimate = _anchorPos + (now - _anchorNow) * _rate;
    final err = estimate - t;
    if (err > snapThreshold || err < -maxHold) {
      t = estimate;
    } else {
      t += err * correction;
      if (t < _audioTime) t = _audioTime;
    }

    if (!track.isPlaying && track.length > 0 && t >= track.length) {
      // Reached the end.
      t = track.length;
      _playing = false;
    }
    _audioTime = t;
  }

  @override
  void dispose() => track.dispose();
}
