import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';

import '../core/core.dart';
import '../editor/audio_clock.dart';
import '../editor/editor_audio.dart';
import 'app_settings.dart';
import 'audio_session.dart';
import 'beatmap_library.dart';
import 'skin_library.dart';
import 'synth_samples.dart';

export '../editor/editor_audio.dart';

/// Process-wide SoLoud engine (FFI, low latency). Initialized lazily the
/// first time a map with audio is opened.
class AudioEngine {
  AudioEngine._();
  static final instance = AudioEngine._();

  Future<void>? _init;
  Map<String, AudioSource>? _builtins;

  SoLoud get _s => SoLoud.instance;

  Future<void> ensureInitialized() => _init ??= () async {
        // Small buffer = finer position updates and lower hitsound latency.
        await _s.init(bufferSize: 1024);
        // Lots of overlapping hitsounds in dense maps.
        _s.setMaxActiveVoiceCount(math.max(_s.getMaxActiveVoiceCount(), 64));
        // A device that fails to start leaves voices "playing" in silence
        // (and the playhead running on): retry once, else stop playback.
        _s.audioDeviceStartFailures.listen((_) => _recoverOutput());
      }();

  bool _recovering = false;

  Future<void> _recoverOutput() async {
    if (_recovering) return;
    _recovering = true;
    try {
      await _s.startAudioDevice();
    } catch (_) {
      AudioSession.instance.reportOutputFailure();
    } finally {
      _recovering = false;
    }
  }

  /// Decodes the whole file into memory: seeking must be instant in an
  /// editor (disk streaming lags on MP3 seeks). Costs ~10 MB per minute of
  /// stereo audio.
  Future<SoloudTrack> loadTrack(File file) async {
    await ensureInitialized();
    final source = await _s.loadFile(file.path, mode: LoadMode.memory);
    return SoloudTrack._(source);
  }

  Future<Map<String, AudioSource>> builtinSamples() async {
    await ensureInitialized();
    return _builtins ??= {
      for (final e in SynthSamples.all().entries) e.key: await _s.loadMem('builtin-${e.key}.wav', e.value),
    };
  }
}

/// The music voice. Kept alive paused between plays so resume never
/// re-creates it; re-created when the engine dropped it (end of track), when
/// the pitch filter is switched, and on seeks while the filter is active.
///
/// **Pitch filter latency.** Away from 1.0x the voice runs through SoLoud's
/// pitch-shift filter (signalsmith-stretch), which delays what is *heard* by
/// [pitchFilterLatencyMs] of output time, while the engine keeps reporting the
/// position it feeds *into* the filter. [position] subtracts that delay so the
/// editor clock (and the hitsounds fired from it) follow the audible music.
class SoloudTrack implements AudioTrack {
  /// Measured on a Galaxy S942N (P0-3, integration_test/audio_latency_test.dart):
  /// music lagged an unfiltered hitsound by ~120 ms at every rate != 1.0x.
  /// It is the stretcher's block size (0.12 s in its default preset), so it
  /// does not depend on the device.
  static const pitchFilterLatencyMs = 120.0;

  final AudioSource _source;
  SoundHandle? _handle;
  double _speed = 1;
  double _volume = 1;
  bool _pitchFilter = false;

  @override
  final double length;

  SoloudTrack._(this._source)
      : length = SoLoud.instance.getLength(_source).inMicroseconds / 1000;

  SoLoud get _s => SoLoud.instance;

  double get _semitones => -12 * math.log(_speed) / math.ln2;

  /// A valid handle, created paused at [at] (or 0) if needed.
  SoundHandle _voice({double? at}) {
    final h = _handle;
    if (h != null && _s.getIsValidVoiceHandle(h)) return h;
    final n = _s.play(_source, paused: true, volume: _volume);
    _s.setProtectVoice(n, true);
    _s.setRelativePlaySpeed(n, _speed);
    if (_pitchFilter) _source.filters.pitchShiftFilter.semitones(soundHandle: n).value = _semitones;
    if (at != null) _s.seek(n, _dur(at));
    return _handle = n;
  }

  /// Replaces the voice (fresh filter state) at [at], keeping play state.
  void _rebuild(double at) {
    final playing = isPlaying;
    final h = _handle;
    if (h != null && _s.getIsValidVoiceHandle(h)) _s.stop(h);
    _handle = null;
    final n = _voice(at: at.clamp(0, length));
    if (playing) _s.setPause(n, false);
  }

  static Duration _dur(double ms) => Duration(microseconds: (ms * 1000).round());

  double get _rawPosition {
    final h = _handle;
    if (h == null || !_s.getIsValidVoiceHandle(h)) return length;
    return _s.getPosition(h).inMicroseconds / 1000;
  }

  /// What is audible now. Right after a filtered voice (re)starts this is
  /// *behind* where it was started (the filter is still silent); AudioClock
  /// holds the playhead until the music catches up.
  @override
  double get position {
    final raw = _rawPosition;
    if (!_pitchFilter || raw >= length) return raw;
    return raw - pitchFilterLatencyMs * _speed;
  }

  /// The mixer advances its clock and every voice's position under one
  /// lock per buffer, so the two agree when read without a buffer mixed in
  /// between (checked by reading the clock on both sides).
  @override
  (double, double)? get engineAnchor {
    final h = _handle;
    if (h == null || !_s.getIsValidVoiceHandle(h)) return null;
    for (var i = 0; i < 3; i++) {
      final e1 = _s.getEngineTime();
      final p = position;
      final e2 = _s.getEngineTime();
      if (e1 == e2) return (e1.inMicroseconds / 1000, p);
    }
    return null;
  }

  @override
  bool get isPlaying {
    final h = _handle;
    return h != null && _s.getIsValidVoiceHandle(h) && !_s.getPause(h);
  }

  @override
  void play() => _s.setPause(_voice(), false);

  @override
  void pause() {
    final h = _handle;
    if (h != null && _s.getIsValidVoiceHandle(h)) _s.setPause(h, true);
  }

  @override
  void seek(double ms) {
    ms = ms.clamp(0, length);
    final h = _handle;
    if (_pitchFilter) {
      // The filter still holds audio from the old position; start clean.
      _rebuild(ms);
    } else if (h != null && _s.getIsValidVoiceHandle(h)) {
      _s.seek(h, _dur(ms));
    } else {
      _voice(at: ms);
    }
  }

  @override
  set speed(double rate) {
    final pos = position;
    _speed = rate;
    // Keep the pitch: shift by the inverse of the speed. The filter costs
    // CPU, colours the sound and adds latency, so it's only active away from
    // 1.0x.
    final wantFilter = (rate - 1).abs() > 1e-3;
    if (wantFilter != _pitchFilter) {
      _pitchFilter = wantFilter;
      final f = _source.filters.pitchShiftFilter;
      wantFilter ? f.activate() : f.deactivate();
      // Filters attach when a voice starts: rebuild the voice in place, at
      // what was audible.
      _rebuild(pos);
      return;
    }
    final h = _voice();
    _s.setRelativePlaySpeed(h, rate);
    if (_pitchFilter) _source.filters.pitchShiftFilter.semitones(soundHandle: h).value = _semitones;
  }

  @override
  set volume(double v) {
    _volume = v;
    final h = _handle;
    if (h != null && _s.getIsValidVoiceHandle(h)) _s.setVolume(h, v);
  }

  @override
  void dispose() {
    final h = _handle;
    if (h != null && _s.getIsValidVoiceHandle(h)) _s.stop(h);
    _s.disposeSource(_source);
  }
}

/// Plays [SamplePlay]s: beatmap-folder custom samples first, then the
/// built-in synthesized ones.
class SoloudHitsoundPlayer implements HitsoundOutput {
  final Map<String, AudioSource> _builtins;

  /// Lower-case stem (`soft-hitclap2`) and full name (`boom.wav`) → source.
  /// A null value means "file exists but is empty / unreadable": silent, as
  /// in osu!.
  final Map<String, AudioSource?> _custom;

  SoloudHitsoundPlayer._(this._builtins, this._custom);

  /// osu!stable looks samples up as wav, then mp3, then ogg (lazer keeps
  /// that order): when one name exists with several, that one wins.
  static const _exts = ['wav', 'mp3', 'ogg'];

  /// Custom samples bigger than this are ignored (probably not a hitsound).
  static const _maxCustomBytes = 2 * 1024 * 1024;

  /// Loads the built-ins and every short audio file in [setPath] except the
  /// music file.
  static Future<SoloudHitsoundPlayer> load({String? setPath, String? musicFile}) async {
    final engine = AudioEngine.instance;
    final builtins = await engine.builtinSamples();
    final custom = <String, AudioSource?>{};
    if (setPath != null) {
      final music = musicFile == null ? null : BeatmapLibrary.resolveFile(setPath, musicFile)?.path;
      final files = [
        for (final e in Directory(setPath).listSync())
          if (e is File && e.path != music) e,
      ];
      // In lookup priority, so `putIfAbsent` below keeps the stable choice.
      int rank(File f) {
        final n = f.path.toLowerCase();
        final i = _exts.indexWhere((x) => n.endsWith('.$x'));
        return i < 0 ? _exts.length : i;
      }

      files.sort((a, b) => rank(a).compareTo(rank(b)));
      for (final e in files) {
        final name = e.path.substring(e.path.lastIndexOf(Platform.pathSeparator) + 1).toLowerCase();
        final dot = name.lastIndexOf('.');
        if (dot <= 0 || !_exts.contains(name.substring(dot + 1))) continue;
        AudioSource? src;
        final len = e.lengthSync();
        if (len > _maxCustomBytes) continue;
        if (len > 0) {
          try {
            src = await SoLoud.instance.loadFile(e.path);
          } catch (_) {
            src = null;
          }
        }
        custom[name] = src;
        custom.putIfAbsent(name.substring(0, dot), () => src);
      }
    }
    final player = SoloudHitsoundPlayer._(builtins, custom);
    await player.useSkin(SkinManager.instance.current.value?.path);
    return player;
  }

  /// The skin's default samples by stem (`soft-hitclap`); null = empty file.
  Map<String, AudioSource?> _skin = const {};
  String? _skinPath;

  static final _skinSampleRe = RegExp(r'^(normal|soft|drum)-(hit|slider)[a-z]+$');

  @override
  Future<void> useSkin(String? path) async {
    if (path == _skinPath) return;
    _skinPath = path;
    final loaded = <String, AudioSource?>{};
    if (path != null && Directory(path).existsSync()) {
      final files = [
        for (final e in Directory(path).listSync())
          if (e is File) e,
      ];
      int rank(File f) {
        final n = f.path.toLowerCase();
        final i = _exts.indexWhere((x) => n.endsWith('.$x'));
        return i < 0 ? _exts.length : i;
      }

      files.sort((a, b) => rank(a).compareTo(rank(b)));
      for (final f in files) {
        final name = f.path.substring(f.path.lastIndexOf(Platform.pathSeparator) + 1).toLowerCase();
        final dot = name.lastIndexOf('.');
        if (dot <= 0 || !_exts.contains(name.substring(dot + 1))) continue;
        final stem = name.substring(0, dot);
        if (!_skinSampleRe.hasMatch(stem) || loaded.containsKey(stem)) continue;
        final len = f.lengthSync();
        if (len > _maxCustomBytes) continue;
        AudioSource? src;
        if (len > 0) {
          try {
            src = await SoLoud.instance.loadFile(f.path);
          } catch (_) {
            src = null;
          }
        }
        loaded[stem] = src;
      }
    }
    if (_disposed || path != _skinPath) {
      for (final s in loaded.values) {
        if (s != null) SoLoud.instance.disposeSource(s);
      }
      return;
    }
    final old = _skin;
    _skin = loaded;
    for (final s in old.values) {
      if (s != null) SoLoud.instance.disposeSource(s);
    }
  }

  /// The skin's sample for [p]'s bank and name, else the built-in one.
  AudioSource? _default(SamplePlay p) {
    final key = '${p.bank}-${p.name}';
    return _skin.containsKey(key) ? _skin[key] : _builtins[key];
  }

  AudioSource? _find(SamplePlay p) {
    final file = p.filename;
    if (file != null) {
      final k = file.toLowerCase();
      return _custom.containsKey(k) ? _custom[k] : _default(p);
    }
    final stem = p.customStem;
    if (stem != null && _custom.containsKey(stem)) return _custom[stem];
    return _default(p);
  }

  @override
  void play(SamplePlay sample, double volume) {
    final src = _find(sample);
    if (src == null) return;
    final v = sample.volume / 100 * volume;
    if (v <= 0) return;
    _trackLong(src, SoLoud.instance.play(src, volume: v));
  }

  /// One-shot handles of long sounds (see [stopLongSounds]).
  final _long = <SoundHandle>{};
  final Map<AudioSource, bool> _isLong = Map.identity();

  /// Sounds longer than this keep playing noticeably after a pause.
  static const _longSound = Duration(milliseconds: 1000);

  void _trackLong(AudioSource src, SoundHandle h) {
    if (!(_isLong[src] ??= SoLoud.instance.getLength(src) > _longSound)) return;
    if (_long.length > 64) _long.removeWhere((x) => !SoLoud.instance.getIsValidVoiceHandle(x));
    _long.add(h);
  }

  @override
  void stopLongSounds() {
    for (final h in _long) {
      if (SoLoud.instance.getIsValidVoiceHandle(h)) SoLoud.instance.stop(h);
    }
    _long.clear();
  }

  @override
  bool get canSchedule => true;

  /// Scheduled sounds not known to be over (stopped on dispose).
  final _scheduled = <SoundHandle>{};

  @override
  Object? playAt(SamplePlay sample, double volume, double engineMs) {
    final src = _find(sample);
    if (src == null) return null;
    final v = sample.volume / 100 * volume;
    if (v <= 0) return null;
    if (_scheduled.length > 256) _scheduled.removeWhere((h) => !SoLoud.instance.getIsValidVoiceHandle(h));
    final h = SoLoud.instance.playScheduled(src, _engine(engineMs), volume: v);
    _scheduled.add(h);
    _trackLong(src, h);
    return h;
  }

  @override
  void cancel(Object handle) {
    if (handle is! SoundHandle) return;
    final h = handle as SoundHandle; // extension type: `is` doesn't promote
    if (_scheduled.remove(h) && SoLoud.instance.getIsValidVoiceHandle(h)) SoLoud.instance.stop(h);
  }

  /// Running slider body loops (stopped on dispose so none keeps playing).
  final _loops = <SoundHandle>{};

  static Duration _engine(double ms) => Duration(microseconds: (ms * 1000).round());

  @override
  Object? startLoop(SamplePlay sample, double volume, {bool keepSilent = false}) {
    final src = _find(sample);
    if (src == null || (volume <= 0 && !keepSilent)) return null;
    final h = SoLoud.instance.play(src, volume: math.max(0, volume), looping: true);
    _loops.add(h);
    return h;
  }

  /// Volume changes are short ramps (no clicks), like a fader move.
  static const _volumeRamp = Duration(milliseconds: 5);

  @override
  Object? startLoopAt(SamplePlay sample, double volume, double startEngineMs, double endEngineMs,
      List<(double, double)> volumeChanges) {
    final src = _find(sample);
    if (src == null || (volume <= 0 && volumeChanges.isEmpty)) return null;
    final s = SoLoud.instance;
    final h = s.playScheduled(src, _engine(startEngineMs),
        duration: _engine(math.max(0, endEngineMs - startEngineMs)), volume: math.max(0, volume), looping: true);
    for (final (at, v) in volumeChanges) {
      s.fadeScheduled(h, _engine(at), math.max(0, v), _volumeRamp);
    }
    _loops.add(h);
    return h;
  }

  @override
  void setLoopVolume(Object handle, double volume) {
    if (handle is! SoundHandle) return;
    final h = handle as SoundHandle; // extension type: `is` doesn't promote
    if (_loops.contains(h) && SoLoud.instance.getIsValidVoiceHandle(h)) SoLoud.instance.setVolume(h, volume);
  }

  @override
  void stopLoop(Object handle) {
    if (handle is! SoundHandle) return;
    final h = handle as SoundHandle; // extension type: `is` doesn't promote
    if (_loops.remove(h)) SoLoud.instance.stop(h);
  }

  /// Storyboard samples may be longer than hitsounds, but not songs.
  static const _maxStoryboardBytes = 16 * 1024 * 1024;

  /// Memory for storyboard samples decoded in RAM (the rest stream from
  /// disk): about 4 minutes of stereo audio.
  static const maxDecodedBytes = 96 * 1024 * 1024;

  /// The budget in use ([maxDecodedBytes]; tests lower it).
  int decodedBudget = maxDecodedBytes;

  /// What SoLoud keeps in RAM for a decoded sound of [length]: 32-bit float
  /// stereo at 48 kHz (an upper estimate for the usual 44.1 kHz files).
  static int decodedBytes(Duration length) => (length.inMicroseconds / 1e6 * 48000 * 2 * 4).ceil();

  int _decodedBytes = 0;

  /// Storyboard samples streamed from disk because the budget was used up.
  int streamedFiles = 0;

  bool _disposed = false;

  @override
  Future<void> loadFiles(String setPath, Iterable<String> paths) async {
    // [paths] come in order of first use, so the earliest sounds get memory.
    for (final p in paths) {
      final key = p.toLowerCase();
      if (_custom.containsKey(key)) continue;
      AudioSource? src;
      final file = BeatmapLibrary.resolveFile(setPath, p);
      if (file != null && file.lengthSync() <= _maxStoryboardBytes) {
        try {
          src = await SoLoud.instance.loadFile(file.path);
          final bytes = decodedBytes(SoLoud.instance.getLength(src));
          if (_decodedBytes + bytes > decodedBudget) {
            // Over budget: stream this one from disk instead (a little more
            // CPU while it plays, almost no memory).
            await SoLoud.instance.disposeSource(src);
            src = null;
            src = await SoLoud.instance.loadFile(file.path, mode: LoadMode.disk);
            streamedFiles++;
          } else {
            _decodedBytes += bytes;
          }
        } catch (_) {
          src = null;
        }
      }
      if (_disposed) {
        if (src != null) SoLoud.instance.disposeSource(src);
        return;
      }
      _custom[key] = src;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final h in _loops) {
      SoLoud.instance.stop(h);
    }
    _loops.clear();
    for (final h in _scheduled) {
      if (SoLoud.instance.getIsValidVoiceHandle(h)) SoLoud.instance.stop(h);
    }
    _scheduled.clear();
    _long.clear();
    for (final s in _custom.values.toSet()) {
      if (s != null) SoLoud.instance.disposeSource(s);
    }
    for (final s in _skin.values) {
      if (s != null) SoLoud.instance.disposeSource(s);
    }
    _skin = const {};
  }
}

/// Loads the map's music and hitsounds from its set folder. Returns null if
/// the map has no audio file there.
Future<EditorAudio?> loadEditorAudio(String setPath, Beatmap beatmap) async {
  final file = BeatmapLibrary.resolveFile(setPath, beatmap.audioFilename);
  if (file == null) return null;
  final settings = await SettingsStore.open();
  final track = await AudioEngine.instance.loadTrack(file);
  try {
    final hitsounds = await SoloudHitsoundPlayer.load(setPath: setPath, musicFile: beatmap.audioFilename);
    final length = track.length;
    return EditorAudio(AudioClock(track), hitsounds, settings,
        waveform: loadWaveform(file, length), detailedWaveform: () => loadDetailedWaveform(file, length));
  } catch (_) {
    track.dispose();
    rethrow;
  }
}

/// RMS envelope of [file] in [Waveform.binMs]-wide bins, decoded by SoLoud
/// on a background isolate. Null on failure (the timeline just has none).
Future<Waveform?> loadWaveform(File file, double lengthMs, {double binMs = 5}) async {
  final bins = (lengthMs / binMs).ceil();
  if (bins <= 0) return null;
  try {
    final rms = await SoLoud.instance.readSamplesFromFile(file.path, bins, average: true);
    return Waveform(rms, binMs);
  } catch (_) {
    return null;
  }
}

/// Frames above which [loadDetailedWaveform] keeps every second frame
/// (~6 minutes at 44.1 kHz), bounding the decode's memory.
const _detailMaxFrames = 16000000;

/// The song at close to sample resolution ([DetailedWaveform], left
/// channel) for the Timing mode's BPM view, decoded and analysed on a
/// background isolate. Null on failure.
Future<DetailedWaveform?> loadDetailedWaveform(File file, double lengthMs) async {
  try {
    final path = file.path;
    return await Isolate.run(() async {
      final rate = (await _sampleRateOf(path) ?? 44100).toDouble();
      final total = lengthMs / 1000 * rate;
      if (!(total >= 1)) return null;
      final step = total > _detailMaxFrames ? 2 : 1;
      // One value per [step] frames: SoLoud reads frame by frame when it
      // is asked for (about) every frame.
      final n = (total / step).floor();
      final samples = await SoLoud.instance.readSamplesFromFile(path, n);
      return DetailedWaveform.fromSamples(samples, rate / step);
    });
  } catch (_) {
    return null;
  }
}

/// The sample rate [path] decodes at, from its header (skipping ID3v2).
Future<int?> _sampleRateOf(String path) async {
  final f = await File(path).open();
  try {
    final head = await f.read(10);
    final skip = id3v2Size(head);
    await f.setPosition(skip);
    return audioSampleRate(Uint8List.fromList(await f.read(64 * 1024)));
  } finally {
    await f.close();
  }
}
