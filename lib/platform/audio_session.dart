import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Why playback has to stop although the user didn't pause it.
enum AudioInterruption {
  /// Another app or a call took the audio focus.
  focusLoss,

  /// Headphones were unplugged (or Bluetooth audio disconnected): the sound
  /// would continue on the speaker.
  noisy,

  /// The audio output device could not be started (after one retry).
  outputFailed,
}

/// The editor's audio session: audio focus while playing and the events
/// that must pause playback. Android only (`osuedit/audio`, MainActivity's
/// AudioSession); elsewhere [acquire] always succeeds and nothing is
/// reported except [reportOutputFailure].
class AudioSession {
  AudioSession._() {
    if (_supported) {
      _channel.setMethodCallHandler((call) async {
        if (call.method != 'interrupted') return;
        final reason = switch (call.arguments) {
          'noisy' => AudioInterruption.noisy,
          _ => AudioInterruption.focusLoss,
        };
        _interruptions.add(reason);
      });
    }
  }

  static final instance = AudioSession._();

  static const _channel = MethodChannel('osuedit/audio');
  static bool get _supported => Platform.isAndroid;

  final _interruptions = StreamController<AudioInterruption>.broadcast();

  /// Events after which playback should pause.
  Stream<AudioInterruption> get interruptions => _interruptions.stream;

  /// Takes the audio focus for playback. False when it was refused (e.g.
  /// during a phone call): don't play then.
  Future<bool> acquire() async {
    if (!_supported) return true;
    try {
      return await _channel.invokeMethod<bool>('acquire') ?? true;
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return true; // play anyway rather than not at all
    }
  }

  /// Gives the audio focus back (playback stopped).
  Future<void> release() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('release');
    } on MissingPluginException {
      // Nothing to release.
    } on PlatformException {
      // Nothing to release.
    }
  }

  /// The device's output latency in ms (Android: measured with a silent
  /// low-latency stream's timestamps, ~1 s), or null when unknown.
  Future<double?> measureOutputLatency() async {
    if (!_supported) return null;
    try {
      return await _channel.invokeMethod<double>('outputLatency');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Output latency (ms) of the phone the offsets were tuned on (SM-S916N,
  /// speaker): there offset 0 lines the audio up with the playfield. Other
  /// devices / routes are corrected by how much theirs differs.
  static const referenceLatencyMs = 123.0;

  /// The last [measureOutputLatency] result (null: not measured / unknown).
  final ValueNotifier<double?> deviceLatency = ValueNotifier(null);

  Future<void>? _measuring;

  /// Measures the output latency again (e.g. the audio route changed) and
  /// publishes it in [deviceLatency]. Concurrent calls share one run.
  Future<void> refreshLatency() => _measuring ??= () async {
        try {
          final v = await measureOutputLatency();
          if (v != null && v.isFinite && v > 0) deviceLatency.value = v;
        } finally {
          _measuring = null;
        }
      }();

  /// How much later audio is heard here than on the reference phone (ms,
  /// limited to −60…200); 0 when unknown.
  double get latencyCorrection {
    final v = deviceLatency.value;
    return v == null ? 0 : (v - referenceLatencyMs).clamp(-60.0, 200.0);
  }

  /// Reports that the audio output stopped working (from the audio engine).
  void reportOutputFailure() => _interruptions.add(AudioInterruption.outputFailed);
}
