import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';

import '../core/core.dart';

import 'app_settings.dart';
import 'audio_engine.dart';
import 'audio_session.dart';
import 'beatmap_library.dart';

/// Song select's music preview: the open set's song, looping from its
/// preview point (injected in tests).
abstract class PreviewPlayer {
  /// Plays [audioFile] of the set at [setPath] from [previewTime] ms (-1 =
  /// 40% into the song, like osu!), looping from there. Already playing
  /// that song: keeps going.
  Future<void> play(String setPath, String audioFile, int previewTime);

  /// Fades out and frees the song. Completes once it is freed.
  Future<void> stop();
}

/// Plays nothing (unit tests, maps without audio).
class SilentPreviewPlayer implements PreviewPlayer {
  const SilentPreviewPlayer();
  @override
  Future<void> play(String setPath, String audioFile, int previewTime) async {}
  @override
  Future<void> stop() async {}
}

/// What a preview plays: [data] from [startMs] into it.
class _PreparedPreview {
  final Uint8List data;

  /// Where to start in [data] (ms); -1 = 40% of its length.
  final double startMs;

  /// Song time (ms) at the start of [data] (an MP3 cut mid-song).
  final double cutMs;
  const _PreparedPreview(this.data, this.startMs, [this.cutMs = 0]);
}

/// SoLoud preview. Starting fast matters (it plays as a set is opened):
/// the file is read and prepared off the UI isolate, the previous song fades
/// out *while* the new one starts, and an MP3 is cut at the preview point
/// ([Mp3Frames]) so nothing has to be seeked — a streamed MP3 seeks by
/// scanning every frame before the target, which is slow for long songs on
/// a phone. The song is loaded with [SoLoud.loadMem] under its own name:
/// [SoLoud.loadFile] of the same path hands back the *same* source, so the
/// editor's track would be freed with the preview.
class SoloudPreviewPlayer implements PreviewPlayer {
  SoloudPreviewPlayer({this.volume});

  /// Fixed volume (tests); otherwise the music volume setting.
  final double? volume;

  static const _fadeIn = Duration(milliseconds: 250);
  static const _fadeOut = Duration(milliseconds: 250);

  SoLoud get _s => SoLoud.instance;

  /// Test hook: (phase, ms since play) as a preview starts.
  static void Function(String phase, double ms)? debugTimings;

  int _generation = 0;
  int _loads = 0;
  String? _key;
  AudioSource? _source;
  SoundHandle? _handle;
  StreamSubscription<AudioInterruption>? _interruptions;

  /// Whether a preview voice is playing (tests).
  bool get isPlaying {
    final h = _handle;
    return h != null && _s.isInitialized && _s.getIsValidVoiceHandle(h);
  }

  double _cutMs = 0;

  /// Seconds into the song (tests).
  double? get position {
    final h = _handle;
    if (!isPlaying) return null;
    return _s.getPosition(h!).inMicroseconds / 1e6 + _cutMs / 1000;
  }

  @override
  Future<void> play(String setPath, String audioFile, int previewTime) async {
    final key = '$setPath|$audioFile';
    if (key == _key && isPlaying) return;
    final gen = ++_generation;
    final sw = Stopwatch()..start();
    void mark(String what) => debugTimings?.call(what, sw.elapsedMicroseconds / 1000);
    // The old song fades out while the new one loads.
    _fadeOutCurrent().ignore();
    final file = audioFile.isEmpty ? null : BeatmapLibrary.resolveFile(setPath, audioFile);
    if (file == null) return;
    try {
      final path = file.path;
      final prepared = _prepareInBackground(path, previewTime);
      final vol = volume ?? await _musicVolume();
      await AudioEngine.instance.ensureInitialized();
      if (!await AudioSession.instance.acquire() || gen != _generation) return;
      final p = await prepared;
      mark('prepare');
      if (gen != _generation) return;
      // Compressed in memory, decoded while playing; a fresh name each time
      // (the previous preview may still be fading out).
      final source = await _s.loadMem('preview${++_loads}:$path', p.data, mode: LoadMode.disk);
      mark('loadMem');
      if (gen != _generation) {
        await _s.disposeSource(source);
        return;
      }
      var start = Duration(microseconds: (p.startMs * 1000).round());
      if (p.startMs < 0) start = _s.getLength(source) * 0.4;
      if (start >= _s.getLength(source)) start = Duration.zero;
      final h = _s.play(source, volume: 0, paused: true, looping: true, loopingStartAt: start);
      if (start > Duration.zero) _s.seek(h, start); // a few frames into a cut MP3
      _s.setPause(h, false);
      _s.fadeVolume(h, vol, _fadeIn);
      mark('playing');
      _source = source;
      _handle = h;
      _key = key;
      _cutMs = p.cutMs;
      _interruptions ??= AudioSession.instance.interruptions.listen((_) => stop());
    } catch (_) {
      // No preview is not worth an error.
    }
  }

  /// [_prepare] in a background isolate (a closure here captures nothing
  /// else: the player itself can't be sent).
  static Future<_PreparedPreview> _prepareInBackground(String path, int previewTime) =>
      Isolate.run(() => _prepare(path, previewTime));

  /// Reads [path] and, for an MP3, cuts it a few frames before the preview
  /// point. Runs in a background isolate.
  static _PreparedPreview _prepare(String path, int previewTime) {
    final bytes = File(path).readAsBytesSync();
    if (path.toLowerCase().endsWith('.mp3') || bytes.length > 2 && bytes[0] == 0xFF) {
      // Total length first when the preview point is relative to it.
      final total = previewTime >= 0 ? null : Mp3Frames.locate(bytes, 0)?.totalTime;
      final at = previewTime >= 0 ? previewTime.toDouble() : (total ?? 0) * 0.4;
      final pos = (previewTime >= 0 || total != null) ? Mp3Frames.locate(bytes, at) : null;
      if (pos != null && at < pos.totalTime) {
        return _PreparedPreview(bytes.sublist(pos.offset), at - pos.frameTime, pos.frameTime);
      }
    }
    return _PreparedPreview(bytes, previewTime.toDouble());
  }

  static Future<double> _musicVolume() async {
    try {
      return (await SettingsStore.open()).audio.musicVolume;
    } catch (_) {
      return 0.8;
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    await _fadeOutCurrent();
    if (_source != null) return; // a new preview started meanwhile
    await _interruptions?.cancel();
    _interruptions = null;
    await AudioSession.instance.release();
  }

  /// Fades out and frees what is playing.
  Future<void> _fadeOutCurrent() async {
    final source = _source, h = _handle;
    _source = null;
    _handle = null;
    _key = null;
    if (source == null) return;
    if (h != null && _s.getIsValidVoiceHandle(h)) {
      _s.fadeVolume(h, 0, _fadeOut);
      await Future<void>.delayed(_fadeOut);
    }
    try {
      await _s.disposeSource(source);
    } catch (_) {}
  }
}
