import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/audio_clock.dart';

/// Engine stand-in whose position advances in [quantum]-ms steps of fake
/// wall time, like a real mixer reporting once per buffer.
class FakeTrack implements AudioTrack {
  final double Function() now;
  final double quantum;
  @override
  final double length;

  /// Audible lag in ms of output time, like SoloudTrack's pitch filter:
  /// [position] reports `engine − latency × speed` (can be before the seek
  /// target right after starting).
  final double latency;

  /// Whether it reports [engineAnchor] (an engine clock = fake wall time).
  final bool engineClock;

  FakeTrack(this.now, {this.quantum = 46, this.length = 10000, this.latency = 0, this.engineClock = false});

  double _base = 0;
  double _startedAt = 0;
  bool _playing = false;
  double _speed = 1;
  int seeks = 0;

  double get _exact {
    if (!_playing) return _base;
    return (_base + (now() - _startedAt) * _speed).clamp(0, length);
  }

  @override
  double get position =>
      (_playing ? (_exact / quantum).floorToDouble() * quantum : _base) - (_exact >= length ? 0 : latency * _speed);

  /// The wall time when the reported (quantized) position was reached,
  /// with that position: what a mixer reports after its last buffer.
  @override
  (double, double)? get engineAnchor {
    if (!engineClock || !_playing) return null;
    final q = (_exact / quantum).floorToDouble() * quantum;
    return (_startedAt + (q - _base) / _speed, position);
  }

  @override
  bool get isPlaying => _playing && _exact < length;

  @override
  void play() {
    _startedAt = now();
    _playing = true;
  }

  @override
  void pause() {
    _base = _exact;
    _playing = false;
  }

  @override
  void seek(double ms) {
    seeks++;
    _base = ms;
    _startedAt = now();
  }

  @override
  set speed(double rate) {
    _base = _exact;
    _startedAt = now();
    _speed = rate;
  }

  @override
  set volume(double v) {}

  @override
  void dispose() {}
}

/// Records played samples.
class RecordingHitsounds implements HitsoundOutput {
  final played = <SamplePlay>[];
  bool disposed = false;

  @override
  void play(SamplePlay sample, double volume) => played.add(sample);

  @override
  final bool canSchedule;

  RecordingHitsounds({this.canSchedule = false});

  /// [playAt] calls still pending (not cancelled), by handle: sample and
  /// engine time.
  final scheduled = <int, (SamplePlay, double)>{};
  int _nextScheduled = 1000;

  @override
  Object? playAt(SamplePlay sample, double volume, double engineMs) {
    scheduled[++_nextScheduled] = (sample, engineMs);
    return _nextScheduled;
  }

  /// Handles passed to [cancel].
  final cancelled = <Object>[];

  @override
  void cancel(Object handle) {
    cancelled.add(handle);
    scheduled.remove(handle);
  }

  /// Loops currently running, by handle.
  final loops = <int, SamplePlay>{};
  int _nextLoop = 0;

  @override
  Object? startLoop(SamplePlay sample, double volume, {bool keepSilent = false}) {
    loops[++_nextLoop] = sample;
    loopVolumes[_nextLoop] = volume;
    return _nextLoop;
  }

  /// Final volume of each running loop (last set).
  final loopVolumes = <int, double>{};

  /// [startLoopAt] calls by handle: start / end engine time and volume changes.
  final scheduledLoops = <int, (double, double, List<(double, double)>)>{};

  @override
  Object? startLoopAt(SamplePlay sample, double volume, double startEngineMs, double endEngineMs,
      List<(double, double)> volumeChanges) {
    loops[++_nextLoop] = sample;
    loopVolumes[_nextLoop] = volume;
    scheduledLoops[_nextLoop] = (startEngineMs, endEngineMs, volumeChanges);
    return _nextLoop;
  }

  @override
  void setLoopVolume(Object handle, double volume) {
    if (handle is int && loops.containsKey(handle)) loopVolumes[handle] = volume;
  }

  int longStops = 0;

  @override
  void stopLongSounds() => longStops++;

  @override
  void stopLoop(Object handle) => loops.remove(handle);

  /// Files passed to [loadFiles].
  final loadedFiles = <String>[];

  @override
  Future<void> loadFiles(String setPath, Iterable<String> paths) async => loadedFiles.addAll(paths);

  /// The last [useSkin] path.
  String? skinPath;

  @override
  Future<void> useSkin(String? path) async => skinPath = path;

  @override
  void dispose() => disposed = true;
}
