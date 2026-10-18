import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// User audio preferences.
class AudioSettings {
  /// Output latency compensation in ms (positive = audio is heard late).
  double offsetMs;
  double musicVolume;
  double hitsoundVolume;
  bool hitsoundsEnabled;

  /// Add the device's measured output latency beyond the reference phone's
  /// to [offsetMs] (see `AudioSession.latencyCorrection`).
  bool autoLatency;

  /// How much earlier than the song maps are timed by convention: ranked
  /// maps carry osu!stable's playback latency (lazer draws its editor
  /// waveform `Editor.WAVEFORM_VISUAL_OFFSET` = 20 ms early for this; ~22 ms
  /// measured over 477 maps). Hitsounds, the playhead and the waveforms
  /// follow the song this much later (`EditorController.mapAudioOffsetMs`).
  /// Fixed at [defaultStableCompensationMs]: it is a property of how maps
  /// are timed, not of the device, so it isn't saved or shown as a setting
  /// (changing it would make maps timed here off for everyone else). Tests
  /// set it to compare against no compensation.
  double stableCompensationMs;

  static const defaultStableCompensationMs = 20.0;

  AudioSettings({
    this.offsetMs = 0,
    this.musicVolume = 0.8,
    this.hitsoundVolume = 0.6,
    this.hitsoundsEnabled = true,
    this.autoLatency = true,
    this.stableCompensationMs = defaultStableCompensationMs,
  });

  static double _d(Object? v, double fallback) => v is num && v.isFinite ? v.toDouble() : fallback;

  factory AudioSettings.fromJson(Map<String, Object?> j) => AudioSettings(
        offsetMs: _d(j['offsetMs'], 0).clamp(-500, 500),
        musicVolume: _d(j['musicVolume'], 0.8).clamp(0, 1),
        hitsoundVolume: _d(j['hitsoundVolume'], 0.6).clamp(0, 1),
        hitsoundsEnabled: j['hitsoundsEnabled'] != false,
        autoLatency: j['autoLatency'] != false,
      );

  Map<String, Object?> toJson() => {
        'offsetMs': offsetMs,
        'musicVolume': musicVolume,
        'hitsoundVolume': hitsoundVolume,
        'hitsoundsEnabled': hitsoundsEnabled,
        'autoLatency': autoLatency,
      };
}

/// Editor display preferences.
class ViewSettings {
  /// Black over the background image: 0 = none, 1 = background hidden.
  double backgroundDim;

  /// Draw the song's waveform behind the timeline ticks.
  bool showWaveform;

  /// Whole-map overview in the bottom strip; hidden by default so the
  /// playfield gets the height.
  bool showMiniTimeline;

  /// Draw the map's storyboard behind the playfield.
  bool showStoryboard;

  /// Follow points between the objects of a combo (lazer's editor shows them).
  bool showFollowPoints;

  /// Stacked objects are drawn shifted up-left like in the game; off, at
  /// their file positions (on top of each other).
  bool showStacking;

  /// Circles and slider ends play the skin's hit animation at their time.
  /// Off (default): lazer's "Show hit markers" — they turn white and fade.
  bool hitAnimations;

  ViewSettings({
    this.backgroundDim = 0.7,
    this.showWaveform = true,
    this.showMiniTimeline = false,
    this.showStoryboard = true,
    this.showFollowPoints = true,
    this.showStacking = true,
    this.hitAnimations = false,
  });

  factory ViewSettings.fromJson(Map<String, Object?> j) => ViewSettings(
        backgroundDim: AudioSettings._d(j['backgroundDim'], 0.7).clamp(0, 1),
        showWaveform: j['showWaveform'] != false,
        showMiniTimeline: j['showMiniTimeline'] == true,
        showStoryboard: j['showStoryboard'] != false,
        showFollowPoints: j['showFollowPoints'] != false,
        showStacking: j['showStacking'] != false,
        hitAnimations: j['hitAnimations'] == true,
      );

  Map<String, Object?> toJson() => {
        'backgroundDim': backgroundDim,
        'showWaveform': showWaveform,
        'showMiniTimeline': showMiniTimeline,
        'showStoryboard': showStoryboard,
        'showFollowPoints': showFollowPoints,
        'showStacking': showStacking,
        'hitAnimations': hitAnimations,
      };
}

/// Curve type used for newly drawn sliders.
enum DefaultSliderType { auto, bezier, linear, catmull }

/// Editing toggles that aren't part of a map (the same for every map).
class EditSettings {
  bool gridSnap;
  bool distanceSnap;
  bool lockNotes;

  /// Rotate / scale / flip around the selection (else the playfield centre).
  bool pivotSelection;

  /// Scaling leaves slider nodes alone (sliders only move with their heads).
  bool scaleKeepsSliderShape;

  /// Scaling keeps the width / height ratio (the Scale panel and the
  /// selection box's lock); unlocked, the axes scale separately.
  bool scaleLocksAspect;

  /// Curve type of newly drawn sliders: [DefaultSliderType.auto] picks by
  /// point count (stable / lazer placement), the others force one type.
  DefaultSliderType defaultSliderType;

  EditSettings({
    this.gridSnap = false,
    this.distanceSnap = false,
    this.lockNotes = false,
    this.pivotSelection = false,
    this.scaleKeepsSliderShape = false,
    this.scaleLocksAspect = true,
    this.defaultSliderType = DefaultSliderType.auto,
  });

  factory EditSettings.fromJson(Map<String, Object?> j) => EditSettings(
        gridSnap: j['gridSnap'] == true,
        distanceSnap: j['distanceSnap'] == true,
        lockNotes: j['lockNotes'] == true,
        pivotSelection: j['pivotSelection'] == true,
        scaleKeepsSliderShape: j['scaleKeepsSliderShape'] == true,
        scaleLocksAspect: j['scaleLocksAspect'] != false,
        defaultSliderType: DefaultSliderType.values.asNameMap()[j['defaultSliderType']] ?? DefaultSliderType.auto,
      );

  Map<String, Object?> toJson() => {
        'gridSnap': gridSnap,
        'distanceSnap': distanceSnap,
        'lockNotes': lockNotes,
        'pivotSelection': pivotSelection,
        'scaleKeepsSliderShape': scaleKeepsSliderShape,
        'scaleLocksAspect': scaleLocksAspect,
        'defaultSliderType': defaultSliderType.name,
      };
}

/// Persists [AudioSettings], [ViewSettings] and [EditSettings] as JSON in
/// the app support folder (one set for all maps).
class SettingsStore {
  final File file;
  final AudioSettings audio;
  final ViewSettings view;
  final EditSettings edit;

  SettingsStore._(this.file, this.audio, this.view, this.edit);

  /// Used instead of the app's settings file when set (desktop integration
  /// tests keep theirs apart).
  static File? fileOverride;

  static Future<SettingsStore> open() async {
    final override = fileOverride;
    if (override != null) return load(override);
    final dir = await getApplicationSupportDirectory();
    return load(File('${dir.path}${Platform.pathSeparator}settings.json'));
  }

  /// Missing or corrupt files give defaults.
  static Future<SettingsStore> load(File file) async {
    var audio = AudioSettings();
    var view = ViewSettings();
    var edit = EditSettings();
    try {
      if (await file.exists()) {
        final j = jsonDecode(await file.readAsString());
        if (j is Map<String, Object?> && j['audio'] is Map<String, Object?>) {
          audio = AudioSettings.fromJson(j['audio'] as Map<String, Object?>);
        }
        if (j is Map<String, Object?> && j['view'] is Map<String, Object?>) {
          view = ViewSettings.fromJson(j['view'] as Map<String, Object?>);
        }
        if (j is Map<String, Object?> && j['edit'] is Map<String, Object?>) {
          edit = EditSettings.fromJson(j['edit'] as Map<String, Object?>);
        }
      }
    } on FormatException {
      // keep defaults
    }
    return SettingsStore._(file, audio, view, edit);
  }

  Future<void>? _saving;
  bool _dirty = false;

  /// Coalesces rapid calls (slider drags) into sequential writes of the
  /// latest values.
  Future<void> save() {
    _dirty = true;
    return _saving ??= () async {
      try {
        while (_dirty) {
          _dirty = false;
          await file.parent.create(recursive: true);
          await file.writeAsString(jsonEncode({'audio': audio.toJson(), 'view': view.toJson(), 'edit': edit.toJson()}), flush: true);
        }
      } finally {
        _saving = null;
      }
    }();
  }
}
