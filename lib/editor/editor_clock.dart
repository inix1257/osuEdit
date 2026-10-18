/// Source of truth for "where are we in the song".
///
/// The editor reads [currentTime] once per frame. When real audio playback
/// lands, implement this interface on top of the audio engine so the **audio
/// position is the master clock** (interpolate between the engine's coarse
/// position updates; never drive audio from the frame clock).
abstract class EditorClock {
  double get currentTime;
  bool get isPlaying;

  /// Playback rate (1.0 = normal). Audio implementations should keep pitch.
  double get rate;
  set rate(double value);

  /// Track length in ms if known.
  double? get duration;

  void play();
  void pause();
  void seek(double ms);
  void dispose();
}

/// Silent clock backed by a [Stopwatch]. Used until the audio engine is
/// integrated, and in tests.
class StopwatchClock implements EditorClock {
  final Stopwatch _sw = Stopwatch();
  double _base = 0;
  double _rate = 1;

  @override
  double? duration;

  StopwatchClock({this.duration});

  @override
  double get currentTime => _base + _sw.elapsedMicroseconds / 1000 * _rate;

  @override
  bool get isPlaying => _sw.isRunning;

  @override
  double get rate => _rate;

  @override
  set rate(double value) {
    _rebase();
    _rate = value;
  }

  @override
  void play() => _sw.start();

  @override
  void pause() {
    _rebase();
    _sw.stop();
  }

  @override
  void seek(double ms) {
    _base = ms;
    _sw.reset();
  }

  void _rebase() {
    _base = currentTime;
    _sw.reset();
  }

  @override
  void dispose() => _sw.stop();
}
