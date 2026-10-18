import 'dart:ui' as ui;

import '../core/core.dart';
import '../platform/app_settings.dart';
import '../platform/storyboard_loader.dart';
import 'audio_clock.dart';

/// Everything audio an editor session needs.
class EditorAudio {
  final AudioClock clock;
  final HitsoundOutput hitsounds;
  final SettingsStore settings;

  /// The song's loudness envelope for the timeline, decoded in the
  /// background (null result: unavailable).
  final Future<Waveform?>? waveform;

  /// Decodes the song at close to sample resolution for the Timing mode's
  /// BPM view; called only when that view first needs it.
  final DetailedWaveformLoader? detailedWaveform;

  const EditorAudio(this.clock, this.hitsounds, this.settings, {this.waveform, this.detailedWaveform});
}

/// Starts decoding a [DetailedWaveform] (null result: unavailable).
typedef DetailedWaveformLoader = Future<DetailedWaveform?> Function();

/// Loads the music + hitsounds of [beatmap] from its set folder; null if the
/// audio file isn't there.
typedef EditorAudioLoader = Future<EditorAudio?> Function(String setPath, Beatmap beatmap);

/// Decodes the background image [fileName] of the set at [setPath]; null if
/// it is missing or unreadable.
typedef BackgroundLoader = Future<ui.Image?> Function(String setPath, String fileName);

/// Parses the storyboard of [beatmap] in the set at [setPath] and decodes
/// its images; null if it has none.
typedef StoryboardLoader = Future<LoadedStoryboard?> Function(String setPath, Beatmap beatmap);
