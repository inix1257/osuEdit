import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../core/core.dart';
import '../platform/beatmap_file_service.dart';
import '../platform/app_settings.dart';
import '../platform/audio_session.dart';
import '../platform/beatmap_library.dart';
import '../platform/recovery_store.dart';
import '../platform/skin_library.dart';
import '../platform/storyboard_loader.dart';
import '../platform/synth_samples.dart';
import 'audio_clock.dart';
import 'editor_audio.dart';
import 'editor_clock.dart';
import 'render/playfield_transform.dart';

enum EditorTool { select, circle, slider, spinner }

/// What flips and the rotate / scale dialog turn around.
enum TransformPivot { playfield, selection }

/// One undo or redo and what it changed ([EditorController.lastHistoryStep]).
class HistoryStep {
  final EditFocus focus;
  final bool undo;
  const HistoryStep(this.focus, {required this.undo});
}

/// Owns one open beatmap and all editor state.
///
/// Two notification channels, on purpose:
/// * the controller itself ([ChangeNotifier]) fires on *edits / UI state*
///   (map changed, selection, tool, zoom) — widgets rebuild;
/// * [time] fires every frame during playback — only painters listen to it,
///   so playback never rebuilds the widget tree.
class EditorController extends ChangeNotifier {
  final Beatmap beatmap;
  late final EditHistory history;
  EditorClock _clock;
  final BeatmapFileService files;

  /// Set when [document] lives in the library (enables .osz export).
  final BeatmapLibrary? library;
  BeatmapDocument document;

  /// Null when the map has no playable audio (silent [StopwatchClock]).
  HitsoundOutput? _hitsounds;

  /// Persisted audio preferences; null in tests (defaults, not saved).
  SettingsStore? _settings;
  final AudioSettings _fallbackAudio = AudioSettings();

  /// Reloads music + hitsounds when `AudioFilename` changes (setting a new
  /// audio file, or undoing that). Null: audio is fixed for the session.
  final EditorAudioLoader? audioLoader;

  /// Loads the background image for the playfield (library maps only).
  final BackgroundLoader? backgroundLoader;

  /// Loads the storyboard for the playfield (library maps only).
  final StoryboardLoader? storyboardLoader;

  final ValueNotifier<double> time = ValueNotifier(0);

  /// Sliders are drawn and edited the osu!lazer way (the user kept a set in
  /// lazer's slider format): each control point can start a segment of its
  /// own curve type ([setPointType]), drawn segments get lazer's automatic
  /// types, and lazer's rules apply when points are added or removed. Paths
  /// stable can't express are saved in lazer's syntax. Sliders already in
  /// lazer's model are always edited this way.
  final bool lazerSliders;

  /// Where unsaved changes are autosaved ([autosave]); null: not at all.
  final RecoveryStore? recovery;

  /// Pinch zoom of the playfield view (view state, not saved). A separate
  /// channel like [time]: pinching repaints the playfield without rebuilds.
  final ValueNotifier<PlayfieldZoom> playfieldZoom = ValueNotifier(PlayfieldZoom.none);

  void resetPlayfieldZoom() => playfieldZoom.value = PlayfieldZoom.none;

  EditorTool _tool = EditorTool.select;
  int _divisor;
  /// Milliseconds the top timeline shows across its width (lazer keeps
  /// its zoom this way: `Zoom` = track length / visible range).
  double? _timelineVisibleMs;

  /// The top timeline's width in logical pixels (set by it on layout).
  double _timelineWidth = 0;

  /// Identity set (hit objects don't override ==).
  final Set<HitObject> selection = LinkedHashSet.identity();

  EditorController({
    required this.beatmap,
    required this.document,
    EditorClock? clock,
    this.files = const BeatmapFileService(),
    this.library,
    this._hitsounds,
    this._settings,
    this.audioLoader,
    this.backgroundLoader,
    this.storyboardLoader,
    Future<Waveform?>? waveform,
    DetailedWaveformLoader? detailedWaveform,
    this.lazerSliders = false,
    this.recovery,
  })  : _clock = clock ?? StopwatchClock(),
        _divisor = _validDivisor(beatmap.beatDivisor),
        _audioName = beatmap.audioFilename,
        _namedFor = DifficultyOps.fileNameOf(beatmap),
        _osbNamedFor = DifficultyOps.osbFileNameOf(beatmap) {
    history = EditHistory(beatmap, onChanged: _onMapChanged);
    _savedSetup = _setupSnapshot();
    _objectTimes = _objectSignature();
    history.followUp = _regenerateBreaks;
    AudioSession.instance.deviceLatency.addListener(_applyOffset);
    SkinManager.instance.current.addListener(_onSkinChanged);
    _applyAudioSettings();
    _reloadBackground();
    _loadStoryboard();
    _attachWaveform(waveform);
    _detailLoader = detailedWaveform;
    final first = beatmap.timingPoints.isEmpty ? 0.0 : beatmap.timingPoints.first.time;
    seek(first);
  }

  static const divisors = [1, 2, 3, 4, 6, 8, 12, 16];
  static int _validDivisor(int d) => divisors.contains(d) ? d : 4;

  EditorClock get clock => _clock;
  HitsoundOutput? get hitsounds => _hitsounds;
  SettingsStore? get settings => _settings;

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    AudioSession.instance.deviceLatency.removeListener(_applyOffset);
    SkinManager.instance.current.removeListener(_onSkinChanged);
    _background?.dispose();
    _background = null;
    _storyboard?.dispose();
    _storyboard = null;
    _stopLoops();
    clock.dispose();
    hitsounds?.dispose();
    time.dispose();
    playfieldZoom.dispose();
    lastHistoryStep.dispose();
    _difficultyTimer?.cancel();
    difficulty.dispose();
    super.dispose();
  }

  void _onMapChanged() {
    // Drop selected objects that no longer exist (after undo/redo).
    selection.removeWhere((h) => beatmap.indexOfHitObject(h) < 0);
    if (beatmap.audioFilename != _audioName) _reloadAudio();
    if (beatmap.backgroundFilename != _backgroundName) _reloadBackground();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Star rating (display only)

  /// The map's star rating and difficulty graph ([StarRating.analyse]) as
  /// of the last analysis; null before the first one and for maps that
  /// aren't osu!standard. Kept up to date once [trackDifficulty] is called.
  final ValueNotifier<StarAnalysis?> difficulty = ValueNotifier(null);

  bool _trackingDifficulty = false;
  int _difficultyRevision = -1;
  int _difficultyGeneration = 0;
  Timer? _difficultyTimer;

  /// Edits within this long of each other are analysed once.
  static const difficultyDelay = Duration(milliseconds: 600);

  /// Starts keeping [difficulty] current: analyses the map now and again
  /// [difficultyDelay] after each edit, in a background isolate.
  void trackDifficulty() {
    if (_trackingDifficulty) return;
    _trackingDifficulty = true;
    addListener(_difficultyChanged);
    _difficultyChanged();
  }

  void _difficultyChanged() {
    if (_disposed || beatmap.revision == _difficultyRevision) return;
    final first = _difficultyRevision < 0;
    _difficultyRevision = beatmap.revision;
    _difficultyTimer?.cancel();
    _difficultyTimer = Timer(first ? Duration.zero : difficultyDelay, _analyseDifficulty);
  }

  Future<void> _analyseDifficulty() async {
    if (_disposed) return;
    final gen = ++_difficultyGeneration;
    if (beatmap.mode != 0) {
      difficulty.value = null;
      return;
    }
    final text = OsuWriter.write(beatmap);
    StarAnalysis? result;
    try {
      result = await Isolate.run(() => StarRating.analyse(OsuParser.parse(text)));
    } catch (_) {
      return; // display only: keep the last result
    }
    if (_disposed || gen != _difficultyGeneration) return;
    difficulty.value = result;
  }

  // ---------------------------------------------------------------------------
  // Waveform (timeline, display only)

  Waveform? _waveform;
  int _waveformGeneration = 0;
  Future<void>? _waveformLoad;

  /// The current song's envelope, once decoded (null without audio).
  Waveform? get waveform => _waveform;

  /// Completes when the current waveform decode has been applied.
  Future<void> get waveformLoaded => _waveformLoad ?? Future.value();

  bool get showWaveform => viewSettings.showWaveform;
  set showWaveform(bool v) {
    if (v == viewSettings.showWaveform) return;
    viewSettings.showWaveform = v;
    settings?.save();
    notifyListeners();
  }

  /// Whether the bottom strip shows the whole-map overview.
  bool get showMiniTimeline => viewSettings.showMiniTimeline;
  set showMiniTimeline(bool v) {
    if (v == viewSettings.showMiniTimeline) return;
    viewSettings.showMiniTimeline = v;
    settings?.save();
    notifyListeners();
  }

  /// Whether circles and slider ends play the hit animation at their time
  /// instead of lazer's hit markers (white, fading) — [ObjectVisuals].
  bool get hitAnimations => viewSettings.hitAnimations;
  set hitAnimations(bool v) {
    if (v == viewSettings.hitAnimations) return;
    viewSettings.hitAnimations = v;
    settings?.save();
    notifyListeners();
  }

  /// Whether the playfield shows follow points ([followConnectionsAt]).
  bool get showFollowPoints => viewSettings.showFollowPoints;
  set showFollowPoints(bool v) {
    if (v == viewSettings.showFollowPoints) return;
    viewSettings.showFollowPoints = v;
    settings?.save();
    notifyListeners();
  }

  /// Whether stacked objects are shown (and hit-tested) shifted, as in
  /// the game ([stackOffsetOf]); off, at their file positions.
  bool get showStacking => viewSettings.showStacking;
  set showStacking(bool v) {
    if (v == viewSettings.showStacking) return;
    viewSettings.showStacking = v;
    settings?.save();
    _cacheRevision = -1; // recompute the stacks
    notifyListeners();
  }

  DetailedWaveformLoader? _detailLoader;
  DetailedWaveform? _detail;
  Future<void>? _detailLoad;
  int _detailGeneration = 0;

  /// The song at close to sample resolution for the Timing mode's BPM view,
  /// once [requestDetailedWaveform] has decoded it (null before / without
  /// audio).
  DetailedWaveform? get detailedWaveform => _detail;

  /// Whether a [detailedWaveform] decode is running.
  bool get detailedWaveformLoading => _detailLoad != null && _detail == null;

  /// Starts decoding [detailedWaveform] unless it is there or on its way
  /// (it takes memory and a few seconds, so only the view that shows it
  /// asks). Completes when it has been applied.
  Future<void> requestDetailedWaveform() {
    final loader = _detailLoader;
    if (loader == null) return Future.value();
    final gen = _detailGeneration;
    return _detailLoad ??= () async {
      DetailedWaveform? w;
      try {
        w = await loader();
      } catch (_) {
        w = null;
      }
      if (_disposed || gen != _detailGeneration) return;
      _detail = w;
      if (w == null) _detailLoader = null; // don't retry a failing decode
      notifyListeners();
    }();
  }

  /// Replaces the detailed waveform's source (audio swap); decoded again on
  /// the next request.
  void _attachDetail(DetailedWaveformLoader? loader) {
    _detailGeneration++;
    _detailLoader = loader;
    _detail = null;
    _detailLoad = null;
  }

  /// Replaces the waveform with the result of [pending] (a newer call wins).
  void _attachWaveform(Future<Waveform?>? pending) {
    final gen = ++_waveformGeneration;
    _waveform = null;
    if (pending == null) {
      _waveformLoad = null;
      return;
    }
    _waveformLoad = () async {
      Waveform? w;
      try {
        w = await pending;
      } catch (_) {
        w = null;
      }
      if (_disposed || gen != _waveformGeneration) return;
      _waveform = w;
      notifyListeners();
    }();
  }

  // ---------------------------------------------------------------------------
  // Background image (display only)

  ui.Image? _background;
  String? _backgroundName;
  int _backgroundGeneration = 0;
  Future<void>? _backgroundLoad;
  final ViewSettings _fallbackView = ViewSettings();

  /// The decoded background for the playfield, if any.
  ui.Image? get background => _background;

  /// Completes when the current background (re)load has been applied.
  Future<void> get backgroundLoaded => _backgroundLoad ?? Future.value();

  ViewSettings get viewSettings => settings?.view ?? _fallbackView;

  double get backgroundDim => viewSettings.backgroundDim;

  set backgroundDim(double v) {
    final d = v.clamp(0.0, 1.0);
    if (d == viewSettings.backgroundDim) return;
    viewSettings.backgroundDim = d;
    settings?.save();
    notifyListeners();
  }

  /// The dim actually drawn at [t]: [backgroundDim], lightened during
  /// breaks, the intro and the outro like lazer's gameplay
  /// ([BreakRules.lighteningAt]).
  double backgroundDimAt(double t) {
    _ensureCache();
    final lighten = BreakRules.lighteningAt(_breaks, t, introEnd: _introEnd, outroStart: _outroStart);
    return math.max(0.0, backgroundDim - BreakRules.lightenAmount * lighten);
  }

  /// Loads the image named by the map's background event (again after it
  /// changes, including through undo). Superseded loads are discarded.
  void _reloadBackground() {
    final name = _backgroundName = beatmap.backgroundFilename;
    final loader = backgroundLoader, setPath = document.setPath;
    final gen = ++_backgroundGeneration;
    if (loader == null || setPath == null || name == null || name.isEmpty) {
      _setBackground(null);
      return;
    }
    _backgroundLoad = () async {
      ui.Image? img;
      try {
        img = await loader(setPath, name);
      } catch (_) {
        img = null;
      }
      if (_disposed || gen != _backgroundGeneration) {
        img?.dispose();
        return;
      }
      _setBackground(img);
      notifyListeners();
    }();
  }

  void _setBackground(ui.Image? img) {
    if (identical(img, _background)) return;
    _background?.dispose();
    _background = img;
  }

  // ---------------------------------------------------------------------------
  // Storyboard (display only; loaded once per session — the editor doesn't
  // change storyboard lines)

  LoadedStoryboard? _storyboard;
  Future<void>? _storyboardLoad;

  /// The storyboard to draw, or null (none, still loading, or hidden).
  LoadedStoryboard? get storyboard => showStoryboard ? _storyboard : null;

  /// Whether the map has a storyboard (whether or not it is shown).
  bool get hasStoryboard => _storyboard != null;

  /// Completes when the storyboard load has been applied.
  Future<void> get storyboardLoaded => _storyboardLoad ?? Future.value();

  bool get showStoryboard => viewSettings.showStoryboard;
  set showStoryboard(bool v) {
    if (v == viewSettings.showStoryboard) return;
    viewSettings.showStoryboard = v;
    _cancelScheduled(all: false); // storyboard samples come and go with it
    settings?.save();
    notifyListeners();
  }

  /// osu! hides the plain background when a storyboard sprite shows the
  /// same image.
  bool get storyboardReplacesBackground {
    final sb = storyboard, bg = beatmap.backgroundFilename;
    return sb != null && bg != null && bg.isNotEmpty && sb.storyboard.usesImage(bg);
  }

  void _loadStoryboard() {
    final loader = storyboardLoader, setPath = document.setPath;
    if (loader == null || setPath == null) return;
    _storyboardLoad = () async {
      LoadedStoryboard? sb;
      try {
        sb = await loader(setPath, beatmap);
      } catch (_) {
        sb = null;
      }
      if (_disposed) {
        sb?.dispose();
        return;
      }
      _storyboard = sb;
      _storyboardSamples = [
        for (final e in sb?.storyboard.samples ?? const <StoryboardSample>[])
          SamplePlay(
              time: e.time - storyboardLeadMs, bank: 'normal', name: 'storyboard', volume: e.volume, filename: e.path),
      ];
      _loadStoryboardSamples();
      if (sb != null) notifyListeners();
    }();
  }

  /// Storyboard `Sample` events, fired with the hitsounds while the
  /// storyboard is shown.
  List<SamplePlay> _storyboardSamples = const [];

  /// Loads the storyboard's sound files into the current hitsound output
  /// (again after the audio is swapped).
  void _loadStoryboardSamples() {
    final out = hitsounds, setPath = document.setPath, sb = _storyboard;
    if (out == null || setPath == null || sb == null || sb.storyboard.samples.isEmpty) return;
    out.loadFiles(setPath, sb.storyboard.samplePaths).catchError((_) {});
  }

  // ---------------------------------------------------------------------------
  // UI state

  EditorTool get tool => _tool;
  set tool(EditorTool t) {
    if (t == _tool) return;
    _draft = null;
    _stroke = null;
    _tool = t;
    notifyListeners();
  }

  int get divisor => _divisor;
  set divisor(int d) {
    if (d == _divisor) return;
    _divisor = d;
    notifyListeners();
  }

  // Timeline zoom, as in osu!lazer's editor (Timeline / ZoomableScrollContainer):
  // the zoom is track length / visible milliseconds; by default 6 s are
  // visible (times the map's `[Editor] TimelineZoom`), at most 10 s and at
  // least 0.5 s (never more than the whole track); Alt / Ctrl + wheel adds
  // 2% of the zoom range per step.

  static const timelineDefaultVisibleMs = 6000.0;
  static const timelineMaxVisibleMs = 10000.0;
  static const timelineMinVisibleMs = 500.0;

  /// The length lazer measures zoom against: the song (else the map).
  double get _zoomTrackLength {
    final d = clock.duration;
    if (d != null && d > 0) return d;
    // No song: the map's length (cached per revision, read every frame).
    _ensureCache();
    final objs = beatmap.hitObjects;
    final end = objs.isEmpty ? 0.0 : objs.last.time + _maxDuration;
    return math.max(end + 2000, timelineMaxVisibleMs);
  }

  double _zoomOf(double visibleMs) => math.max(1.0, _zoomTrackLength / visibleMs);

  /// lazer's zoom limits (minimum = 10 s visible, maximum = 0.5 s).
  double get _minZoom => _zoomOf(timelineMaxVisibleMs);
  double get _maxZoom => _zoomOf(timelineMinVisibleMs);

  /// lazer's zoom (track length / visible ms), clamped to its limits.
  double get timelineZoomLevel {
    final v = _timelineVisibleMs;
    if (v == null) {
      final stored = double.tryParse(beatmap.getValue(SectionNames.editor, 'TimelineZoom')?.trim() ?? '');
      final factor = stored == null || stored <= 0 ? 1.0 : stored;
      return (_zoomOf(timelineDefaultVisibleMs) * factor).clamp(_minZoom, _maxZoom).toDouble();
    }
    return (_zoomTrackLength / v).clamp(_minZoom, _maxZoom).toDouble();
  }

  set timelineZoomLevel(double zoom) {
    final z = zoom.clamp(_minZoom, _maxZoom).toDouble();
    final v = _zoomTrackLength / z;
    if (v == _timelineVisibleMs) return;
    _timelineVisibleMs = v;
    notifyListeners();
  }

  /// Milliseconds visible across the top timeline.
  double get timelineVisibleMs => _zoomTrackLength / timelineZoomLevel;

  /// lazer's Alt + wheel: [steps] (positive = in) × 2% of the zoom range.
  void stepTimelineZoom(double steps) =>
      timelineZoomLevel = timelineZoomLevel + steps * (_maxZoom - _minZoom) * 0.02;

  /// Called by the timeline on layout (no notification: it is drawing).
  set timelineWidth(double w) => _timelineWidth = w;

  /// The timeline's scale in logical pixels per millisecond (its width
  /// over [timelineVisibleMs]; a nominal width before its first layout).
  double get timelineZoom => (_timelineWidth > 0 ? _timelineWidth : 640) / timelineVisibleMs;

  /// Sets the scale in px/ms (pinch zoom), kept within lazer's limits.
  set timelineZoom(double pxPerMs) {
    if (pxPerMs <= 0) return;
    final width = _timelineWidth > 0 ? _timelineWidth : 640;
    timelineZoomLevel = _zoomTrackLength / (width / pxPerMs);
  }

  bool get isDirty => history.isDirty;
  String get title =>
      beatmap.title.isEmpty ? document.fileName : '${beatmap.artist} - ${beatmap.title} [${beatmap.version}]';

  // ---------------------------------------------------------------------------
  // Derived data, cached per beatmap revision

  int _cacheRevision = -1;
  late TimingInfo _timing;
  final Expando<ComboInfo> _combo = Expando();
  final Expando<int> _stack = Expando();
  double _maxDuration = 0;
  List<OverlapIssue> _overlaps = const [];
  List<Color> _comboColours = const [];
  Color? _sliderTrack, _sliderBorder;
  List<SamplePlay> _samples = const [];
  List<SliderBodySound> _bodies = const [];
  double _maxBodyDuration = 0;
  List<BreakPeriod> _breaks = const [];
  Map<int, Set<BreakIssue>> _breakIssues = const {};
  List<(double, double)> _insertableBreaks = const [];
  double? _introEnd, _outroStart;
  List<FollowConnection> _followConnections = const [];

  void _ensureCache() {
    if (_cacheRevision == beatmap.revision) return;
    _cacheRevision = beatmap.revision;
    _timing = TimingInfo.of(beatmap);
    _breaks = beatmap.breakPeriods;
    final combos = computeCombos(beatmap.hitObjects, breakEnds: [for (final b in _breaks) b.end]..sort());
    var maxDur = 0.0;
    final sm = beatmap.sliderMultiplier;
    for (var i = 0; i < beatmap.hitObjects.length; i++) {
      final h = beatmap.hitObjects[i];
      _combo[h] = combos[i];
      maxDur = math.max(maxDur, _timing.endTimeOf(h, sm) - h.time);
    }
    _maxDuration = maxDur;
    _computeStacks();
    _overlaps = beatmap.mode != 0
        ? const []
        : findOverlaps(beatmap.hitObjects, endTime: (h) => _timing.endTimeOf(h, sm));
    // The map's colours win over the skin's (osu!'s default "beatmap skin").
    final ini = skin?.ini;
    _comboColours = _parseComboColours(beatmap, ini);
    final track = ComboColours.colourOf(beatmap, ComboColours.sliderTrack) ?? ini?.sliderTrackOverride;
    final border = ComboColours.colourOf(beatmap, ComboColours.sliderBorder) ?? ini?.sliderBorder;
    _sliderTrack = track == null ? null : colourOf(track);
    _sliderBorder = border == null ? null : colourOf(border);
    _samples = hitsounds == null ? const [] : HitsoundResolver.resolve(beatmap, _timing);
    _bodies = hitsounds == null ? const [] : HitsoundResolver.resolveBodies(beatmap, _timing);
    _maxBodyDuration = _bodies.fold(0.0, (m, b) => math.max(m, b.end - b.start));
    final objs = beatmap.hitObjects;
    double endOf(HitObject h) => _timing.endTimeOf(h, sm);
    _breakIssues = {
      for (final p in _breaks)
        if (BreakRules.issues(p, objs, endOf) case final issues when issues.isNotEmpty) p.lineIndex: issues,
    };
    _insertableBreaks = BreakRules.insertable(objs, endOf, _breaks, _breakLeadIn);
    _introEnd = objs.isEmpty ? null : BreakRules.introEnd(objs.first, mode: beatmap.mode, preempt: preempt);
    _outroStart = objs.isEmpty ? null : objs.map(endOf).reduce(math.max);
    _followConnections = beatmap.mode != 0
        ? const []
        : FollowPoints.connect(
            objs,
            isNewCombo: (h) => _combo[h]?.number == 1,
            endTime: endOf,
            endPosition: (h) => (h is SliderObject ? sliderEndPosition(h) : h.position) + (_stackOf(h)),
            position: (h) => h.position + _stackOf(h),
          );
    // Slider paths are keyed by (immutable) object, so they never go stale.
  }

  /// [stackOffsetOf] while the cache is being built.
  Vec2 _stackOf(HitObject h) {
    final n = _stack[h] ?? 0;
    return n == 0 ? Vec2.zero : stackOffset(n, circleRadius);
  }

  /// Follow point connections that may show something at [t] (see
  /// [FollowPoints.pointsAt]), with the preempt they use.
  Iterable<FollowConnection> followConnectionsAt(double t) sync* {
    _ensureCache();
    final cs = _followConnections;
    if (cs.isEmpty) return;
    final pre = FollowPoints.preempt(preempt);
    // Sorted by end (the next object's start); each starts no earlier than
    // the previous one ends.
    var i = Beatmap.lowerBound(cs, t - fadeIn, (c) => c.endTime);
    for (; i < cs.length; i++) {
      final c = cs[i];
      final (from, to) = FollowPoints.lifetime(c, pre, fadeIn);
      if (t >= from && t <= to) yield c;
      if (c.endTime - pre > t) break;
    }
  }

  TimingInfo get timing {
    _ensureCache();
    return _timing;
  }

  // The Hitsound screen's notes, built on first use after each change.
  List<HitsoundNote> _hitsoundNotes = const [];
  int _hitsoundNotesRevision = -1;

  /// Every point where an object sounds, resolved for the Hitsound screen
  /// ([HitsoundLayers]), sorted by time.
  List<HitsoundNote> get hitsoundNotes {
    _ensureHitsoundLayers();
    return _hitsoundNotes;
  }

  final Expando<HitsoundBody> _hitsoundBodies = Expando();

  /// [slider]'s body sound for the Hitsound screen ([HitsoundLayers.bodies]),
  /// or null (custom sample file, zero length).
  HitsoundBody? hitsoundBodyOf(SliderObject slider) {
    _ensureHitsoundLayers();
    return _hitsoundBodies[slider];
  }

  void _ensureHitsoundLayers() {
    _ensureCache();
    if (_hitsoundNotesRevision == _cacheRevision) return;
    _hitsoundNotesRevision = _cacheRevision;
    _hitsoundNotes = HitsoundLayers.notes(beatmap, _timing);
    _hitsoundTicks = HitsoundLayers.ticks(beatmap, _timing);
    for (final b in HitsoundLayers.bodies(beatmap, _timing)) {
      _hitsoundBodies[b.slider] = b;
    }
  }

  List<HitsoundTick> _hitsoundTicks = const [];

  /// Slider ticks ([HitsoundLayers.ticks]) from [from] to [to] (inclusive).
  Iterable<HitsoundTick> hitsoundTicksInRange(double from, double to) sync* {
    _ensureHitsoundLayers();
    final ticks = _hitsoundTicks;
    for (var i = Beatmap.lowerBound(ticks, from, (t) => t.time); i < ticks.length; i++) {
      if (ticks[i].time > to) break;
      yield ticks[i];
    }
  }

  /// [hitsoundNotes] from [from] to [to] (inclusive).
  Iterable<HitsoundNote> hitsoundNotesInRange(double from, double to) sync* {
    final notes = hitsoundNotes;
    for (var i = Beatmap.lowerBound(notes, from, (n) => n.time); i < notes.length; i++) {
      if (notes[i].time > to) break;
      yield notes[i];
    }
  }

  /// Abnormal patterns (overlaps, unsnapped objects), by time.
  List<OverlapIssue> get overlapIssues {
    _ensureCache();
    return _overlaps;
  }

  ComboInfo comboOf(HitObject h) {
    _ensureCache();
    return _combo[h] ?? const ComboInfo(1, 1);
  }

  Color comboColourOf(HitObject h) {
    _ensureCache();
    return comboColourAt(comboOf(h).colourIndex);
  }

  /// The combo colour for [ComboInfo.colourIndex] [index] (wraps around).
  Color comboColourAt(int index) {
    _ensureCache();
    return _comboColours[index % _comboColours.length];
  }

  SliderPath sliderPath(SliderObject s) => SliderPath.cached(s);

  final Expando<(int, List<Vec2>, List<double>)> _tickCache = Expando();

  /// Positions of [s]'s slider ticks (one span; reverse spans reuse them).
  /// Depends on timing too, so cached per revision.
  List<Vec2> sliderTickPositions(SliderObject s) => _ticks(s).$2;

  /// Where along the path (0..1, by distance) each of
  /// [sliderTickPositions] is, i.e. its time within a forward span.
  List<double> sliderTickProgress(SliderObject s) => _ticks(s).$3;

  (int, List<Vec2>, List<double>) _ticks(SliderObject s) {
    final rev = beatmap.revision;
    final hit = _tickCache[s];
    if (hit != null && hit.$1 == rev) return hit;
    final path = sliderPath(s);
    final ds = timing.sliderTickDistances(s, beatmap.sliderMultiplier, beatmap.sliderTickRate,
        formatVersion: beatmap.formatVersion);
    final out = (rev, [for (final d in ds) path.positionAtDistance(d)], [for (final d in ds) d / path.distance]);
    _tickCache[s] = out;
    return out;
  }

  /// Where a slider ends (its tail after an odd number of spans, else its
  /// head).
  Vec2 sliderEndPosition(SliderObject s) => s.slides.isOdd ? sliderPath(s).tail : s.position;

  // Stacking is display-only (osu!standard): objects are drawn and hit-tested
  // at `position + stackOffsetOf(h)`, edits still work on file positions.
  void _computeStacks() {
    final objs = beatmap.hitObjects;
    if (beatmap.mode != 0 || !viewSettings.showStacking) {
      for (final h in objs) {
        _stack[h] = null;
      }
      return;
    }
    final sm = beatmap.sliderMultiplier;
    final heights = computeStackHeights(
      objs,
      preempt: preempt,
      stackLeniency: beatmap.stackLeniency,
      endTime: (h) => _timing.endTimeOf(h, sm),
      endPosition: sliderEndPosition,
    );
    for (var i = 0; i < objs.length; i++) {
      _stack[objs[i]] = heights[i] == 0 ? null : heights[i];
    }
  }

  /// Stack height of [h] (0 = not stacked).
  int stackHeightOf(HitObject h) {
    _ensureCache();
    return _stack[h] ?? 0;
  }

  /// Display shift of [h] caused by stacking (zero for most objects).
  Vec2 stackOffsetOf(HitObject h) {
    final n = stackHeightOf(h);
    return n == 0 ? Vec2.zero : stackOffset(n, circleRadius);
  }

  /// Where [h]'s head is drawn.
  Vec2 displayPositionOf(HitObject h) => h.position + stackOffsetOf(h);

  double endTimeOf(HitObject h) => timing.endTimeOf(h, beatmap.sliderMultiplier);

  double get preempt => OsuRules.preempt(beatmap.approachRate);
  double get fadeIn => OsuRules.fadeIn(beatmap.approachRate);
  double get circleRadius => OsuRules.circleRadius(beatmap.circleSize);

  /// How long objects stay visible after they end, in the editor (lazer's
  /// hit-marker fade, see [ObjectVisuals]).
  static const fadeOut = ObjectVisuals.lingerAfterEnd;

  /// Objects worth drawing at [t], sorted by start time.
  List<HitObject> visibleObjectsAt(double t) {
    _ensureCache();
    final objs = beatmap.hitObjects;
    final out = <HitObject>[];
    var i = Beatmap.lowerBound(objs, t - _maxDuration - fadeOut, (h) => h.time);
    final until = t + preempt;
    for (; i < objs.length && objs[i].time <= until; i++) {
      final h = objs[i];
      if (endTimeOf(h) + fadeOut >= t) out.add(h);
    }
    return out;
  }

  /// Objects overlapping the time range [from, to] (for the timeline).
  Iterable<HitObject> objectsInRange(double from, double to) sync* {
    _ensureCache();
    final objs = beatmap.hitObjects;
    for (var i = Beatmap.lowerBound(objs, from - _maxDuration, (h) => h.time);
        i < objs.length && objs[i].time <= to;
        i++) {
      if (endTimeOf(objs[i]) >= from) yield objs[i];
    }
  }

  /// osu!'s default Combo1..Combo4 (the first combo uses Combo2).
  static const defaultComboColours = [
    Color(0xFFFFC000),
    Color(0xFF00CA00),
    Color(0xFF127CFF),
    Color(0xFFF21839),
  ];

  /// `Combo1`..`Combo8` in file order ([ComboColours.of]), else the
  /// skin's ([skin]), else the default ones. [ComboInfo.colourIndex] picks
  /// from this.
  static List<Color> _parseComboColours(Beatmap b, [SkinIni? skin]) {
    var found = ComboColours.of(b);
    if (found.isEmpty && skin != null) found = skin.comboColours;
    return found.isEmpty ? defaultComboColours : [for (final c in found) colourOf(c)];
  }

  /// The user's skin (`.osk`, app-wide), or null for the built-in look.
  LoadedSkin? get skin => SkinManager.instance.current.value;

  void _onSkinChanged() {
    if (_disposed) return;
    _cacheRevision = -1; // combo / slider colours may come from the skin
    hitsounds?.useSkin(skin?.path);
    notifyListeners();
  }

  static Color colourOf(RgbColour c) => Color.fromARGB(255, c.r, c.g, c.b);
  static RgbColour rgbOf(Color c) =>
      RgbColour((c.r * 255).round(), (c.g * 255).round(), (c.b * 255).round());

  /// The map's own combo colours (empty: it has none, [defaultComboColours]
  /// apply).
  List<RgbColour> get mapComboColours => ComboColours.of(beatmap);

  /// `[Colours]` SliderTrackOverride / SliderBorder of the map (null: not
  /// set — the combo colour / white apply).
  RgbColour? mapColour(String key) => ComboColours.colourOf(beatmap, key);

  /// Sets (or with null removes) a `[Colours]` key such as
  /// [ComboColours.sliderTrack]; one undo step.
  void setMapColour(String key, RgbColour? colour) {
    if (mapColour(key) == colour) return;
    history.execute(SetColourKeyCommand(key, colour));
  }

  /// The slider body colour (`SliderTrackOverride`), null for the combo
  /// colour; and the body border (`SliderBorder`), null for white.
  Color? get sliderTrackColour {
    _ensureCache();
    return _sliderTrack;
  }

  Color? get sliderBorderColour {
    _ensureCache();
    return _sliderBorder;
  }

  /// Replaces the map's combo colours (one undo step; empty = use the
  /// default ones).
  void setComboColours(List<RgbColour> colours) {
    final now = mapComboColours;
    if (now.length == colours.length && [for (var i = 0; i < now.length; i++) now[i] == colours[i]].every((x) => x)) {
      return;
    }
    history.execute(SetComboColoursCommand(colours));
  }

  // ---------------------------------------------------------------------------
  // Transport

  bool get isPlaying => clock.isPlaying;

  /// Called by the screen's Ticker every frame.
  void tick() {
    if (!clock.isPlaying) {
      // The clock stopped by itself (end of track): sync the UI once.
      if (_wasPlaying) {
        _wasPlaying = false;
        _cancelScheduled(); // samples queued past the end of the song
        _stopLoops();
        if (_offsetPending) _applyOffset();
        time.value = clock.currentTime;
        notifyListeners();
      }
      return;
    }
    time.value = clock.currentTime;
    _fireHitsounds();
    _updateLoops();
  }

  bool _wasPlaying = false;

  /// Earliest seekable time: enough lead-in for the first object to fade in.
  double get minTime {
    final objs = beatmap.hitObjects;
    return math.min(0.0, objs.isEmpty ? 0.0 : objs.first.time) - preempt;
  }

  /// Latest seekable time: the end of the song when its length is known.
  double get maxTime {
    final d = clock.duration;
    return d != null && d > 0 ? d - _clockOffsetMs : double.infinity;
  }

  void seek(double ms) {
    final t = ms.clamp(minTime, math.max(minTime, maxTime)).toDouble();
    clock.seek(t);
    time.value = t;
    _resetHitsoundCursor();
  }

  // ---------------------------------------------------------------------------
  // Hitsounds

  /// Map time up to which samples have been played.
  double _hitsoundCursor = 0;

  /// A frame gap longer than this (app was paused, debugger, …) skips the
  /// backlog instead of firing a burst of samples.
  static const _maxHitsoundCatchUp = 250.0;

  /// The map time whose sounds are due now: the music's position less
  /// [mapAudioOffsetMs] (map time t goes with the song at t + that).
  double get _soundTime {
    final c = clock;
    return c is AudioClock ? c.audioTime - mapAudioOffsetMs : c.currentTime;
  }

  /// Samples exactly at the current position still play on the next start.
  /// Body loops restart from the new position on the next frame.
  void _resetHitsoundCursor() {
    _cancelScheduled();
    hitsounds?.stopLongSounds();
    _hitsoundCursor = _soundTime - 0.5;
    _stopLoops();
  }

  // Scheduling: with an engine clock ([HitsoundOutput.canSchedule] and the
  // track's [AudioTrack.engineAnchor]) samples are queued on the mixer up
  // to [_scheduleAhead] of wall time early, each at the exact engine time
  // its music is heard, instead of fired on the frame that passes them
  // (up to a frame, ~16 ms, late). The cursor then runs ahead of the audio.

  /// How far ahead (wall time) samples are scheduled: comfortably more
  /// than a slow frame, small enough that edits are rarely heard late.
  static const _scheduleAhead = 120.0;

  /// Scheduled samples not yet heard: handle and map time.
  final List<(Object, double)> _scheduled = [];

  /// Beatmap revision / hitsound volume the scheduled samples were made with.
  int _scheduledRevision = -1;
  double _scheduledVolume = -1;

  /// Drops scheduled samples that are not heard yet and moves the cursor
  /// back to the audio, so they are scheduled again (after an edit, a
  /// volume change...). [all]: every pending one (seek, pause, speed).
  void _cancelScheduled({bool all = true}) {
    final out = hitsounds;
    if (_scheduled.isEmpty || out == null) {
      _scheduled.clear();
      return;
    }
    final now = _soundTime;
    _scheduled.removeWhere((s) {
      if (!all && s.$2 <= now) return true; // heard (or about to be): just forget it
      out.cancel(s.$1);
      return true;
    });
    if (!all) _hitsoundCursor = math.min(_hitsoundCursor, now);
  }

  bool _metronome = false;

  /// Timing mode: a click on every beat of the timing (accented on the
  /// first beat of each measure) replaces the map's hitsounds and slider
  /// loops. Plays even with hitsounds switched off, at the hitsound volume.
  bool get metronome => _metronome;
  set metronome(bool on) {
    if (on == _metronome) return;
    _metronome = on;
    _resetHitsoundCursor();
  }

  static const _metronomeAccent = SamplePlay(time: 0, bank: SynthSamples.metronomeBank, name: 'accent');
  static const _metronomeBeat = SamplePlay(time: 0, bank: SynthSamples.metronomeBank, name: 'beat');

  /// Slider body loops playing (or scheduled) now, by body, with the
  /// final volume last set on frame-driven ones (-1: scheduled).
  final Map<SliderBodySound, (Object, double)> _loops = Map.identity();

  /// Starts the loops of slider bodies the audio is inside and stops the
  /// rest (ended, or gone after an edit — bodies are rebuilt per revision).
  /// With an engine clock a body is scheduled up to [_scheduleAhead] early:
  /// start, end and the volume changes of green lines inside it land
  /// sample-accurately on the music; otherwise they follow the frames.
  void _updateLoops() {
    final out = hitsounds;
    if (out == null) return;
    final a = audioSettings;
    if (_metronome || !a.hitsoundsEnabled) return _stopLoops();
    _ensureCache();
    final c = clock;
    final now = _soundTime;
    final anchor = out.canSchedule && c is AudioClock ? c.engineTimeAt(now + mapAudioOffsetMs) : null;
    final until = anchor == null ? now : now + _scheduleAhead * c.rate;
    final active = <SliderBodySound>{};
    final b = _bodies;
    for (var i = Beatmap.lowerBound(b, now - _maxBodyDuration, (x) => x.start);
        i < b.length && b[i].start <= until;
        i++) {
      if (b[i].end > now) active.add(b[i]);
    }
    _loops.removeWhere((body, loop) {
      if (active.contains(body)) return false;
      out.stopLoop(loop.$1);
      return true;
    });
    double level(int volume) => volume / 100 * a.hitsoundVolume;
    for (final body in active) {
      final running = _loops[body];
      if (running != null) {
        // Frame-driven loops follow green lines here; scheduled ones carry
        // their volume changes already.
        if (running.$2 >= 0) {
          final v = level(body.volumeAt(now));
          if (v != running.$2) {
            out.setLoopVolume(running.$1, v);
            _loops[body] = (running.$1, v);
          }
        }
        continue;
      }
      if (anchor != null) {
        double at(double t) => anchor + (t - now) / c.rate;
        final h = out.startLoopAt(
          body.sample,
          level(body.volumeAt(now)),
          at(body.start),
          at(body.end),
          [for (final (t, v) in body.volumeChanges) if (t > now) (at(t), level(v))],
        );
        if (h != null) _loops[body] = (h, -1);
      } else if (body.start <= now) {
        final v = level(body.volumeAt(now));
        final h = out.startLoop(body.sample, v, keepSilent: body.volumeChanges.isNotEmpty);
        if (h != null) _loops[body] = (h, v);
      }
    }
  }

  void _stopLoops() {
    final out = hitsounds;
    if (out != null) {
      for (final (h, _) in _loops.values) {
        out.stopLoop(h);
      }
    }
    _loops.clear();
  }

  void _fireHitsounds() {
    final out = hitsounds;
    if (out == null) return;
    final a = audioSettings;
    final c = clock;
    final now = _soundTime;
    // Scheduled samples made from an older map or volume: drop the ones
    // not heard yet and schedule again from here.
    if (_scheduled.isNotEmpty && (_scheduledRevision != beatmap.revision || _scheduledVolume != a.hitsoundVolume)) {
      _cancelScheduled(all: false);
    }
    _scheduled.removeWhere((s) => s.$2 < now - 1000);
    // Engine time of map time t (anchor + (t - now) / rate), when
    // scheduling is possible.
    final anchor = out.canSchedule && c is AudioClock ? c.engineTimeAt(now + mapAudioOffsetMs) : null;
    final until = anchor == null ? now : now + _scheduleAhead * c.rate;
    final from = _hitsoundCursor;
    if (until <= from) return;
    _hitsoundCursor = until;
    if (now - from > _maxHitsoundCatchUp) return;
    _scheduledRevision = beatmap.revision;
    _scheduledVolume = a.hitsoundVolume;

    void emit(SamplePlay p, double t) {
      if (anchor == null || t <= now) {
        out.play(p, a.hitsoundVolume);
        return;
      }
      final h = out.playAt(p, a.hitsoundVolume, anchor + (t - now) / c.rate);
      if (h != null) _scheduled.add((h, t));
    }

    if (_metronome) {
      for (final tick in timing.ticks(from, until, 1)) {
        emit(tick.isMeasureStart ? _metronomeAccent : _metronomeBeat, tick.time);
      }
      return;
    }
    if (!a.hitsoundsEnabled) return;
    _ensureCache();
    final s = _samples;
    for (var i = Beatmap.upperBound(s, from, (p) => p.time); i < s.length && s[i].time <= until; i++) {
      emit(s[i], s[i].time);
    }
    if (!showStoryboard) return;
    final sb = _storyboardSamples;
    for (var i = Beatmap.upperBound(sb, from, (p) => p.time); i < sb.length && sb[i].time <= until; i++) {
      emit(sb[i], sb[i].time);
    }
  }

  // ---------------------------------------------------------------------------
  // Audio settings

  AudioSettings get audioSettings => settings?.audio ?? _fallbackAudio;
  bool get hasAudio => clock is AudioClock;

  /// The latency compensation the clock uses: the user's offset plus, when
  /// [AudioSettings.autoLatency], the device's measured difference from the
  /// reference phone.
  double get effectiveOffsetMs =>
      audioSettings.offsetMs + (audioSettings.autoLatency ? AudioSession.instance.latencyCorrection : 0);

  /// osu!stable/lazer read v3/v4 files 24 ms later than written (lazer
  /// `LegacyBeatmapDecoder.EARLY_VERSION_TIMING_OFFSET`). Applied here, not to
  /// the parsed times, so the file round-trips and shows stable's numbers.
  static const earlyVersionTimingOffsetMs = 24.0;

  /// How much later than map time the song plays: map time t goes with the
  /// music at audio time t + this. [AudioSettings.stableCompensationMs]
  /// (ranked maps are timed early by stable's latency), plus
  /// [earlyVersionTimingOffsetMs] for v3/v4 files. Hitsounds are scheduled
  /// by it, and the playhead and the waveforms are shifted by it.
  double get mapAudioOffsetMs =>
      audioSettings.stableCompensationMs + (beatmap.formatVersion < 5 ? earlyVersionTimingOffsetMs : 0);

  /// The storyboard isn't read 24 ms late in v3/v4 files (only the map's
  /// objects and timing are; lazer's storyboard decoder has no such offset):
  /// storyboard time = map time + this.
  double get storyboardLeadMs => beatmap.formatVersion < 5 ? earlyVersionTimingOffsetMs : 0;

  /// What [AudioClock.offset] is set to: shown time = audio − this.
  double get _clockOffsetMs => effectiveOffsetMs + mapAudioOffsetMs;

  /// Waveforms are in audio time; screen time = audio − this. (The user's
  /// offset counts, the measured device latency doesn't.)
  double get waveformOffsetMs => audioSettings.offsetMs + mapAudioOffsetMs;

  /// A new latency measurement arrived while playing (applied on pause).
  bool _offsetPending = false;

  /// Re-applies the clock offset (a new latency measurement, settings).
  void _applyOffset() {
    final c = clock;
    if (c is! AudioClock || c.offset == _clockOffsetMs) return;
    // Changing it re-seeks the music: an audible jump mid-play. Wait.
    if (c.isPlaying) {
      _offsetPending = true;
      return;
    }
    _offsetPending = false;
    c.offset = _clockOffsetMs;
    time.value = c.currentTime;
    _resetHitsoundCursor();
    notifyListeners();
  }

  void _applyAudioSettings() {
    final c = clock;
    if (c is AudioClock) {
      c.offset = _clockOffsetMs;
      c.track.volume = audioSettings.musicVolume;
    }
  }

  /// `AudioFilename` the current clock was loaded for (or tried to).
  String _audioName;

  /// Why the last audio (re)load produced no sound; null if fine / not tried.
  String? audioError;

  /// Bumped per reload so a slow, superseded load is discarded.
  int _audioGeneration = 0;
  Future<void>? _audioLoad;

  /// Completes when the current audio reload (if any) has been applied.
  Future<void> get audioLoaded => _audioLoad ?? Future.value();

  bool get canChangeSetFiles => library != null && document.setPath != null;

  /// Loads the audio for the current `AudioFilename` and swaps it in,
  /// keeping the playhead position and rate. A missing file falls back to a
  /// silent clock (so undoing an audio change never leaves the wrong music).
  Future<void> _reloadAudio() {
    _audioName = beatmap.audioFilename;
    final loader = audioLoader, setPath = document.setPath;
    if (loader == null || setPath == null) return Future.value();
    final gen = ++_audioGeneration;
    return _audioLoad = () async {
      EditorAudio? audio;
      String? error;
      try {
        audio = await loader(setPath, beatmap);
        if (audio == null) error = 'Audio file "${beatmap.audioFilename}" not found';
      } catch (e) {
        error = 'Could not load audio: $e';
      }
      if (_disposed || gen != _audioGeneration) {
        audio?.clock.dispose();
        audio?.hitsounds.dispose();
        return;
      }
      audioError = error;
      _swapAudio(audio);
    }();
  }

  void _swapAudio(EditorAudio? audio) {
    final at = time.value, rate = clock.rate;
    pause();
    _stopLoops();
    clock.dispose();
    hitsounds?.dispose();
    _clock = audio?.clock ?? StopwatchClock();
    _hitsounds = audio?.hitsounds;
    _settings ??= audio?.settings;
    _loadStoryboardSamples();
    _attachWaveform(audio?.waveform);
    _attachDetail(audio?.detailedWaveform);
    _clock.rate = rate;
    _applyAudioSettings();
    _cacheRevision = -1; // hitsound samples depend on the output
    seek(at);
    notifyListeners();
  }

  /// Copies [file] into the set and makes it the map's audio (undoable;
  /// the file itself stays in the set folder).
  Future<void> importAudioFile(PickedFile file) async {
    final lib = library, setPath = document.setPath;
    if (lib == null || setPath == null) return;
    final name = await lib.addFileToSet(setPath, file.name, file.bytes);
    if (_disposed) return;
    if (name == beatmap.audioFilename) {
      // Same name, possibly new content: reload anyway.
      await _reloadAudio();
      return;
    }
    history.execute(SetValueCommand(SectionNames.general, 'AudioFilename', name));
    await _audioLoad;
  }

  /// Copies [file] into the set and makes it the background (undoable).
  Future<void> importBackgroundFile(PickedFile file) async {
    final lib = library, setPath = document.setPath;
    if (lib == null || setPath == null) return;
    final name = await lib.addFileToSet(setPath, file.name, file.bytes);
    if (_disposed || name == beatmap.backgroundFilename) return;
    history.execute(SetBackgroundCommand(name));
  }

  static const rates = [0.25, 0.5, 0.75, 1.0, 1.5];
  double get rate => clock.rate;
  set rate(double r) {
    if (r == clock.rate) return;
    clock.rate = r;
    _resetHitsoundCursor(); // scheduled samples were timed for the old speed
    notifyListeners();
  }

  void updateAudioSettings(
      {double? offsetMs,
      double? musicVolume,
      double? hitsoundVolume,
      bool? hitsoundsEnabled,
      bool? autoLatency,
      double? stableCompensationMs}) {
    final a = audioSettings;
    final c = clock;
    if (offsetMs != null || autoLatency != null || stableCompensationMs != null) {
      if (offsetMs != null) a.offsetMs = offsetMs;
      if (autoLatency != null) a.autoLatency = autoLatency;
      if (stableCompensationMs != null) a.stableCompensationMs = stableCompensationMs;
      if (c is AudioClock) {
        c.offset = _clockOffsetMs;
        time.value = c.currentTime;
      }
      _resetHitsoundCursor();
    }
    if (musicVolume != null) {
      a.musicVolume = musicVolume;
      if (c is AudioClock) c.track.volume = musicVolume;
    }
    if (hitsoundVolume != null) {
      a.hitsoundVolume = hitsoundVolume;
      _stopLoops(); // restarted next frame at the new volume
    }
    if (hitsoundsEnabled != null) {
      a.hitsoundsEnabled = hitsoundsEnabled;
      _cancelScheduled(all: false);
    }
    settings?.save();
    notifyListeners();
  }

  void seekSnapped(double ms) => seek(timing.snap(ms, divisor));

  void stepBeat({required bool forward}) =>
      seek(timing.stepSnap(time.value, divisor, forward: forward));

  // ---------------------------------------------------------------------------
  // Bookmarks ([Editor] Bookmarks, whole ms). Each change is one undo step.

  /// The bookmark at the current time: within half a snap step of it.
  int? get bookmarkHere {
    final t = time.value;
    final tolerance = math.max(2.0, timing.beatLengthAt(t) / divisor / 2);
    int? best;
    for (final m in beatmap.bookmarks) {
      final d = (m - t).abs();
      if (d <= tolerance && (best == null || d < (best - t).abs())) best = m;
    }
    return best;
  }

  /// Adds a bookmark at the snapped current time, or removes the one here.
  void toggleBookmark() {
    final here = bookmarkHere;
    final marks = beatmap.bookmarks;
    if (here != null) {
      marks.remove(here);
      _setBookmarks(marks, 'Remove bookmark');
    } else {
      final t = timing.snap(time.value, divisor).round();
      _setBookmarks([...marks, t], 'Add bookmark');
    }
  }

  void removeAllBookmarks() {
    if (beatmap.bookmarks.isEmpty) return;
    _setBookmarks(const [], 'Remove all bookmarks');
  }

  /// Seeks to the next / previous bookmark (no-op if there is none).
  void seekBookmark({required bool forward}) {
    final t = time.value;
    final marks = beatmap.bookmarks..sort();
    final next = forward
        ? marks.where((m) => m > t + 0.5).firstOrNull
        : marks.where((m) => m < t - 0.5).lastOrNull;
    if (next != null) seek(next.toDouble());
  }

  void _setBookmarks(List<int> marks, String label) {
    final sorted = marks.toSet().toList()..sort();
    final cmd = sorted.isEmpty
        ? RemoveValueCommand(SectionNames.editor, 'Bookmarks')
        : SetValueCommand(SectionNames.editor, 'Bookmarks', sorted.join(','));
    history.execute(CompositeCommand(label, [cmd]));
  }

  void togglePlay() {
    if (clock.isPlaying) {
      clock.pause();
      _cancelScheduled();
      hitsounds?.stopLongSounds();
      if (_offsetPending) {
        _wasPlaying = false;
        _applyOffset();
      }
      _stopLoops();
      time.value = clock.currentTime;
    } else {
      _resetHitsoundCursor();
      clock.play();
    }
    _wasPlaying = clock.isPlaying;
    notifyListeners();
  }

  void pause() {
    if (!clock.isPlaying) return;
    togglePlay();
  }

  // ---------------------------------------------------------------------------
  // Editing

  bool get canUndo => history.canUndo;
  bool get canRedo => history.canRedo;
  void undo() => _historyStep(undo: true);
  void redo() => _historyStep(undo: false);

  /// The last undo / redo and what it changed: the screen switches to the
  /// mode / panel holding the change and shows a toast. A new value per step.
  final ValueNotifier<HistoryStep?> lastHistoryStep = ValueNotifier(null);

  void _historyStep({required bool undo}) {
    final before = EditSnapshot.of(beatmap);
    if (!(undo ? history.undo() : history.redo())) return;
    _objectTimes = _objectSignature();
    final focus = EditFocus.between(before, beatmap, history.lastStep!);
    _focusOn(focus);
    lastHistoryStep.value = HistoryStep(focus, undo: undo);
  }

  /// Brings an undone / redone change into view: selects the changed objects
  /// still in the map and seeks to the change unless it is already showing.
  void _focusOn(EditFocus f) {
    if (f.area == EditArea.objects && f.objects.isNotEmpty) {
      _selectedPoint = null;
      selection
        ..clear()
        ..addAll(f.objects);
    }
    final t = f.time;
    if (t != null && !_isShowing(f, t)) seek(t);
    notifyListeners();
  }

  bool _isShowing(EditFocus f, double t) {
    final now = time.value;
    switch (f.area) {
      case EditArea.objects:
        // On the playfield: approaching or being played.
        final first = f.objects.firstOrNull;
        final end = first == null ? t : endTimeOf(first);
        return now >= t - preempt && now <= end;
      case EditArea.breaks:
        return beatmap.breaks.any((b) => b.$1 == t && now >= b.$1 && now <= b.$2);
      default:
        return (now - t).abs() < 0.5;
    }
  }

  static Vec2 clampToPlayfield(Vec2 p) => Vec2(
        p.x.clamp(0, OsuRules.playfieldWidth),
        p.y.clamp(0, OsuRules.playfieldHeight),
      );

  /// [p] kept where a slider point may go ([OsuRules.sliderBounds]: on
  /// screen at this CS, a little past the playfield).
  Vec2 clampToSliderBounds(Vec2 p) {
    final b = OsuRules.sliderBounds(beatmap.circleSize);
    return Vec2(p.x.clamp(b.left, b.right), p.y.clamp(b.top, b.bottom));
  }

  /// The box [h]'s head must stay in: the playfield, or for a slider
  /// [OsuRules.sliderBounds].
  ({double left, double top, double right, double bottom}) _headBounds(HitObject h) => h is SliderObject
      ? OsuRules.sliderBounds(beatmap.circleSize)
      : (left: 0, top: 0, right: OsuRules.playfieldWidth, bottom: OsuRules.playfieldHeight);

  /// The range of shifts keeping every head in [_headBounds]: (min, max)
  /// per axis; min > max when none does. Spinners / hold notes are ignored.
  (Vec2, Vec2)? _shiftRange(List<HitObject> objs) {
    var lo = const Vec2(-double.infinity, -double.infinity);
    var hi = const Vec2(double.infinity, double.infinity);
    var any = false;
    for (final h in objs) {
      if (!_movesInSpace(h)) continue;
      any = true;
      final b = _headBounds(h), p = h.position;
      lo = Vec2(math.max(lo.x, b.left - p.x), math.max(lo.y, b.top - p.y));
      hi = Vec2(math.min(hi.x, b.right - p.x), math.min(hi.y, b.bottom - p.y));
    }
    return any ? (lo, hi) : null;
  }

  void placeCircle(Vec2 pos) {
    final t = timing.snap(time.value, divisor);
    final c = _addPlaced(_placed(HitCircle(position: placementPosition(pos, t), time: t)));
    selection
      ..clear()
      ..add(c);
    notifyListeners();
  }

  /// Adds a newly placed object as one undo step. Objects already starting
  /// at its time (a slider by its head) are replaced by it, their
  /// hitsounds kept ([PlacementOps.withSoundsOf]). Returns what was added.
  HitObject _addPlaced(HitObject h) {
    final old = PlacementOps.startingAt(beatmap.hitObjects, h.time);
    if (old.isEmpty) {
      history.execute(AddHitObjectsCommand([h]));
      return h;
    }
    final placed = PlacementOps.withSoundsOf(h, old.first);
    history.execute(
        CompositeCommand('Replace object', [RemoveHitObjectsCommand(old), AddHitObjectsCommand([placed])]));
    return placed;
  }

  /// Topmost object under [pos] (osu!pixels) at time [t], or null.
  /// Earlier objects are drawn on top, so they win ties.
  HitObject? hitTest(Vec2 pos, double t) {
    final r = circleRadius;
    final r2 = r * r;
    HitObject? best;
    var bestDt = double.infinity;
    for (final h in visibleObjectsAt(t)) {
      var hit = false;
      // Test in the object's own (unstacked) space.
      final p = h is Spinner ? pos : pos - stackOffsetOf(h);
      switch (h) {
        case Spinner():
          hit = false; // spinners are selected from the timeline
        case SliderObject():
          hit = h.position.distanceSquaredTo(p) <= r2 || _nearPath(sliderPath(h).vertices, p, r2);
        default:
          hit = h.position.distanceSquaredTo(p) <= r2;
      }
      if (!hit) continue;
      final dt = (h.time - t).abs();
      if (dt < bestDt) {
        best = h;
        bestDt = dt;
      }
    }
    return best;
  }

  /// Whether [p] is within sqrt([r2]) of the polyline [vertices] — the whole
  /// slider body, not just its vertices (a linear slider has only two).
  static bool _nearPath(List<Vec2> vertices, Vec2 p, double r2) {
    for (var i = 0; i < vertices.length; i++) {
      final a = vertices[i];
      if (i == vertices.length - 1) return a.distanceSquaredTo(p) <= r2;
      final ab = vertices[i + 1] - a;
      final len2 = ab.lengthSquared;
      final t = len2 == 0 ? 0.0 : ((p - a).dot(ab) / len2).clamp(0.0, 1.0);
      if ((a + ab * t).distanceSquaredTo(p) <= r2) return true;
    }
    return false;
  }

  void select(HitObject? h, {bool additive = false}) {
    _selectedPoint = null;
    _edgeSlider = null;
    if (!additive) selection.clear();
    if (h != null) {
      if (additive && selection.contains(h)) {
        selection.remove(h);
      } else {
        selection.add(h);
      }
    }
    notifyListeners();
  }

  void clearSelection() {
    if (_draft != null) {
      cancelSlider();
      return;
    }
    if (selection.isEmpty) return;
    _selectedPoint = null;
    _edgeSlider = null;
    selection.clear();
    notifyListeners();
  }

  void deleteSelection() {
    if (selection.isEmpty) return;
    _selectedPoint = null;
    history.execute(RemoveHitObjectsCommand(selection.toList()));
  }

  void toggleNewComboOnSelection() {
    if (selection.isEmpty) return;
    final before = selection.toList();
    final nc = !before.every((h) => h.newCombo);
    // A colour skip only counts with the new-combo bit, so drop it with NC.
    _replaceSelection(
        before, [for (final h in before) h.copyWithBase(newCombo: nc, comboSkip: nc ? null : 0)],
        'Toggle new combo');
  }

  void _replaceSelection(List<HitObject> before, List<HitObject> after, String label) {
    history.execute(ReplaceHitObjectsCommand(before, after, label: label));
    selection
      ..clear()
      ..addAll(after);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Precision placement: a touch drag with a placement tool shows a cursor
  // above the finger (so it doesn't hide the spot) and places on release.

  Vec2? _cursor;

  /// The offset placement cursor (osu!pixels) while dragging, or null.
  Vec2? get placementCursor => _cursor;
  set placementCursor(Vec2? p) {
    if (p == _cursor) return;
    _cursor = p;
    notifyListeners();
  }

  /// Where releasing at [placementCursor] puts the next circle / slider
  /// point (snapping applied), or null.
  Vec2? get placementPreview {
    final p = _cursor;
    if (p == null) return null;
    if (isDrafting) return clampToSliderBounds(snapPosition(p)).roundToInt();
    return placementPosition(p, timing.snap(time.value, divisor), slider: _tool == EditorTool.slider);
  }

  // ---------------------------------------------------------------------------
  // Placement preview (Circle tool, while the finger is down): the circle
  // that releasing would add, drawn as a real one, with the combo numbers /
  // colours of the other objects as they would become.

  /// The circle releasing now would place (position and time snapped, the
  /// toolbox's new combo / colour skip), or null.
  HitCircle? get placementGhost {
    final at = placementPreview;
    if (at == null || _tool != EditorTool.circle || isDrafting) return null;
    final t = timing.snap(time.value, divisor);
    final nc = _placeNewCombo;
    final ghost = HitCircle(position: at, time: t, newCombo: nc, comboSkip: nc ? _placeComboSkip : 0);
    final old = PlacementOps.startingAt(beatmap.hitObjects, t);
    return old.isEmpty ? ghost : PlacementOps.withSoundsOf(ghost, old.first) as HitCircle;
  }

  /// Whether an object already starts at the [placementGhost]'s time:
  /// releasing replaces it ([isBeingReplaced]).
  bool get placementCollides {
    final g = placementGhost;
    return g != null && PlacementOps.startingAt(beatmap.hitObjects, g.time).isNotEmpty;
  }

  final Set<HitObject> _ghostReplaces = Set.identity();

  /// Whether [h] would be replaced by the [placementGhost] (not drawn
  /// while it shows).
  bool isBeingReplaced(HitObject h) {
    final g = placementGhost;
    if (g == null) return false;
    _ensureGhostCombos(g);
    return _ghostReplaces.contains(h);
  }

  // Combos with the ghost inserted, for (revision, time, new combo, skip).
  (int, double, bool, int)? _ghostKey;
  ComboInfo? _ghostCombo;
  final Map<HitObject, ComboInfo> _ghostShifted = Map.identity();

  /// The ghost's combo and the other objects' combos that change with it.
  void _ensureGhostCombos(HitCircle g) {
    _ensureCache();
    final key = (beatmap.revision, g.time, g.newCombo, g.comboSkip);
    // (What is replaced only depends on the time and the map.)
    if (key == _ghostKey) return;
    _ghostKey = key;
    _ghostShifted.clear();
    _ghostReplaces
      ..clear()
      ..addAll(PlacementOps.startingAt(beatmap.hitObjects, g.time));
    final objs = [for (final h in beatmap.hitObjects) if (!_ghostReplaces.contains(h)) h];
    // Where AddHitObjectsCommand would put it: after objects at its time.
    final at = Beatmap.upperBound(objs, g.time, (h) => h.time);
    final list = [...objs.sublist(0, at), g, ...objs.sublist(at)];
    final combos = computeCombos(list, breakEnds: [for (final b in _breaks) b.end]..sort());
    _ghostCombo = combos[at];
    for (var i = at + 1; i < list.length; i++) {
      final h = list[i], now = _combo[h], then = combos[i];
      if (now == null || now.number != then.number || now.colourIndex != then.colourIndex) _ghostShifted[h] = then;
    }
  }

  /// The [placementGhost]'s combo number / colour slot, or null.
  ComboInfo? get placementGhostCombo {
    final g = placementGhost;
    if (g == null) return null;
    _ensureGhostCombos(g);
    return _ghostCombo;
  }

  /// [comboOf] as drawn: with a placement preview showing, the numbers and
  /// colours the objects after it would get. Only for drawing.
  ComboInfo shownComboOf(HitObject h) {
    final g = placementGhost;
    if (g != null) {
      _ensureGhostCombos(g);
      final shifted = _ghostShifted[h];
      if (shifted != null) return shifted;
    }
    return comboOf(h);
  }

  Color shownComboColourOf(HitObject h) => comboColourAt(shownComboOf(h).colourIndex);

  // ---------------------------------------------------------------------------
  // Spinners

  /// Places a spinner at the snapped current time lasting one measure (the
  /// end is adjusted by dragging it on the timeline).
  void placeSpinner() {
    final t = timing.snap(time.value, divisor);
    final tp = timing.redPointAt(t);
    final beats = tp == null || tp.meter <= 0 ? 4 : tp.meter;
    final s = _addPlaced(_placed(Spinner(
      position: Spinner.center,
      time: t,
      endTime: timing.storedTime(t + timing.beatLengthAt(t) * beats),
      newCombo: true,
    )));
    selection
      ..clear()
      ..add(s);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Slider placement: each tap adds a point; tapping a point again toggles
  // it red (a segment boundary). finishSlider (Create / Enter) creates the
  // slider. Its length is the drawn length rounded down to the beat snap.

  List<PathPoint>? _draft;
  double _draftTime = 0;

  bool get isDrafting => _draft != null;
  int get draftPointCount => _draft?.length ?? 0;

  /// The points drawn so far (the last one may be red: it becomes a segment
  /// boundary once another point follows it).
  List<PathPoint> get draftPoints => List.unmodifiable(_draft ?? const <PathPoint>[]);

  /// The slider being drawn, as it would be created (null below 2 points).
  SliderObject? get draftSlider {
    final d = _draft;
    if (d == null || d.length < 2) return null;
    // A red tail is no boundary yet: it must not force a bezier.
    final pts = d.last.red ? [...d.take(d.length - 1), PathPoint(d.last.position)] : d;
    if (lazerSliders) return _typedShaped(_draftTime, _draftSegments(pts));
    return _shaped(_draftTime, pts, _draftType(pts));
  }

  /// The curve type picked in the editor options for new sliders (null =
  /// automatic by point count).
  PathType? get _forcedSliderType => switch (editSettings.defaultSliderType) {
        DefaultSliderType.auto => null,
        DefaultSliderType.bezier => PathType.bezier,
        DefaultSliderType.linear => PathType.linear,
        DefaultSliderType.catmull => PathType.catmull,
      };

  /// stable file format: the chosen type, else [SliderShape.autoType]. Red
  /// anchors only exist on bezier paths, so they win.
  CurveType _draftType(List<PathPoint> pts) {
    final forced = _forcedSliderType;
    if (forced == null || pts.any((p) => p.red)) return SliderShape.autoType(pts);
    return forced.kind;
  }

  /// lazer's slider placement: red points start new segments, and each
  /// segment's type follows its point count (2 linear, 3 perfect curve,
  /// more bezier) unless the editor options force one.
  List<PathPoint> _draftSegments(List<PathPoint> pts, {bool useDefaultType = true}) {
    final forced = useDefaultType ? _forcedSliderType : null;
    final bounds = [0, for (var i = 1; i < pts.length - 1; i++) if (pts[i].red) i, pts.length - 1];
    final out = [for (final p in pts) PathPoint(p.position, red: p.red)];
    for (var k = 0; k < bounds.length - 1; k++) {
      out[bounds[k]] = out[bounds[k]].withType(forced ?? LazerPath.autoSegmentType(bounds[k + 1] - bounds[k] + 1));
    }
    return out;
  }

  /// The head of the slider being drawn (shown before a second point exists).
  Vec2? get draftHead => _draft?.first.position;

  /// Slider tool tap at [pos]. A tap within [tolerance] (osu!pixels) of a
  /// drawn point (or snapping onto it) taps that point again: it toggles
  /// red, except the head, which ignores the tap.
  void sliderToolTap(Vec2 pos, {double tolerance = 8}) {
    final d = _draft;
    if (d == null) {
      _draftTime = timing.snap(time.value, divisor);
      _draft = [PathPoint(placementPosition(pos, _draftTime, slider: true))];
      notifyListeners();
      return;
    }
    final p = clampToSliderBounds(snapPosition(pos)).roundToInt();
    final raw = clampToSliderBounds(pos);
    int? hit;
    var best = double.infinity;
    for (var i = d.length - 1; i >= 0; i--) {
      final dist = d[i].position == p ? 0.0 : d[i].position.distanceTo(raw);
      if (dist <= tolerance && dist < best) {
        hit = i;
        best = dist;
      }
    }
    if (hit == null) {
      d.add(PathPoint(p));
    } else if (hit > 0) {
      d[hit] = PathPoint(d[hit].position, red: !d[hit].red);
    }
    notifyListeners();
  }

  /// Creates the drawn slider (needs at least two points).
  void finishSlider() {
    final drawn = draftSlider;
    _draft = null;
    if (drawn != null) {
      final s = _addPlaced(_placed(drawn));
      selection
        ..clear()
        ..add(s);
      _selectedPoint = null;
    }
    notifyListeners();
  }

  void cancelSlider() {
    if (_draft == null) return;
    _draft = null;
    notifyListeners();
  }

  // Freehand sliders (a drag with the Slider tool): the finger's path becomes a slider.

  List<Vec2>? _stroke;
  double _strokeTime = 0;

  /// The stroke being drawn with the Slider tool (osu!pixels), or null.
  List<Vec2>? get freehandStroke => _stroke;

  /// Starts a freehand slider at [pos] (snapped like a placed circle) at
  /// the snapped current time.
  void beginFreehand(Vec2 pos) {
    if (history.inTransaction) return;
    pause();
    _strokeTime = timing.snap(time.value, divisor);
    _stroke = [placementPosition(pos, _strokeTime, slider: true)];
    notifyListeners();
  }

  void updateFreehand(Vec2 pos) {
    final s = _stroke;
    if (s == null) return;
    s.add(clampToSliderBounds(pos));
    notifyListeners();
  }

  /// Fits the stroke with bezier pieces ([FreehandFit]) and places it as a
  /// slider (length snapped to the beat like a drawn one; in lazer's path
  /// model when the set keeps that format). One undo step; the slider ends
  /// up selected. Returns it, or null when the stroke was too short.
  SliderObject? endFreehand() {
    final stroke = _stroke;
    _stroke = null;
    final pts = stroke == null ? null : FreehandFit.fit(stroke);
    if (pts == null || pts.length < 2) {
      notifyListeners();
      return null;
    }
    final drawn = lazerSliders
        ? _typedShaped(_strokeTime, _draftSegments(pts, useDefaultType: false))
        : _shaped(_strokeTime, pts, pts.length == 2 ? CurveType.linear : CurveType.bezier);
    final s = _addPlaced(_placed(drawn)) as SliderObject;
    selection
      ..clear()
      ..add(s);
    _selectedPoint = null;
    notifyListeners();
    return s;
  }

  void cancelFreehand() {
    if (_stroke == null) return;
    _stroke = null;
    notifyListeners();
  }

  /// A slider through [points] at [t], its length snapped to the beat.
  /// Hitsound / combo fields come from [base].
  SliderObject _shaped(double t, List<PathPoint> points, CurveType type, {SliderObject? base}) {
    if (type == CurveType.perfectCircle && points.length != 3) type = CurveType.bezier;
    final all = SliderShape.encode(points);
    final length =
        timing.snapSliderLength(SliderShape.fullLength(type, all), t, beatmap.sliderMultiplier, divisor);
    final n = base?.slides ?? 1;
    return SliderObject(
      position: all.first,
      time: t,
      curveType: type,
      controlPoints: all.sublist(1),
      slides: n,
      length: length,
      edgeSounds: base?.edgeSounds,
      edgeSets: base?.edgeSets,
      newCombo: base?.newCombo ?? false,
      comboSkip: base?.comboSkip ?? 0,
      hitSound: base?.hitSound ?? 0,
      sample: base?.sample ?? HitSample.empty,
    );
  }

  /// A slider in lazer's path model through [points] (their [PathPoint.type]s
  /// start segments) at [t], made valid like lazer (`EnsureValidPathTypes`),
  /// its length snapped to the beat. With [keepLength] (lazer's curve type
  /// change) that length is kept unless the new path is shorter.
  SliderObject _typedShaped(double t, List<PathPoint> points, {SliderObject? base, double? keepLength}) {
    final positions = [for (final p in points) p.position];
    final types = LazerPath.ensureValid(positions, [for (final p in points) p.type]);
    if (types.length > 1) types[types.length - 1] = null; // starts nothing
    final full = SliderPath.fromTypedPoints(positions, types, 0).distance;
    var length = timing.snapSliderLength(full, t, beatmap.sliderMultiplier, divisor);
    if (keepLength != null && full >= keepLength) length = keepLength;
    return SliderObject(
      position: positions.first,
      time: t,
      curveType: types.first!.kind,
      controlPoints: positions.sublist(1),
      pointTypes: types,
      slides: base?.slides ?? 1,
      length: length,
      edgeSounds: base?.edgeSounds,
      edgeSets: base?.edgeSets,
      newCombo: base?.newCombo ?? false,
      comboSkip: base?.comboSkip ?? 0,
      hitSound: base?.hitSound ?? 0,
      sample: base?.sample ?? HitSample.empty,
    );
  }

  /// Converts every slider in osu!lazer's format to stable's (bezier curves
  /// of the same shape), as one undo step. Returns how many.
  int convertSlidersToStable() {
    final command = SliderFormatOps.convertToStable(beatmap);
    if (command == null) return 0;
    final n = SliderFormatOps.lazerSliders(beatmap).length;
    history.execute(command);
    selection.clear();
    notifyListeners();
    return n;
  }

  // ---------------------------------------------------------------------------
  // Editing the selected slider's path

  /// Whether [s] is edited with lazer's rules ([lazerSliders]).
  bool editsTyped(SliderObject s) => lazerSliders || s.isLazerPath;

  /// The editable control points of [s]: lazer's model (with segment
  /// types) when [editsTyped], else stable's (red anchors).
  List<PathPoint> editablePoints(SliderObject s) =>
      editsTyped(s) ? SliderShape.typedOf(s) : SliderShape.decode(s.allPoints);

  /// The slider whose control points are shown (exactly one selected).
  SliderObject? get editedSlider {
    if (selection.length != 1) return null;
    final s = selection.first;
    return s is SliderObject ? s : null;
  }

  int? _selectedPoint;

  /// Selected control point of [editedSlider] (index into its PathPoints).
  int? get selectedPoint {
    final s = editedSlider, i = _selectedPoint;
    if (s == null || i == null) return null;
    return i < editablePoints(s).length ? i : null;
  }

  set selectedPoint(int? i) {
    if (i == _selectedPoint) return;
    _selectedPoint = i;
    notifyListeners();
  }

  /// Index of the control point of [editedSlider] nearest [pos] within
  /// [radius], or null.
  int? hitTestControlPoint(Vec2 pos, double radius) {
    final s = editedSlider;
    if (s == null) return null;
    final pts = editablePoints(s);
    final at = pos - stackOffsetOf(s);
    int? best;
    var bestD = radius;
    for (var i = 0; i < pts.length; i++) {
      final d = pts[i].position.distanceTo(at);
      if (d <= bestD) {
        best = i;
        bestD = d;
      }
    }
    return best;
  }

  /// Applies [edit] to the edited slider's points and reshapes it (length
  /// re-snapped). [edit] returns null to cancel.
  void _editPoints(String label, List<PathPoint>? Function(List<PathPoint> pts) edit, {CurveType? type}) {
    final s = editedSlider;
    if (s == null) return;
    final pts = edit(editablePoints(s));
    if (pts == null) return;
    if (editsTyped(s)) {
      _replaceSelection([s], [_typedShaped(s.time, pts, base: s)], label);
      return;
    }
    var t = type ?? s.curveType;
    if (pts.any((p) => p.red)) t = CurveType.bezier;
    _replaceSelection([s], [_shaped(s.time, pts, t, base: s)], label);
  }

  /// The curve types the point menu offers for the edited slider when it is
  /// edited the stable way (one type for the whole path, like stable's
  /// slider menu): Bezier, Perfect circle (three points only), Catmull,
  /// Linear. Empty when edited the lazer way ([pointTypeChoices]), and for
  /// two points (every type is the same straight line).
  List<CurveType> get curveTypeChoices {
    final s = editedSlider;
    if (s == null || editsTyped(s)) return const [];
    final n = editablePoints(s).length;
    if (n < 3) return const [];
    return [CurveType.bezier, if (n == 3) CurveType.perfectCircle, CurveType.catmull, CurveType.linear];
  }

  /// The edited slider's curve type as stable shows it (bezier whenever it
  /// has red anchors).
  CurveType? get curveTypeState {
    final s = editedSlider;
    if (s == null) return null;
    return editablePoints(s).any((p) => p.red) ? CurveType.bezier : s.curveType;
  }

  bool get canSetCurveType => !lockNotes && !history.inTransaction && curveTypeChoices.isNotEmpty;

  /// Whether point [index] of the edited slider can be made (or unmade) a
  /// red anchor in the point menu: stable-format sliders, not the ends.
  bool canToggleRedAnchor(int index) {
    final s = editedSlider;
    if (s == null || editsTyped(s) || lockNotes || history.inTransaction) return false;
    return index > 0 && index < editablePoints(s).length - 1;
  }

  /// Whether point [index] of the edited (stable-format) slider is a red
  /// anchor.
  bool isRedAnchor(int index) {
    final s = editedSlider;
    if (s == null || editsTyped(s)) return false;
    final pts = editablePoints(s);
    return index >= 0 && index < pts.length && pts[index].red;
  }

  /// Toggles point [index] (default: the selected one) between a red
  /// anchor and an ordinary point (one undo step; the path becomes bezier).
  void toggleRedAnchor([int? index]) {
    final i = index ?? selectedPoint;
    if (i == null) return;
    final s = editedSlider;
    if (s != null && editsTyped(s)) {
      // lazer: a point with its own type starts a new segment.
      final pts = editablePoints(s);
      if (i == 0 || i >= pts.length - 1) return;
      setPointType(i, pts[i].type != null ? null : _segmentTypeAt(pts, i));
      return;
    }
    _editPoints('Toggle red anchor', (pts) {
      if (i == 0 || i == pts.length - 1) return null;
      pts[i] = PathPoint(pts[i].position, red: !pts[i].red);
      return pts;
    });
  }

  /// Inserts a point halfway between the selected point (or the head) and
  /// the next one; after the tail it extends the last segment by half.
  void insertControlPoint() {
    final s = editedSlider;
    if (s == null) return;
    final pts = editablePoints(s);
    if (pts.length < 2) return;
    final i = math.min(selectedPoint ?? 0, pts.length - 1);
    final p = i < pts.length - 1
        ? Vec2.lerp(pts[i].position, pts[i + 1].position, 0.5)
        : clampToSliderBounds(pts[i].position + (pts[i].position - pts[i - 1].position) * 0.5);
    _editPoints('Add control point', (pts) => pts..insert(i + 1, PathPoint(p.roundToInt())),
        type: _typeAfterInsert(s, pts.length));
    _selectedPoint = i + 1;
    notifyListeners();
  }

  /// The leg of [editedSlider]'s control polygon (the lines joining its
  /// points) within [tolerance] osu!pixels of [pos] (as displayed): the
  /// index the new point would get and the nearest point on that leg
  /// (whole pixels). Null off the legs, or when that spot is a point.
  (int, Vec2)? controlLegAt(Vec2 pos, {double tolerance = 8}) {
    final s = editedSlider;
    if (s == null) return null;
    final at = pos - stackOffsetOf(s);
    final pts = editablePoints(s);
    (int, Vec2)? best;
    var bestD = tolerance;
    for (var i = 0; i < pts.length - 1; i++) {
      final q = _nearestOnSegment(at, pts[i].position, pts[i + 1].position);
      final d = q.distanceTo(at);
      if (d <= bestD) {
        bestD = d;
        best = (i + 1, q.roundToInt());
      }
    }
    if (best == null || pts.any((q) => q.position == best!.$2)) return null;
    return best;
  }

  /// Whether [insertControlPointAt] would add a point at [pos]: on a leg of
  /// the edited slider's control polygon, notes not locked.
  bool canInsertControlPointAt(Vec2 pos, {double tolerance = 8}) =>
      !lockNotes && !history.inTransaction && controlLegAt(pos, tolerance: tolerance) != null;

  /// lazer's "Add control point" (Ctrl+click, or the long-press menu's Add):
  /// inserts a point on the control polygon leg under [pos] (see
  /// [controlLegAt]) and selects it, as one undo step. Returns its index,
  /// or null when [canInsertControlPointAt] is false. A two-point slider
  /// becomes a perfect circle, a perfect circle becomes bezier.
  int? insertControlPointAt(Vec2 pos, {double tolerance = 8}) {
    final s = editedSlider;
    if (s == null || !canInsertControlPointAt(pos, tolerance: tolerance)) return null;
    final (at, p) = controlLegAt(pos, tolerance: tolerance)!;
    final n = editablePoints(s).length;
    _editPoints('Add control point', (pts) => pts..insert(at, PathPoint(p)), type: _typeAfterInsert(s, n));
    _selectedPoint = at;
    notifyListeners();
    return at;
  }

  static Vec2 _nearestOnSegment(Vec2 p, Vec2 a, Vec2 b) {
    final ab = b - a;
    final len2 = ab.lengthSquared;
    final t = len2 == 0 ? 0.0 : ((p - a).dot(ab) / len2).clamp(0.0, 1.0);
    return a + ab * t;
  }

  /// Curve type once a point is added to [s], which had [points] points:
  /// two points → perfect circle; a perfect circle with a fourth point
  /// turns bezier in [_shaped]; other types are kept.
  static CurveType _typeAfterInsert(SliderObject s, int points) =>
      points == 2 ? CurveType.perfectCircle : s.curveType;

  /// Whether a point of [editedSlider] can be deleted (it keeps two).
  bool get canDeleteControlPoint {
    final s = editedSlider;
    return s != null && !lockNotes && !history.inTransaction && editablePoints(s).length > 2;
  }

  /// Deletes point [index] of [editedSlider] (default: the selected one) as
  /// one undo step; never below two points. A perfect circle left with two
  /// points becomes linear.
  void deleteControlPoint([int? index]) {
    final i = index ?? selectedPoint, s = editedSlider;
    if (i == null || s == null || !canDeleteControlPoint) return;
    final n = editablePoints(s).length;
    if (i >= n) return;
    _editPoints('Delete control point', (pts) {
      // lazer: the first point must have a type; the next one inherits it.
      if (i == 0 && pts.length > 1 && pts[1].type == null) pts[1] = pts[1].withType(pts[0].type);
      return pts..removeAt(i);
    },
        type: n == 3 && s.curveType == CurveType.perfectCircle ? CurveType.linear : null);
    _selectedPoint = math.max(0, i - 1);
    notifyListeners();
  }

  void setCurveType(CurveType type) {
    final s = editedSlider;
    if (s == null || s.curveType == type) return;
    _editPoints(
      'Change curve type',
      // Red anchors only exist on bezier paths; in lazer's model the whole
      // path becomes one segment of [type].
      (pts) => editsTyped(s)
          ? [for (var i = 0; i < pts.length; i++) PathPoint(pts[i].position, type: i == 0 ? PathType(type) : null)]
          : type == CurveType.bezier
              ? pts
              : [for (final p in pts) PathPoint(p.position)],
      type: type,
    );
  }

  /// The curve types [setPointType] offers for point [index] of the edited
  /// slider, like lazer's control point menu: Inherit (null; not for the
  /// head), Linear, Bezier, Perfect curve, B-spline, and Catmull only for a
  /// point that already is one. Empty for the last point (it starts no
  /// segment) or when not editing the lazer way.
  List<PathType?> pointTypeChoices(int index) {
    final s = editedSlider;
    if (s == null || !editsTyped(s)) return const [];
    final pts = editablePoints(s);
    if (index < 0 || index >= pts.length - 1) return const [];
    return [
      if (index > 0) null,
      PathType.linear,
      PathType.bezier,
      PathType.perfectCurve,
      PathType.bSpline4,
      if (pts[index].type == PathType.catmull) PathType.catmull,
    ];
  }

  /// The curve type point [index] of the edited slider starts (null =
  /// inherits its segment's), when editing the lazer way.
  PathType? pointType(int index) {
    final s = editedSlider;
    if (s == null || !editsTyped(s)) return null;
    final pts = editablePoints(s);
    return index >= 0 && index < pts.length ? pts[index].type : null;
  }

  /// Whether [setPointType] can change point [index] now.
  bool canSetPointType(int index) =>
      !lockNotes && !history.inTransaction && pointTypeChoices(index).isNotEmpty;

  /// lazer's "Curve type" for one control point (one undo step): the point
  /// starts a segment of [type] (null: joins the previous segment). Making
  /// it a perfect curve splits off the rest of a longer segment two points
  /// later (an arc has three points). The length is kept unless the new
  /// path is shorter (then snapped).
  void setPointType(int index, PathType? type) {
    final s = editedSlider;
    if (s == null || !canSetPointType(index) || (index == 0 && type == null)) return;
    final pts = editablePoints(s);
    if (pts[index].type == type) return;
    if (type == PathType.perfectCurve) {
      var start = index;
      while (start > 0 && pts[start].type == null) {
        start--;
      }
      var end = index + 1;
      while (end < pts.length - 1 && pts[end].type == null) {
        end++;
      }
      if (index + 2 < end) pts[index + 2] = pts[index + 2].withType(pts[start].type);
    }
    pts[index] = pts[index].withType(type);
    _replaceSelection([s], [_typedShaped(s.time, pts, base: s, keepLength: s.length)], 'Change curve type');
  }

  /// The type of the segment point [i] of [pts] belongs to (a perfect
  /// curve's is bezier: a split arc can't stay one).
  static PathType _segmentTypeAt(List<PathPoint> pts, int i) {
    while (i > 0 && pts[i].type == null) {
      i--;
    }
    final t = pts[i].type ?? PathType.bezier;
    return t == PathType.perfectCurve ? PathType.bezier : t;
  }

  void setSlides(int slides) {
    final s = editedSlider;
    if (s == null || slides < 1 || slides == s.slides) return;
    _replaceSelection([s], [_withSlides(s, slides)], 'Change repeats');
  }

  static SliderObject _withSlides(SliderObject s, int n) => s.copyWith(
        slides: n,
        edgeSounds: SliderShape.resizeEdges(s.edgeSounds, n, 0),
        edgeSets: SliderShape.resizeEdges(s.edgeSets, n, const EdgeSet(0, 0)),
      );

  // Control point drag: one transaction; every update reshapes the original
  // (like the move drag), so a drag back to the start is a no-op.
  SliderObject? _pointDragOriginal;
  SliderObject? _pointDragCurrent;
  int _pointDragIndex = 0;
  Vec2 _pointDragStack = Vec2.zero;

  void beginPointDrag(int index) {
    final s = editedSlider;
    if (lockNotes || s == null || history.inTransaction) return;
    _selectedPoint = _pointDragIndex = index;
    _pointDragOriginal = _pointDragCurrent = s;
    // The handle is shown stacked; keep that shift for the whole drag.
    _pointDragStack = stackOffsetOf(s);
    history.beginTransaction('Move control point');
    notifyListeners();
  }

  void updatePointDrag(Vec2 pos) {
    final orig = _pointDragOriginal, cur = _pointDragCurrent;
    if (orig == null || cur == null) return;
    final pts = editablePoints(orig);
    // The head stays on screen ([clampToSliderBounds]); other points may go
    // anywhere (osu! allows it).
    final snapped = snapPosition(pos - _pointDragStack);
    final p = (_pointDragIndex == 0 ? clampToSliderBounds(snapped) : snapped).roundToInt();

    final SliderObject next;
    if (pts[_pointDragIndex].position == p) {
      next = orig;
    } else {
      pts[_pointDragIndex] = pts[_pointDragIndex].withPosition(p);
      next = editsTyped(orig)
          ? _typedShaped(orig.time, pts, base: orig)
          : _shaped(orig.time, pts, orig.curveType, base: orig);
    }
    if (identical(next, cur)) return;
    history.execute(ReplaceHitObjectsCommand([cur], [next], label: 'Move control point'));
    _pointDragCurrent = next;
    selection
      ..clear()
      ..add(next);
    notifyListeners();
  }

  /// [cancel] reverts the drag (e.g. a second finger turned it into a pinch).
  void endPointDrag({bool cancel = false}) {
    final orig = _pointDragOriginal;
    if (orig == null) return;
    final moved = !cancel && !identical(_pointDragCurrent, orig);
    _pointDragOriginal = _pointDragCurrent = null;
    if (moved) {
      history.commitTransaction();
    } else {
      history.cancelTransaction();
      _restoreSelection([orig]);
    }
  }

  // ---------------------------------------------------------------------------
  // Breaks (edited on the timeline)

  /// The map's breaks, sorted by start.
  List<BreakPeriod> get breaks {
    _ensureCache();
    return _breaks;
  }

  /// Whether lazer would flag [b] (see [breakIssues]).
  bool isBreakInvalid(BreakPeriod b) => breakIssues(b).isNotEmpty;

  /// What lazer would flag about [b] (empty when nothing).
  Set<BreakIssue> breakIssues(BreakPeriod b) {
    _ensureCache();
    return _breakIssues[b.lineIndex] ?? const {};
  }

  /// Default breaks for the object gaps that are long enough and have none.
  List<(double, double)> get insertableBreaks {
    _ensureCache();
    return _insertableBreaks;
  }

  /// Breaks the user adjusted by dragging, by (start, end): like lazer's
  /// `ManualBreakPeriod` they survive [_regenerateBreaks] (unless an object
  /// ends up inside them). Session only — the file can't tell them apart.
  final Set<(double, double)> _manualBreaks = {};

  double _breakLeadIn(HitObject next) =>
      BreakRules.leadIn(mode: beatmap.mode, preempt: preempt, beatLength: timing.beatLengthAt(next.time));

  /// Every object's (start, end), to regenerate breaks only when they change.
  List<double> _objectTimes = const [];

  List<double> _objectSignature() {
    // Its own TimingInfo: also runs in the constructor, before the caches.
    final t = TimingInfo.of(beatmap);
    final sm = beatmap.sliderMultiplier;
    return [
      for (final h in beatmap.hitObjects) ...[h.time, t.endTimeOf(h, sm)],
    ];
  }

  /// [EditHistory.followUp]: after an edit that changed when objects are
  /// (not on opening the map, so an unedited file stays as it is), redo
  /// the breaks like lazer's editor: automatic ones are dropped and every
  /// gap that can hold a break gets the longest allowed one
  /// ([BreakRules.regenerate]); manual ones stay while valid. A regenerated
  /// break identical to an existing line keeps that line.
  EditCommand? _regenerateBreaks() {
    final sig = _objectSignature();
    if (listEquals(sig, _objectTimes)) return null;
    _objectTimes = sig;
    final current = beatmap.breakPeriods;
    final (kept, added) = BreakRules.regenerate(
        beatmap.hitObjects, endTimeOf, current, (b) => _manualBreaks.contains((b.start, b.end)), _breakLeadIn);
    final keptLines = {for (final b in kept) b.lineIndex};
    final remove = {for (final b in current) if (!keptLines.contains(b.lineIndex)) b.lineIndex};
    final add = <(int, int)>[];
    for (final (s, e) in added) {
      final same = current.where((b) => remove.contains(b.lineIndex) && b.start == s && b.end == e).firstOrNull;
      if (same != null) {
        remove.remove(same.lineIndex);
      } else {
        add.add((s.round(), e.round()));
      }
    }
    if (remove.isEmpty && add.isEmpty) return null;
    return ReplaceBreaksCommand(remove, add);
  }

  /// Adds the break [at] (one of [insertableBreaks]). Undoable.
  void addBreak((double, double) at) {
    if (history.inTransaction) return;
    history.execute(AddBreakCommand(at.$1.round(), at.$2.round()));
  }

  /// Whether [b] may be deleted: not when it sits in a gap long enough for
  /// a break ([BreakRules.suggested]), since such a gap must keep one (the
  /// next edit would bring it back). Breaks overlapping an object or outside
  /// the objects can always go.
  bool canRemoveBreak(BreakPeriod b) {
    final objects = beatmap.hitObjects;
    final bad = BreakRules.issues(b, objects, endTimeOf);
    if (bad.contains(BreakIssue.overlapsObject) || bad.contains(BreakIssue.outsideObjects)) return true;
    for (final (prevEnd, nextStart, next) in BreakRules.objectGaps(objects, endTimeOf)) {
      if (prevEnd <= b.start && nextStart >= b.end) {
        return BreakRules.suggested(prevEnd, nextStart, _breakLeadIn(next)) == null;
      }
    }
    return true;
  }

  /// Deletes [b] unless its gap must hold a break ([canRemoveBreak]).
  /// Undoable. Returns whether it was deleted.
  bool removeBreak(BreakPeriod b) {
    if (history.inTransaction || !canRemoveBreak(b)) return false;
    history.execute(RemoveBreakCommand(b.lineIndex));
    return true;
  }

  BreakPeriod? _breakDrag;
  bool _breakDragEnd = false;
  bool _breakDragChanged = false;
  ((double, double), (double, double)) _breakLimits = ((0, 0), (0, 0));

  /// The break whose edge is being dragged (current times) and whether it
  /// is the end edge, or null.
  (BreakPeriod, bool)? get breakDrag {
    final d = _breakDrag;
    if (d == null) return null;
    return (breaks.firstWhere((b) => b.lineIndex == d.lineIndex, orElse: () => d), _breakDragEnd);
  }

  /// Starts dragging [b]'s start (or [end]) edge. One undo step.
  bool beginBreakDrag(BreakPeriod b, {required bool end}) {
    if (history.inTransaction) return false;
    _breakDrag = b;
    _breakDragEnd = end;
    _breakDragChanged = false;
    _breakLimits = BreakRules.limits(b, beatmap.hitObjects, endTimeOf, breaks);
    history.beginTransaction('Change break');
    notifyListeners();
    return true;
  }

  /// Moves the dragged edge to the nearest snap of [t], kept clear of the
  /// neighbouring objects and at least [BreakRules.minDuration] long.
  void updateBreakDrag(double t) {
    final d = _breakDrag;
    if (d == null) return;
    final cur = breakDrag!.$1;
    final (lo, hi) = _breakDragEnd ? _breakLimits.$2 : _breakLimits.$1;
    final v = timing.snap(t, divisor).clamp(lo, hi).roundToDouble();
    final start = _breakDragEnd ? cur.start : v, end = _breakDragEnd ? v : cur.end;
    if (start == cur.start && end == cur.end) return;
    history.execute(SetBreakCommand(d.lineIndex, start.round(), end.round()));
    _breakDragChanged = true;
  }

  void endBreakDrag() {
    if (_breakDrag == null) return;
    final moved = breakDrag!.$1;
    _breakDrag = null;
    if (_breakDragChanged) {
      _manualBreaks.add((moved.start, moved.end));
      history.commitTransaction();
    } else {
      history.cancelTransaction();
    }
  }

  // ---------------------------------------------------------------------------
  // Timeline end drag: spinner end time / slider repeat count

  HitObject? _endDragOriginal;
  HitObject? _endDragCurrent;

  /// The selected object whose end can be dragged on the timeline.
  HitObject? get endDraggable {
    if (selection.length != 1) return null;
    final h = selection.first;
    return h is Spinner || h is SliderObject ? h : null;
  }

  void beginEndDrag() {
    final h = endDraggable;
    if (h == null || history.inTransaction) return;
    _endDragOriginal = _endDragCurrent = h;
    history.beginTransaction(h is Spinner ? 'Change spinner length' : 'Change repeats');
  }

  /// Moves the dragged end to time [t]: a spinner ends on the nearest snap
  /// (at least one snap long), a slider gets the nearest whole repeat count.
  void updateEndDrag(double t) {
    final orig = _endDragOriginal, cur = _endDragCurrent;
    if (orig == null || cur == null) return;
    final HitObject next;
    switch (orig) {
      case Spinner():
        final minEnd = orig.time + timing.beatLengthAt(orig.time) / divisor;
        final end = timing.storedTime(math.max(minEnd, timing.snap(t, divisor)));
        next = (end - orig.endTime).abs() < 1e-6 ? orig : orig.copyWith(endTime: end);
      case SliderObject():
        final span = timing.sliderSpanDuration(orig, beatmap.sliderMultiplier);
        final n = span <= 0 ? orig.slides : math.max(1, ((t - orig.time) / span).round());
        next = n == orig.slides ? orig : _withSlides(orig, n);
      default:
        return;
    }
    if (identical(next, cur)) return;
    history.execute(ReplaceHitObjectsCommand([cur], [next], label: 'Change length'));
    _endDragCurrent = next;
    selection
      ..clear()
      ..add(next);
    notifyListeners();
  }

  void endEndDrag() {
    if (_endDragOriginal == null) return;
    final changed = !identical(_endDragCurrent, _endDragOriginal);
    _endDragOriginal = _endDragCurrent = null;
    if (changed) {
      history.commitTransaction();
    } else {
      history.cancelTransaction();
    }
  }

  // Drag-move: originals are captured at start; each update replaces the
  // current copies with `original + totalDelta`, inside one transaction.
  List<HitObject>? _dragOriginals;
  List<HitObject>? _dragCurrent;

  /// Earliest moved (non-spinner) object, and the distance snap ring it is
  /// kept on (around the object before the selection), if any.
  HitObject? _dragAnchor;
  Vec2 _dragAnchorOffset = Vec2.zero;
  (Vec2, double)? _moveGuide;

  /// The distance snap ring while dragging the selection (for the painter).
  (Vec2, double)? get moveSnapGuide => _dragOriginals == null ? null : _moveGuide;

  void beginMoveSelection() {
    if (lockNotes || selection.isEmpty || history.inTransaction) return;
    final orig = selection.toList();
    _dragOriginals = orig;
    _dragCurrent = orig;
    final movable = orig.where((h) => h is! Spinner).toList()..sort((a, b) => a.time.compareTo(b.time));
    _dragAnchor = movable.firstOrNull;
    final a = _dragAnchor;
    _dragAnchorOffset = a == null ? Vec2.zero : stackOffsetOf(a);
    _moveGuide = a == null ? null : distanceSnapGuide(a.time, exclude: LinkedHashSet.identity()..addAll(orig));
    history.beginTransaction('Move objects');
  }

  void updateMoveSelection(Vec2 totalDelta) {
    final orig = _dragOriginals, cur = _dragCurrent;
    if (orig == null || cur == null) return;
    final anchor = _dragAnchor?.position;
    if (anchor != null) {
      // Distance snap keeps the earliest (non-spinner) object on the ring,
      // then grid snap puts it on the grid (the grid wins, as in stable and
      // lazer).
      // The ring is around the previous object as drawn, so it holds the
      // anchor as drawn (with its stack offset at the start).
      final off = _dragAnchorOffset;
      totalDelta = snapPosition(_ringSnapped(anchor + off + totalDelta, _moveGuide) - off) - anchor;
    }
    final d = _clampDelta(orig, totalDelta.roundToInt());
    // Zero delta → back to the original instances (keeps their sourceLine,
    // so a no-op drag doesn't rewrite lines in the saved file).
    final next = d == Vec2.zero ? orig : [for (final h in orig) h.translated(d)];
    if (identical(next, cur)) return;
    history.execute(ReplaceHitObjectsCommand(cur, next, label: 'Move objects'));
    _dragCurrent = next;
    selection
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  /// [cancel] reverts the drag (e.g. a second finger turned it into a pinch).
  void endMoveSelection({bool cancel = false}) {
    final orig = _dragOriginals;
    if (orig == null) return;
    final moved = !cancel && !identical(_dragCurrent, orig);
    _dragOriginals = _dragCurrent = null;
    _dragAnchor = null;
    _moveGuide = null;
    if (moved) {
      history.commitTransaction();
    } else {
      history.cancelTransaction();
      _restoreSelection(orig);
    }
  }

  /// After a cancelled drag: select the original instances again.
  void _restoreSelection(List<HitObject> objs) {
    selection
      ..clear()
      ..addAll(objs.where((h) => beatmap.indexOfHitObject(h) >= 0));
    notifyListeners();
  }

  /// Keeps object heads inside their bounds while dragging ([_headBounds]:
  /// circles on the playfield, sliders on screen). Heads already outside
  /// may stay put or move back in, never further out.
  Vec2 _clampDelta(List<HitObject> objs, Vec2 d) {
    final range = _shiftRange(objs);
    if (range == null) return Vec2.zero;
    final (lo, hi) = range;
    return Vec2(
      d.x.clamp(math.min(lo.x, 0), math.max(hi.x, 0)),
      d.y.clamp(math.min(lo.y, 0), math.max(hi.y, 0)),
    );
  }

  // ---------------------------------------------------------------------------
  // Selection productivity: select all, box select, clipboard, moving in
  // time, flip / rotate. Each edit is one undo step.

  /// Selects every object (and switches to the Select tool, like stable).
  void selectAll() {
    _draft = null;
    _tool = EditorTool.select;
    _selectedPoint = null;
    selection
      ..clear()
      ..addAll(beatmap.hitObjects);
    notifyListeners();
  }

  // Box selection: a Select-tool drag that starts on empty playfield.
  // The selection updates live; additive keeps what was selected before.
  Vec2? _boxStart;
  Vec2? _boxEnd;
  List<HitObject> _boxBase = const [];

  /// Corners of the box being dragged (osu!pixels), or null.
  (Vec2, Vec2)? get selectionBox {
    final a = _boxStart, b = _boxEnd;
    return a == null || b == null ? null : (a, b);
  }

  void beginBoxSelect(Vec2 pos, {bool additive = false}) {
    _selectedPoint = null;
    _boxStart = _boxEnd = pos;
    _boxBase = additive ? selection.toList() : const [];
    _applyBox();
  }

  void updateBoxSelect(Vec2 pos) {
    if (_boxStart == null) return;
    _boxEnd = pos;
    _applyBox();
  }

  void endBoxSelect() {
    if (_boxStart == null) return;
    _boxStart = _boxEnd = null;
    _boxBase = const [];
    notifyListeners();
  }

  /// Objects shown at the current time whose head is inside the box
  /// (spinners are selected from the timeline).
  void _applyBox() {
    final (a, b) = selectionBox!;
    final minX = math.min(a.x, b.x), maxX = math.max(a.x, b.x);
    final minY = math.min(a.y, b.y), maxY = math.max(a.y, b.y);
    selection
      ..clear()
      ..addAll(_boxBase);
    for (final h in visibleObjectsAt(time.value)) {
      if (h is Spinner) continue;
      final p = displayPositionOf(h);
      if (p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY) selection.add(h);
    }
    notifyListeners();
  }

  /// Shared by every open editor, so objects can be copied between the
  /// difficulties of a set.
  static List<HitObject> _clipboard = const [];

  int get clipboardCount => _clipboard.length;

  void copySelection() {
    if (selection.isEmpty) return;
    _clipboard = selection.toList()..sort((a, b) => a.time.compareTo(b.time));
    notifyListeners();
  }

  void cutSelection() {
    if (selection.isEmpty) return;
    copySelection();
    deleteSelection();
  }

  /// Pastes the clipboard so its first object starts at the snapped current
  /// time (positions kept) and selects the pasted objects.
  void paste() {
    if (_clipboard.isEmpty) return;
    final d = timing.snap(time.value, divisor) - _clipboard.first.time;
    final pasted = [
      for (final h in _clipboard)
        // A map edited the stable way gets stable sliders only.
        if (h is SliderObject && h.isLazerPath && !lazerSliders)
          SliderFormatOps.toStable(h).shiftedInTime(d)
        else
          h.shiftedInTime(d),
    ];
    history.execute(AddHitObjectsCommand(pasted));
    _draft = null;
    _tool = EditorTool.select;
    _selectedPoint = null;
    selection
      ..clear()
      ..addAll(pasted);
    notifyListeners();
  }

  /// Moves the selection one beat-snap step earlier / later: its first
  /// object goes to the neighbouring snap, the rest keep their spacing.
  void moveSelectionInTime({required bool forward}) {
    if (selection.isEmpty) return;
    final before = selection.toList();
    final first = before.map((h) => h.time).reduce(math.min);
    final target = timing.stepSnap(timing.snap(first, divisor), divisor, forward: forward);
    final d = target - first;
    if (d.abs() < 1e-6 || target < 0) return;
    _replaceSelection(before, [for (final h in before) h.shiftedInTime(d)], 'Move in time');
  }

  /// Moves the selection by ([dx], [dy]) osu!pixels as one undo step
  /// (spinners stay put). Heads can't leave the playfield: a nudge past the
  /// edge does nothing.
  void nudgeSelection(double dx, double dy) =>
      _transformSelection('Nudge', (p) => p + Vec2(dx, dy));

  /// Pivot of flips and the rotate / scale dialog. Flips default to the
  /// playfield's centre line, like stable (copy → paste → flip).
  TransformPivot get pivot => editSettings.pivotSelection ? TransformPivot.selection : TransformPivot.playfield;
  set pivot(TransformPivot p) {
    if (p != pivot) _setEdit((e) => e.pivotSelection = p == TransformPivot.selection);
  }

  /// Whether the Scale panel leaves slider nodes alone (sliders only move
  /// with their heads): the Scale panel, the selection box's corners and
  /// two-finger scaling. Off by default.
  bool get scaleKeepsSliderShape => editSettings.scaleKeepsSliderShape;
  set scaleKeepsSliderShape(bool v) {
    if (v != scaleKeepsSliderShape) _setEdit((e) => e.scaleKeepsSliderShape = v);
  }

  /// Whether scaling keeps the width / height ratio: the Scale panel (one
  /// slider), the selection box's corners and two fingers. Unlocked, the
  /// panel has Width / Height, corners follow the finger in both axes and
  /// two fingers stretch along their spread (without turning). One setting
  /// for the panel and the box's lock button. On by default.
  bool get scaleLocksAspect => editSettings.scaleLocksAspect;
  set scaleLocksAspect(bool v) {
    if (v != scaleLocksAspect) _setEdit((e) => e.scaleLocksAspect = v);
  }

  /// Mirrors the selection across the [pivot]'s vertical (horizontal flip,
  /// stable's Ctrl+H) or horizontal (Ctrl+J) line.
  void flipSelection({required bool horizontal}) {
    final c = _pivotPoint(selection, pivot);
    if (c == null) return;
    _transformSelection(
      horizontal ? 'Flip horizontally' : 'Flip vertically',
      (p) => horizontal ? Vec2(2 * c.x - p.x, p.y) : Vec2(p.x, 2 * c.y - p.y),
    );
  }

  /// Rotates the selection by 90° around the centre of its bounds.
  void rotateSelection({required bool clockwise}) {
    final c = _pivotPoint(selection, TransformPivot.selection);
    if (c == null) return;
    // Screen y points down, so (dx, dy) → (−dy, dx) turns clockwise.
    _transformSelection(
      clockwise ? 'Rotate clockwise' : 'Rotate counter-clockwise',
      (p) => clockwise ? Vec2(c.x - (p.y - c.y), c.y + (p.x - c.x)) : Vec2(c.x + (p.y - c.y), c.y - (p.x - c.x)),
    );
  }

  /// lazer's Reverse (Ctrl+G): mirrors the selection in time inside its own
  /// time range and runs sliders backwards; new combos stay in place.
  void reverseSelection() {
    if (selection.isEmpty) return;
    final (before, after) = PatternOps.reversed(selection.toList(),
        endTime: endTimeOf, pathOf: sliderPath, storedTime: timing.storedTime);
    if (before.isEmpty) return;
    final kept = [for (final h in selection) if (!before.contains(h)) h];
    history.execute(ReplaceHitObjectsCommand(before, after, label: 'Reverse'));
    _selectedPoint = null;
    selection
      ..clear()
      ..addAll(kept)
      ..addAll(after);
    notifyListeners();
  }

  /// Whether the selection has a slider to convert to a stream.
  bool get canConvertToStream => selection.any((h) => h is SliderObject);

  /// lazer's "Convert to stream" (Ctrl+Shift+F): replaces each selected
  /// slider with circles every current beat snap along its path, as one
  /// undo step. The circles join the selection.
  void convertSelectionToStream() {
    final sliders = [for (final h in selection) if (h is SliderObject) h];
    if (sliders.isEmpty) return;
    final sm = beatmap.sliderMultiplier;
    final circles = [
      for (final s in sliders)
        ...PatternOps.sliderToStream(
          s,
          path: sliderPath(s),
          spanDuration: timing.sliderSpanDuration(s, sm),
          spacing: timing.beatLengthAt(s.time) / divisor,
          storedTime: timing.storedTime,
        ),
    ];
    history.execute(CompositeCommand('Convert to stream', [
      RemoveHitObjectsCommand(sliders),
      AddHitObjectsCommand(circles),
    ]));
    _selectedPoint = null;
    selection
      ..removeAll(sliders)
      ..addAll(circles);
    notifyListeners();
  }

  /// Whether the selection can be merged into one slider ([mergeSelection]).
  bool get canMergeSelection => PatternOps.canMerge(selection);

  /// lazer's "Merge selection" (Ctrl+Shift+M): the selected circles and
  /// sliders become one slider from the first one's head through the others
  /// ([PatternOps.merged]), its length rounded to the nearest beat snap.
  /// One undo step; the slider ends up selected.
  void mergeSelection() {
    if (history.inTransaction) return;
    final items = [for (final h in selection) if (h is HitCircle || h is SliderObject) h];
    if (items.isEmpty) return;
    final start = items.map((h) => h.time).reduce(math.min);
    final merged = PatternOps.merged(
      items,
      lazerFormat: lazerSliders,
      lengthOf: (l) {
        // To the nearest beat snap (a drawn slider rounds down; here that
        // could stop well short of the last object).
        final step = timing.sliderLengthStep(start, beatmap.sliderMultiplier, divisor);
        return step > 0 ? math.max(1, (l / step).round()) * step : l;
      },
    );
    if (merged == null) return;
    final (removed, slider) = merged;
    history.execute(CompositeCommand('Merge', [
      RemoveHitObjectsCommand(removed),
      AddHitObjectsCommand([slider]),
    ]));
    _selectedPoint = null;
    _edgeSlider = null;
    selection
      ..clear()
      ..add(slider);
    notifyListeners();
  }

  static List<Vec2> _pointsOf(HitObject h) => h is SliderObject ? h.allPoints : [h.position];

  static bool _movesInSpace(HitObject h) => h is! Spinner && h is! HoldNote;

  /// The playfield centre, or the whole-pixel centre of the bounds of
  /// [objs]' points (whole pixels keep rotated whole-pixel points whole).
  /// Null if nothing in [objs] has a position that transforms.
  static Vec2? _pivotPoint(Iterable<HitObject> objs, TransformPivot pivot) {
    final pts = [for (final h in objs) if (_movesInSpace(h)) ..._pointsOf(h)];
    if (pts.isEmpty) return null;
    if (pivot == TransformPivot.playfield) {
      return const Vec2(OsuRules.playfieldWidth / 2, OsuRules.playfieldHeight / 2);
    }
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final p in pts) {
      minX = math.min(minX, p.x);
      minY = math.min(minY, p.y);
      maxX = math.max(maxX, p.x);
      maxY = math.max(maxY, p.y);
    }
    return Vec2((minX + maxX) / 2, (minY + maxY) / 2).roundToInt();
  }

  /// Maps the positions of the selected objects (spinners stay put) as one
  /// undo step; see [_transformed].
  void _transformSelection(String label, Vec2 Function(Vec2) f) {
    final moving = [for (final h in selection) if (_movesInSpace(h)) h];
    if (moving.isEmpty) return;
    final next = _transformed(moving, f);
    if (next == null || identical(next, moving)) return;
    final kept = [for (final h in selection) if (!_movesInSpace(h)) h];
    history.execute(ReplaceHitObjectsCommand(moving, next, label: label));
    selection
      ..clear()
      ..addAll(next)
      ..addAll(kept);
    notifyListeners();
  }

  /// [objs] with their positions mapped by [f] (rounded to whole pixels),
  /// shifted back inside the playfield if heads left it. [f] scales by
  /// [scale] across and [scaleY] (default [scale]) down; slider lengths are
  /// re-snapped when either isn't 1: multiplied by [scale] when both match,
  /// otherwise the drawn path mapped by [f] is measured again. Returns
  /// [objs] itself when nothing changes, null when the heads can't all fit
  /// (e.g. a wide pattern turned upright). With [keepSliderShape] (and a
  /// scale other than 1), sliders aren't scaled: their heads go where [f]
  /// puts them and their nodes keep their distances, turned by [turn]
  /// radians (the rotation part of [f]); lengths stay.
  List<HitObject>? _transformed(List<HitObject> objs, Vec2 Function(Vec2) f,
      {double scale = 1, double? scaleY, bool keepSliderShape = false, double turn = 0, bool shiftToFit = true}) {
    final sy = scaleY ?? scale;
    final scaled = scale != 1 || sy != 1;
    final cos = math.cos(turn), sin = math.sin(turn);
    double lengthOf(SliderObject before) {
      if (sy == scale) return before.length * scale;
      final v = sliderPath(before).vertices;
      var l = 0.0;
      for (var i = 1; i < v.length; i++) {
        l += (f(v[i]) - f(v[i - 1])).length;
      }
      return l;
    }

    var next = [
      for (final h in objs)
        if (keepSliderShape && scaled && h is SliderObject)
          h.transformed((p) {
            final head = f(h.position), d = p - h.position;
            return Vec2(head.x + d.x * cos - d.y * sin, head.y + d.x * sin + d.y * cos).roundToInt();
          })
        else
          switch (h.transformed((p) => f(p).roundToInt())) {
            final SliderObject s when scaled => s.copyWith(
                length: timing.snapSliderLength(
                    lengthOf(h as SliderObject), s.time, beatmap.sliderMultiplier, divisor)),
            final t => t,
          },
    ];
    final d = _fitDelta(next);
    if (d == null || (!shiftToFit && d != Vec2.zero)) return null;
    if (d != Vec2.zero) next = [for (final h in next) h.translated(d)];
    for (var i = 0; i < objs.length; i++) {
      final a = objs[i], b = next[i];
      if (a is SliderObject && b is SliderObject && a.length != b.length) return next;
      final pa = _pointsOf(a), pb = _pointsOf(b);
      for (var j = 0; j < pa.length; j++) {
        if (pa[j] != pb[j]) return next;
      }
    }
    return objs;
  }

  // Rotate / scale dialog: a live preview inside one transaction; every
  // update transforms the originals again.
  List<HitObject>? _xfOriginals;
  List<HitObject> _xfCurrent = const [];
  List<HitObject> _xfKept = const [];

  bool get isTransforming => _xfOriginals != null;

  String _xfLabel = 'Rotate / scale';

  /// Rotations within this many degrees of a right angle (0, 90, 180,
  /// 270°) snap to it: the rotate panel's slider, the selection box's
  /// handle and two-finger turns.
  static const rightAngleSnapDegrees = 6.0;

  /// [degrees] snapped to the nearest right angle when within
  /// [rightAngleSnapDegrees] of it.
  static double snapRightAngle(double degrees) {
    final q = (degrees / 90).roundToDouble() * 90;
    return (degrees - q).abs() <= rightAngleSnapDegrees ? q : degrees;
  }

  /// Starts a rotate / scale preview of the selection. Returns false if
  /// there is nothing to transform (or another edit is in progress).
  /// [label] names the undo step ("Rotate", "Scale").
  bool beginTransform({String label = 'Rotate / scale'}) {
    if (_xfOriginals != null || history.inTransaction) return false;
    _xfLabel = label;
    final moving = [for (final h in selection) if (_movesInSpace(h)) h];
    if (moving.isEmpty) return false;
    _xfOriginals = _xfCurrent = moving;
    _xfKept = [for (final h in selection) if (!_movesInSpace(h)) h];
    history.beginTransaction(label);
    return true;
  }

  /// Shows the originals rotated by [degrees] (clockwise on screen) and
  /// scaled by [scale] around [pivot] — across by [scale] and down by
  /// [scaleY] when that is given (after the turn, along the playfield's
  /// axes). Returns false (showing the originals) if the result doesn't fit
  /// the playfield. With [keepSliderShape], sliders keep their nodes and
  /// length and only move with their heads.
  bool updateTransform({double degrees = 0, double scale = 1, double? scaleY, bool keepSliderShape = false}) {
    final orig = _xfOriginals;
    if (orig == null) return false;
    final c = _pivotPoint(orig, pivot)!;
    final a = degrees * math.pi / 180;
    final cos = math.cos(a), sin = math.sin(a);
    final sy = scaleY ?? scale;
    final next = _transformed(orig, (p) {
      final d = p - c;
      return Vec2(c.x + (d.x * cos - d.y * sin) * scale, c.y + (d.x * sin + d.y * cos) * sy);
    }, scale: scale, scaleY: sy, keepSliderShape: keepSliderShape, turn: a);
    final shown = next ?? orig;
    if (!identical(shown, _xfCurrent)) {
      history.execute(ReplaceHitObjectsCommand(_xfCurrent, shown, label: _xfLabel));
      _xfCurrent = shown;
      selection
        ..clear()
        ..addAll(shown)
        ..addAll(_xfKept);
      notifyListeners();
    }
    return next != null;
  }

  // ---------------------------------------------------------------------------
  // Selection box (lazer's): a rectangle around the selected objects with
  // corner handles (scale) and a rotation handle; two fingers on it rotate,
  // scale and move the selection directly. All go through the transform
  // preview above (one undo step per gesture).

  /// Whether the selection box shows: Select tool, at least two objects
  /// that move in space or one slider, no slider being drawn.
  bool get showsSelectionBox {
    if (_tool != EditorTool.select || isDrafting) return false;
    var n = 0;
    for (final h in selection) {
      if (!_movesInSpace(h)) continue;
      if (h is SliderObject) return true;
      n++;
    }
    return n >= 2;
  }

  /// The selection box in osu!pixels, as drawn (stack offsets, slider
  /// paths, circle radius around): (min, max). Null without one.
  (Vec2, Vec2)? get selectionBounds {
    if (!showsSelectionBox) return null;
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    void add(Vec2 p) {
      minX = math.min(minX, p.x);
      minY = math.min(minY, p.y);
      maxX = math.max(maxX, p.x);
      maxY = math.max(maxY, p.y);
    }

    for (final h in selection) {
      if (!_movesInSpace(h)) continue;
      final o = stackOffsetOf(h);
      add(h.position + o);
      if (h is SliderObject) {
        for (final v in sliderPath(h).vertices) {
          add(v + o);
        }
      }
    }
    if (!minX.isFinite) return null;
    final r = circleRadius;
    return (Vec2(minX - r, minY - r), Vec2(maxX + r, maxY + r));
  }

  /// The free transform shown now (for a readout): degrees, scale across,
  /// scale down.
  (double, double, double)? get freeTransformShown => _freeShown;
  (double, double, double)? _freeShown;

  /// Shows the selection (as when the transform began) scaled by [scale]
  /// (down by [scaleY] when given: the selection box's side handles) and
  /// rotated by [radians] (clockwise on screen) around [pivot], then
  /// moved by [offset] (osu!pixels). A result that doesn't fit the
  /// playfield keeps the last one that did (heads outside are shifted back
  /// in unless [shiftToFit] is false: a handle drag must keep the pivot
  /// side fixed). Needs [beginTransform].
  /// Sliders keep their size with [scaleKeepsSliderShape].
  bool updateFreeTransform(
      {required Vec2 pivot,
      double radians = 0,
      double scale = 1,
      double? scaleY,
      Vec2 offset = Vec2.zero,
      bool shiftToFit = true}) {
    final orig = _xfOriginals;
    if (orig == null) return false;
    final cos = math.cos(radians), sin = math.sin(radians);
    final sy = scaleY ?? scale;
    final next = _transformed(orig, (p) {
      final d = p - pivot;
      return Vec2(pivot.x + (d.x * cos - d.y * sin) * scale + offset.x,
          pivot.y + (d.x * sin + d.y * cos) * sy + offset.y);
    }, scale: scale, scaleY: sy, keepSliderShape: scaleKeepsSliderShape, turn: radians, shiftToFit: shiftToFit);
    if (next == null) return false;
    _freeShown = (radians * 180 / math.pi, scale, sy);
    if (!identical(next, _xfCurrent)) {
      history.execute(ReplaceHitObjectsCommand(_xfCurrent, next, label: _xfLabel));
      _xfCurrent = next;
      selection
        ..clear()
        ..addAll(next)
        ..addAll(_xfKept);
    }
    notifyListeners();
    return true;
  }

  /// Keeps the previewed transform as one undo step ([apply]) or reverts it.
  void endTransform({required bool apply}) {
    final orig = _xfOriginals;
    if (orig == null) return;
    _freeShown = null;
    final changed = !identical(_xfCurrent, orig);
    final shown = apply && changed ? _xfCurrent : orig;
    final kept = _xfKept;
    _xfOriginals = null;
    _xfCurrent = _xfKept = const [];
    if (apply && changed) {
      history.commitTransaction();
    } else {
      history.cancelTransaction();
    }
    selection
      ..clear()
      ..addAll(shown)
      ..addAll(kept);
    notifyListeners();
  }

  /// The smallest shift that brings object heads back inside their bounds
  /// ([_headBounds]), or null if no shift does.
  Vec2? _fitDelta(List<HitObject> objs) {
    final range = _shiftRange(objs);
    if (range == null) return Vec2.zero;
    final (lo, hi) = range;
    if (lo.x > hi.x || lo.y > hi.y) return null;
    double fit(double lo, double hi) => lo > 0 ? lo : (hi < 0 ? hi : 0);
    return Vec2(fit(lo.x, hi.x), fit(lo.y, hi.y));
  }

  // Timeline: dragging a selected object moves the selection in time (the
  // grabbed object lands on the beat snap); a long-press drag selects the
  // objects starting inside a time range.
  List<HitObject>? _timeDragOriginals;
  List<HitObject> _timeDragCurrent = const [];
  HitObject? _timeDragAnchor;

  bool get isTimeDragging => _timeDragOriginals != null;

  /// Starts moving the selection in time by dragging [grabbed] (selected).
  bool beginTimeDrag(HitObject grabbed) {
    if (lockNotes || !selection.contains(grabbed) || history.inTransaction) return false;
    _timeDragOriginals = _timeDragCurrent = selection.toList();
    _timeDragAnchor = grabbed;
    history.beginTransaction('Move in time');
    return true;
  }

  /// Puts the grabbed object on the beat snap nearest [anchorTime]; the
  /// rest keep their offsets. Nothing moves before 0 (the earliest stops
  /// there).
  void updateTimeDrag(double anchorTime) {
    final orig = _timeDragOriginals, anchor = _timeDragAnchor;
    if (orig == null || anchor == null) return;
    var d = timing.snap(anchorTime, divisor) - anchor.time;
    final first = orig.map((h) => h.time).reduce(math.min);
    if (first + d < 0) d = -first;
    final next = d.abs() < 1e-6 ? orig : [for (final h in orig) h.shiftedInTime(d)];
    if (identical(next, _timeDragCurrent)) return;
    history.execute(ReplaceHitObjectsCommand(_timeDragCurrent, next, label: 'Move in time'));
    _timeDragCurrent = next;
    selection
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  void endTimeDrag() {
    final orig = _timeDragOriginals;
    if (orig == null) return;
    final moved = !identical(_timeDragCurrent, orig);
    _timeDragOriginals = _timeDragAnchor = null;
    _timeDragCurrent = const [];
    if (moved) {
      history.commitTransaction();
    } else {
      history.cancelTransaction();
    }
  }

  double? _rangeStart, _rangeEnd;
  List<HitObject> _rangeBase = const [];

  /// The time range being box-selected on the timeline, or null.
  (double, double)? get timelineBox {
    final a = _rangeStart, b = _rangeEnd;
    return a == null || b == null ? null : (math.min(a, b), math.max(a, b));
  }

  void beginTimelineBox(double t, {bool additive = false}) {
    _selectedPoint = null;
    _rangeStart = _rangeEnd = t;
    _rangeBase = additive ? selection.toList() : const [];
    _applyTimelineBox();
  }

  void updateTimelineBox(double t) {
    if (_rangeStart == null) return;
    _rangeEnd = t;
    _applyTimelineBox();
  }

  void endTimelineBox() {
    if (_rangeStart == null) return;
    _rangeStart = _rangeEnd = null;
    _rangeBase = const [];
    notifyListeners();
  }

  /// Every object (spinners too) starting inside the range.
  void _applyTimelineBox() {
    final (from, to) = timelineBox!;
    final objs = beatmap.hitObjects;
    selection
      ..clear()
      ..addAll(_rangeBase);
    for (var i = Beatmap.lowerBound(objs, from, (h) => h.time); i < objs.length && objs[i].time <= to; i++) {
      selection.add(objs[i]);
    }
    notifyListeners();
  }

  /// Stable's clipboard text for the selection, e.g. `00:01:234 (1,2,3) - `
  /// (time of the earliest object, combo numbers in time order).
  String? get selectionTimestamp {
    if (selection.isEmpty) return null;
    final objs = selection.toList()..sort((a, b) => a.time.compareTo(b.time));
    return EditorTimestamp(objs.first.time.round(), [for (final h in objs) comboOf(h).number]).format();
  }

  /// Seeks to [ts] and selects the objects it names: from its time on, the
  /// next object with each listed combo number in turn (how stable follows
  /// modding links). Returns how many were selected.
  int goToTimestamp(EditorTimestamp ts) {
    pause();
    seek(ts.time.toDouble());
    _draft = null;
    _tool = EditorTool.select;
    _selectedPoint = null;
    selection.clear();
    final objs = beatmap.hitObjects;
    var i = Beatmap.lowerBound(objs, ts.time - 1.0, (h) => h.time);
    for (final n in ts.combos) {
      // Only look a little ahead, so a wrong number doesn't jump far away.
      final stop = math.min(objs.length, i + 64);
      var j = i;
      while (j < stop && comboOf(objs[j]).number != n) {
        j++;
      }
      if (j >= stop) break;
      selection.add(objs[j]);
      i = j + 1;
    }
    notifyListeners();
    return selection.length;
  }

  // ---------------------------------------------------------------------------
  // Timing points

  /// Adds a red (uninherited) or green (inherited) point at the snapped
  /// current time, copying BPM / meter / SV / sample settings from the
  /// points in effect there. If a point of that kind already sits at that
  /// time it is returned instead of adding a duplicate.
  TimingPoint addTimingPoint({required bool red}) {
    final t = timing.snap(time.value, divisor).roundToDouble();
    for (final p in beatmap.timingPoints) {
      if (p.time == t && p.uninherited == red) return p;
    }
    final eff = timing.effectivePointAt(t);
    final redAt = timing.redPointAt(t);
    final point = TimingPoint(
      time: t,
      beatLength: red ? (redAt?.beatLength ?? 500) : -100 / (eff?.sliderVelocity ?? 1),
      meter: redAt?.meter ?? 4,
      sampleSet: eff?.sampleSet ?? 0,
      sampleIndex: eff?.sampleIndex ?? 0,
      volume: eff?.volume ?? 100,
      uninherited: red,
      effects: (eff?.effects ?? 0) & TimingEffects.kiai,
    );
    history.execute(AddTimingPointCommand(point));
    return point;
  }

  /// Replaces [before] with [after] (one undo step). Returns [after], or
  /// [before] if nothing changed or [before] is gone (stale UI).
  TimingPoint updateTimingPoint(TimingPoint before, TimingPoint after) {
    if (_sameTiming(before, after) || beatmap.indexOfTimingPoint(before) < 0) return before;
    history.execute(ReplaceTimingPointCommand(before, after));
    return after;
  }

  bool _moveObjectsWithTiming = false;

  /// Timing mode's "Move objects with timing": offset / BPM changes made
  /// through [retimePoint] carry the red point's section along. Session only.
  bool get moveObjectsWithTiming => _moveObjectsWithTiming;
  set moveObjectsWithTiming(bool on) {
    if (on == _moveObjectsWithTiming) return;
    _moveObjectsWithTiming = on;
    notifyListeners();
  }

  /// [updateTimingPoint], except that with [moveObjectsWithTiming] on, a red
  /// point's offset / BPM change also moves the objects and green points of
  /// its section so they keep their beats (`TimingOps.retimeSection`), all
  /// as one undo step. Moved objects stay selected.
  TimingPoint retimePoint(TimingPoint before, TimingPoint after) {
    final retimes = before.uninherited && (before.time != after.time || before.beatLength != after.beatLength);
    if (!_moveObjectsWithTiming || !retimes || beatmap.indexOfTimingPoint(before) < 0) {
      return updateTimingPoint(before, after);
    }
    final cmd = TimingOps.retimeSection(beatmap, before, after);
    if (cmd == null) return updateTimingPoint(before, after);
    final selected = Set<HitObject>.identity()..addAll(selection);
    history.execute(cmd);
    for (final move in cmd.commands.whereType<ReplaceHitObjectsCommand>()) {
      for (var i = 0; i < move.before.length; i++) {
        if (selected.contains(move.before[i])) selection.add(move.after[i]);
      }
    }
    notifyListeners();
    return after;
  }

  static bool _sameTiming(TimingPoint a, TimingPoint b) =>
      a.time == b.time &&
      a.beatLength == b.beatLength &&
      a.meter == b.meter &&
      a.sampleSet == b.sampleSet &&
      a.sampleIndex == b.sampleIndex &&
      a.volume == b.volume &&
      a.uninherited == b.uninherited &&
      a.effects == b.effects;

  void deleteTimingPoint(TimingPoint p) {
    if (beatmap.indexOfTimingPoint(p) < 0) return;
    history.execute(RemoveTimingPointCommand(p));
  }

  /// Applies [change] to each of [points] still in the map, as one undo
  /// step. Returns the resulting points (unchanged ones as they were; gone
  /// ones left out).
  List<TimingPoint> updateTimingPoints(Iterable<TimingPoint> points, TimingPoint Function(TimingPoint) change) {
    final cmds = <EditCommand>[];
    final out = <TimingPoint>[];
    for (final p in points) {
      if (beatmap.indexOfTimingPoint(p) < 0) continue;
      final q = change(p);
      if (_sameTiming(p, q)) {
        out.add(p);
      } else {
        cmds.add(ReplaceTimingPointCommand(p, q));
        out.add(q);
      }
    }
    if (cmds.isNotEmpty) {
      history.execute(cmds.length == 1 ? cmds.single : CompositeCommand('Modify timing points', cmds));
    }
    return out;
  }

  /// Deletes each of [points] still in the map, as one undo step.
  void deleteTimingPoints(Iterable<TimingPoint> points) {
    final cmds = <EditCommand>[
      for (final p in points)
        if (beatmap.indexOfTimingPoint(p) >= 0) RemoveTimingPointCommand(p),
    ];
    if (cmds.isEmpty) return;
    history.execute(cmds.length == 1 ? cmds.single : CompositeCommand('Delete timing points', cmds));
  }

  // ---------------------------------------------------------------------------
  // Song setup (metadata / difficulty / general values)

  /// Sets several key-value entries as one undo step. Entries whose value is
  /// unchanged are skipped (their original lines stay). Returns whether
  /// anything changed.
  bool setValues(String label, List<(String section, String key, String value)> values) {
    final cmds = [
      for (final (s, k, v) in values)
        if (beatmap.getValue(s, k) != v) SetValueCommand(s, k, v),
    ];
    if (cmds.isEmpty) return false;
    history.execute(cmds.length == 1 ? cmds.single : CompositeCommand(label, cmds));
    return true;
  }

  // ---------------------------------------------------------------------------
  // Difficulties of the set (library maps only)

  /// Creates a new difficulty named [version] in this map's set from the
  /// current (possibly unsaved) state: empty (timing, settings and metadata
  /// only) or, with [copyObjects], a full duplicate. Returns its path.
  Future<String?> createDifficulty(String version, {bool copyObjects = false}) async {
    final lib = library, setPath = document.setPath;
    if (lib == null || setPath == null) return null;
    final b = DifficultyOps.derive(beatmap, version: version, keepObjects: copyObjects);
    final d = await lib.addDifficulty(setPath, b, encoding: document.encoding);
    return d.path;
  }

  /// Copies this map's set-wide metadata (title, artist, creator, source,
  /// tags, set ID) into the set's other difficulties, on disk. Not undoable.
  /// Returns how many files changed.
  Future<int> syncMetadataToSet() async {
    final lib = library, setPath = document.setPath;
    if (lib == null || setPath == null) return 0;
    return lib.syncSetMetadata(setPath, DifficultyOps.setMetadataOf(beatmap), exceptPath: document.path);
  }

  /// The set's other difficulties (library maps only).
  Future<List<LibraryDifficulty>> otherDifficulties() async {
    final lib = library, setPath = document.setPath;
    if (lib == null || setPath == null) return const [];
    return [for (final d in (await lib.readSet(setPath)).difficulties) if (d.path != document.path) d];
  }

  /// Copies this map's hitsounds (its current, possibly unsaved state) into
  /// the difficulties at [paths], on disk ([HitsoundCopyOps]). Not part of
  /// this map's undo history: returns the changed files' previous bytes,
  /// which [restoreDifficulties] writes back.
  Future<Map<String, Uint8List>> copyHitsoundsTo(
    List<String> paths, {
    double leniency = HitsoundCopyOps.defaultLeniency,
    bool samplePoints = true,
    bool clearUnmatched = false,
  }) async {
    final lib = library;
    if (lib == null || paths.isEmpty) return const {};
    return lib.copyHitsounds(beatmap, paths,
        leniency: leniency, samplePoints: samplePoints, clearUnmatched: clearUnmatched);
  }

  Future<void> restoreDifficulties(Map<String, Uint8List> files) async => library?.restoreFiles(files);

  // ---------------------------------------------------------------------------
  // stable's pattern and reset tools: polygon circles, reset samples / combo
  // colours, revert to saved, delete difficulty.

  List<HitCircle>? _polygon;

  /// Starts "Polygon circles" (a live preview; [endPolygon] keeps or drops
  /// it). False while another gesture is under way.
  bool beginPolygon() {
    if (_polygon != null || history.inTransaction) return false;
    pause();
    history.beginTransaction('Polygon circles');
    _polygon = const [];
    return true;
  }

  /// Shows the circles for these settings from the snapped current time
  /// (see [PolygonOps.circles]); returns whether they fit the playfield
  /// (if not, the preview is still shown).
  bool updatePolygon({required int vertices, int repeats = 1, double distance = 1, double angleDegrees = 0}) {
    final shown = _polygon;
    if (shown == null) return false;
    final next = PolygonOps.circles(
      timing: timing,
      sliderMultiplier: beatmap.sliderMultiplier,
      distanceSpacing: distanceSpacing,
      startTime: timing.snap(time.value, divisor),
      divisor: divisor,
      vertices: vertices,
      repeats: repeats,
      distance: distance,
      angleDegrees: angleDegrees,
    );
    if (shown.isNotEmpty) history.execute(RemoveHitObjectsCommand(shown));
    history.execute(AddHitObjectsCommand(next));
    _polygon = next;
    selection
      ..clear()
      ..addAll(next);
    notifyListeners();
    return PolygonOps.fits(next);
  }

  /// Keeps the previewed circles as one undo step ([apply]) or removes them.
  void endPolygon({required bool apply}) {
    final shown = _polygon;
    if (shown == null) return;
    _polygon = null;
    if (apply && shown.isNotEmpty) {
      history.commitTransaction();
    } else {
      history.cancelTransaction();
      selection.clear();
    }
    notifyListeners();
  }

  /// The objects the reset tools work on: the selection, or every object
  /// when nothing is selected (stable's "reset all").
  List<HitObject> get _resetTargets => selection.isNotEmpty ? selection.toList() : List.of(beatmap.hitObjects);

  /// stable's "Reset samples": drops additions, sample sets and custom
  /// samples (slider edges too) from the selection, or the whole map when
  /// nothing is selected. One undo step; returns how many objects changed.
  int resetSamples() => _resetEach('Reset samples', ResetOps.withoutSamples);

  /// stable's "Reset combo colours": drops combo colour skips ("colour
  /// hax"), new combos themselves stay. Selection or whole map, one undo
  /// step; returns how many objects changed.
  int resetComboColours() => _resetEach('Reset combo colours', ResetOps.withoutColourSkip);

  /// stable's "Resnap all notes": every object's start (and a spinner's
  /// end) moves to the nearest tick of the current beat snap. Selection or
  /// whole map, one undo step; returns how many objects moved.
  int resnapNotes() => _resetEach('Resnap notes', (h) => _retimed(h, (t) => timing.snap(t, divisor)));

  /// Moves the selection, or every object when nothing is selected, by
  /// [ms] (negative = earlier), as one undo step. Nothing goes before 0:
  /// the earliest object stops there. Timing points stay where they are
  /// (Timing mode moves objects with their timing). Returns how many moved.
  int moveNotesInTime(double ms) {
    final targets = _resetTargets;
    if (targets.isEmpty) return 0;
    final first = targets.map((h) => h.time).reduce(math.min);
    final d = math.max(ms, -first);
    if (d.abs() < 1e-6) return 0;
    return _resetEach('Move notes', (h) => h.shiftedInTime(d));
  }

  /// [h] with its times mapped by [map], or null if that changes nothing.
  static HitObject? _retimed(HitObject h, double Function(double) map) {
    final n = TimingOps.moved(h, map);
    return n.time == h.time && n.endTimeIfKnown == h.endTimeIfKnown ? null : n;
  }

  int _resetEach(String label, HitObject? Function(HitObject) reset) {
    if (history.inTransaction) return 0;
    final before = <HitObject>[], after = <HitObject>[];
    for (final h in _resetTargets) {
      final r = reset(h);
      if (r == null) continue;
      before.add(h);
      after.add(r);
    }
    if (before.isEmpty) return 0;
    // Captured first: the edit drops replaced objects from the selection.
    final selected = selection.toList();
    history.execute(ReplaceHitObjectsCommand(before, after, label: label));
    if (selected.isNotEmpty) {
      final swapped = {for (var i = 0; i < before.length; i++) before[i]: after[i]};
      final kept = [for (final h in selected) swapped[h] ?? h];
      selection
        ..clear()
        ..addAll(kept);
    }
    _edgeSlider = null;
    notifyListeners();
    return before.length;
  }

  /// Whether [revertToSaved] can go back through the undo history (the
  /// saved state is still on it). Otherwise the file has to be reopened.
  bool get canRevertInHistory => history.canReachSavePoint;

  /// stable's "Revert to saved" through the history: undoes (or redoes) up
  /// to the last saved state, so a redo can bring the changes back. Returns
  /// false when that state is no longer on the history.
  bool revertToSaved() {
    if (!history.isDirty) return true;
    if (!history.reachSavePoint()) return false;
    _objectTimes = _objectSignature();
    selection.removeWhere((h) => beatmap.indexOfHitObject(h) < 0);
    _edgeSlider = null;
    notifyListeners();
    return true;
  }

  /// Number of difficulties in this map's set (library maps; 0 otherwise).
  Future<int> setDifficultyCount() async {
    final lib = library, setPath = document.setPath;
    if (lib == null || setPath == null || !document.isInLibrary) return 0;
    return (await lib.readSet(setPath)).difficulties.length;
  }

  /// Deletes this difficulty's file from its library set (not undoable;
  /// the editor should close). Never the set's last difficulty.
  Future<bool> deleteThisDifficulty() async {
    final lib = library, path = document.path;
    if (lib == null || path == null || await setDifficultyCount() < 2) return false;
    await lib.deleteDifficulty(path);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Compose toggles (osu!stable's side toolboxes). New combo, additions and
  // sample sets apply to the selection (Select tool), otherwise to the
  // next placed object (always with a placement tool). Grid / distance snap
  // and note lock are editor state.

  bool _placeNewCombo = false;
  int _placeComboSkip = 0;
  int _placeAdditions = 0;
  int _placeNormalSet = SampleSet.auto;
  int _placeAdditionSet = SampleSet.auto;

  static const gridSizes = [4, 8, 16, 32];
  static int _validGridSize(String? v) {
    final n = int.tryParse(v?.trim() ?? '');
    return gridSizes.contains(n) ? n! : 16;
  }

  /// Toggles edit the selection only with the Select tool (stable's rule);
  /// with a placement tool they set up the next object, even though the
  /// object just placed stays selected.
  bool get _editsSelection => _tool == EditorTool.select && selection.isNotEmpty;

  /// The common value of [f] over the selection, or null if it differs.
  int? _common(int Function(HitObject) f) {
    final v = f(selection.first);
    return selection.every((h) => f(h) == v) ? v : null;
  }

  bool get newComboState => _editsSelection ? selection.every((h) => h.newCombo) : _placeNewCombo;

  // A slider edge picked on the timeline (stable): with one, the hitsound
  // toggles and sample sets below show and edit that edge only.
  SliderObject? _edgeSlider;
  int _edge = 0;

  /// The edge of [editedSlider] whose hitsounds the toolbox edits (0 = head,
  /// 1.. = repeats, `slides` = tail), or null for the whole slider.
  int? get selectedEdge {
    final s = editedSlider;
    if (s == null || !identical(s, _edgeSlider) || _tool != EditorTool.select || _edge > s.slides) return null;
    return _edge;
  }

  /// Picks edge [edge] of [editedSlider] (null: back to the whole slider).
  void selectEdge(int? edge) {
    final s = editedSlider;
    if (edge == null || s == null || edge < 0 || edge > s.slides) {
      if (_edgeSlider == null) return;
      _edgeSlider = null;
    } else {
      if (identical(_edgeSlider, s) && _edge == edge) return;
      _edgeSlider = s;
      _edge = edge;
    }
    notifyListeners();
  }

  /// Times of [s]'s edges: head, repeats, tail.
  List<double> edgeTimes(SliderObject s) {
    final span = timing.sliderSpanDuration(s, beatmap.sliderMultiplier);
    return [for (var i = 0; i <= s.slides; i++) s.time + span * i];
  }

  /// "Head", "Repeat n" or "Tail".
  static String edgeName(SliderObject s, int edge) =>
      edge == 0 ? 'Head' : edge == s.slides ? 'Tail' : 'Repeat $edge';

  /// Hitsound flags of edge [i] (the slider's own when the file has none,
  /// as osu! plays them).
  static int edgeSoundOf(SliderObject s, int i) =>
      s.edgeSounds != null && i < s.edgeSounds!.length ? s.edgeSounds![i] : s.hitSound;

  /// Sample sets of edge [i] (0 = the slider's).
  static EdgeSet edgeSetOf(SliderObject s, int i) =>
      s.edgeSets != null && i < s.edgeSets!.length ? s.edgeSets![i] : const EdgeSet(0, 0);

  /// Changes the selected edge's sounds / sets (one undo step), filling in
  /// the slider's per-edge lists.
  void _editEdge(String label, {int Function(int)? sound, int? normalSet, int? additionSet}) {
    final s = editedSlider, i = selectedEdge;
    if (s == null || i == null) return;
    final n = s.slides + 1;
    final sounds = [for (var k = 0; k < n; k++) edgeSoundOf(s, k)];
    final sets = [for (var k = 0; k < n; k++) edgeSetOf(s, k)];
    if (sound != null) sounds[i] = sound(sounds[i]);
    if (normalSet != null || additionSet != null) {
      sets[i] = EdgeSet(normalSet ?? sets[i].normalSet, additionSet ?? sets[i].additionSet);
    }
    final next = s.copyWith(edgeSounds: sounds, edgeSets: sets);
    _edgeSlider = next; // stays picked on the new copy
    _replaceSelection([s], [next], label);
  }

  /// Whether [flag] (a [HitSoundFlags] addition) is on.
  bool additionState(int flag) {
    final s = editedSlider, e = selectedEdge;
    if (s != null && e != null) return edgeSoundOf(s, e) & flag != 0;
    return _editsSelection ? selection.every((h) => h.hitSound & flag != 0) : _placeAdditions & flag != 0;
  }

  /// Sample set ([SampleSet] id); null when the selection is mixed.
  int? get normalSetState {
    final s = editedSlider, e = selectedEdge;
    if (s != null && e != null) return edgeSetOf(s, e).normalSet;
    return _editsSelection ? _common((h) => h.sample.normalSet) : _placeNormalSet;
  }

  int? get additionSetState {
    final s = editedSlider, e = selectedEdge;
    if (s != null && e != null) return edgeSetOf(s, e).additionSet;
    return _editsSelection ? _common((h) => h.sample.additionSet) : _placeAdditionSet;
  }

  void toggleNewCombo() {
    if (_editsSelection) return toggleNewComboOnSelection();
    _placeNewCombo = !_placeNewCombo;
    if (!_placeNewCombo) _placeComboSkip = 0;
    notifyListeners();
  }

  /// Combo colours skipped by the new combo ("colour hax", 0-7): the
  /// selection's common value (null when mixed or not all new combos), or
  /// the next placed object's.
  int? get comboSkipState {
    if (!_editsSelection) return _placeNewCombo ? _placeComboSkip : 0;
    if (!newComboState) return null;
    return _common((h) => h.comboSkip);
  }

  /// Sets the colour skip to [n], turning new combo on: for the selection
  /// (one undo step) or the next placed object (one-shot, like NC).
  void setComboSkip(int n) {
    n = n.clamp(0, maxComboSkip);
    if (!_editsSelection) {
      _placeNewCombo = true;
      _placeComboSkip = n;
      notifyListeners();
      return;
    }
    final before = selection.toList();
    if (before.every((h) => h.newCombo && h.comboSkip == n)) return;
    _replaceSelection(before, [for (final h in before) h.copyWithBase(newCombo: true, comboSkip: n)],
        'Set combo colour skip');
  }

  static const maxComboSkip = 7;

  /// The colour index (see [comboColourAt]) the selected object, or the
  /// next one placed at the current time, gets as a new combo with no skip;
  /// skipping n colours gives `+ n`. Null when there is no single target
  /// (several objects selected, or a spinner, whose new combo is ignored).
  int? get comboSkipBaseColour {
    final objs = beatmap.hitObjects;
    int i; // index of the target object, or where it would be inserted
    if (_editsSelection) {
      if (selection.length != 1 || selection.first is Spinner) return null;
      i = objs.indexOf(selection.first);
    } else {
      if (_tool == EditorTool.spinner) return null;
      final t = timing.snap(time.value, divisor);
      i = objs.length;
      while (i > 0 && objs[i - 1].time > t) {
        i--;
      }
    }
    return i <= 0 ? 1 : comboOf(objs[i - 1]).colourIndex + 1;
  }

  void toggleAddition(int flag) {
    if (selectedEdge != null) {
      final on = !additionState(flag);
      return _editEdge(on ? 'Add hitsound' : 'Remove hitsound', sound: (v) => on ? v | flag : v & ~flag);
    }
    if (!_editsSelection) {
      _placeAdditions ^= flag;
      notifyListeners();
      return;
    }
    final before = selection.toList();
    final on = !additionState(flag);
    int apply(int v) => on ? v | flag : v & ~flag;
    _replaceSelection(before, [for (final h in before) _withSounds(h, sound: apply)],
        on ? 'Add hitsound' : 'Remove hitsound');
  }

  void setNormalSet(int set) {
    if (normalSetState == set) return;
    if (selectedEdge != null) return _editEdge('Change sample set', normalSet: set);
    if (!_editsSelection) {
      _placeNormalSet = set;
      notifyListeners();
      return;
    }
    final before = selection.toList();
    _replaceSelection(before, [for (final h in before) _withSounds(h, normalSet: set)], 'Change sample set');
  }

  void setAdditionSet(int set) {
    if (additionSetState == set) return;
    if (selectedEdge != null) return _editEdge('Change addition set', additionSet: set);
    if (!_editsSelection) {
      _placeAdditionSet = set;
      notifyListeners();
      return;
    }
    final before = selection.toList();
    _replaceSelection(before, [for (final h in before) _withSounds(h, additionSet: set)], 'Change addition set');
  }

  /// [h] with its hitsound flags mapped by [sound] and / or its sample sets
  /// replaced. Slider edges follow the body, like stable's toolbox.
  static HitObject _withSounds(HitObject h, {int Function(int)? sound, int? normalSet, int? additionSet}) {
    final s = h.sample;
    final sample = normalSet == null && additionSet == null
        ? s
        : HitSample(
            normalSet: normalSet ?? s.normalSet,
            additionSet: additionSet ?? s.additionSet,
            index: s.index,
            volume: s.volume,
            filename: s.filename,
          );
    final hitSound = sound == null ? h.hitSound : sound(h.hitSound);
    if (h is SliderObject) {
      return h.copyWith(
        hitSound: hitSound,
        sample: sample,
        edgeSounds: sound == null ? null : h.edgeSounds?.map(sound).toList(),
        edgeSets: normalSet == null && additionSet == null
            ? null
            : h.edgeSets
                ?.map((e) => EdgeSet(normalSet ?? e.normalSet, additionSet ?? e.additionSet))
                .toList(),
      );
    }
    return h.copyWithBase(hitSound: hitSound, sample: sample);
  }

  // ---------------------------------------------------------------------------
  // Hitsound screen editing: a tap on a layer edits one sounding point (a
  // circle, one slider edge or a spinner's end), a slider body or a timing
  // point directly, whatever is selected (one undo step each).

  /// Undo labels of the edits that only change objects' hitsounds (the
  /// Hitsound screen shows them, so undoing one there stays there).
  static const hitsoundEditLabels = {
    'Add hitsound',
    'Remove hitsound',
    'Change sample set',
    'Change addition set',
    'Change volume',
    'Change sample index',
  };

  /// The next sample set when cycling: inherit (0) → normal → soft → drum.
  static int nextSampleSet(int set) => (set + 1) % 4;

  /// Replaces [before] with [after] (one undo step), keeping the selection
  /// and a picked slider edge on the new copy.
  HitObject _replaceObject(HitObject before, HitObject after, String label) {
    if (!beatmap.hitObjects.contains(before)) return before;
    history.execute(ReplaceHitObjectsCommand([before], [after], label: label));
    if (selection.remove(before)) selection.add(after);
    if (identical(_edgeSlider, before) && after is SliderObject) _edgeSlider = after;
    notifyListeners();
    return after;
  }

  /// [s] with edge [edge]'s sounds / sets changed, filling in the per-edge
  /// lists (the other edges keep what they play).
  static SliderObject _withEdge(SliderObject s, int edge,
      {int Function(int)? sound, int Function(EdgeSet)? normalSet, int Function(EdgeSet)? additionSet}) {
    final n = s.slides + 1;
    final sounds = [for (var k = 0; k < n; k++) edgeSoundOf(s, k)];
    final sets = [for (var k = 0; k < n; k++) edgeSetOf(s, k)];
    if (sound != null) sounds[edge] = sound(sounds[edge]);
    final e = sets[edge];
    sets[edge] = EdgeSet(normalSet?.call(e) ?? e.normalSet, additionSet?.call(e) ?? e.additionSet);
    return s.copyWith(edgeSounds: sounds, edgeSets: sets);
  }

  /// Toggles addition [flag] on [note]: its object, or just its slider edge.
  void toggleNoteAddition(HitsoundNote note, int flag) {
    final o = note.object;
    final on = (o is SliderObject ? edgeSoundOf(o, note.edge) : o.hitSound) & flag == 0;
    int apply(int v) => on ? v | flag : v & ~flag;
    final label = on ? 'Add hitsound' : 'Remove hitsound';
    _replaceObject(
        o, o is SliderObject ? _withEdge(o, note.edge, sound: apply) : o.copyWithBase(hitSound: apply(o.hitSound)), label);
  }

  /// Cycles [note]'s sample set (or addition set) with [nextSampleSet]: its
  /// object's, or just its slider edge's.
  void cycleNoteSet(HitsoundNote note, {required bool addition}) {
    final o = note.object;
    final label = addition ? 'Change addition set' : 'Change sample set';
    if (o is SliderObject) {
      _replaceObject(
          o,
          addition
              ? _withEdge(o, note.edge, additionSet: (e) => nextSampleSet(e.additionSet))
              : _withEdge(o, note.edge, normalSet: (e) => nextSampleSet(e.normalSet)),
          label);
      return;
    }
    final s = o.sample;
    _replaceObject(
        o,
        _withSounds(o,
            normalSet: addition ? null : nextSampleSet(s.normalSet),
            additionSet: addition ? nextSampleSet(s.additionSet) : null),
        label);
  }

  /// Toggles [s]'s body whistle (sliderwhistle) without changing what its
  /// edges play.
  void toggleBodyWhistle(SliderObject s) {
    final n = s.slides + 1;
    final on = s.hitSound & HitSoundFlags.whistle == 0;
    _replaceObject(
        s,
        s.copyWith(
          hitSound: on ? s.hitSound | HitSoundFlags.whistle : s.hitSound & ~HitSoundFlags.whistle,
          edgeSounds: [for (var k = 0; k < n; k++) edgeSoundOf(s, k)],
        ),
        on ? 'Add hitsound' : 'Remove hitsound');
  }

  /// Cycles [s]'s own sample set (or addition set): its body, ticks and the
  /// edges without a set of their own.
  void cycleBodySet(SliderObject s, {required bool addition}) {
    final x = s.sample;
    _replaceObject(
        s,
        s.copyWith(
            sample: HitSample(
          normalSet: addition ? x.normalSet : nextSampleSet(x.normalSet),
          additionSet: addition ? nextSampleSet(x.additionSet) : x.additionSet,
          index: x.index,
          volume: x.volume,
          filename: x.filename,
        )),
        addition ? 'Change addition set' : 'Change sample set');
  }

  /// Sets [o]'s own sample [index] and / or [volume] (0 = inherit from the
  /// timing point). Returns the new object.
  HitObject setObjectSample(HitObject o, {int? index, int? volume}) {
    final x = o.sample;
    if ((index ?? x.index) == x.index && (volume ?? x.volume) == x.volume) return o;
    final sample = HitSample(
      normalSet: x.normalSet,
      additionSet: x.additionSet,
      index: index ?? x.index,
      volume: volume ?? x.volume,
      filename: x.filename,
    );
    return _replaceObject(
        o,
        o is SliderObject ? o.copyWith(sample: sample) : o.copyWithBase(sample: sample),
        volume != null && volume != x.volume ? 'Change volume' : 'Change sample index');
  }

  /// Cycles [p]'s sample set with [nextSampleSet] (0 = the map default).
  TimingPoint cycleTimingPointSet(TimingPoint p) =>
      updateTimingPoint(p, p.copyWith(sampleSet: nextSampleSet(p.sampleSet)));

  /// A new object with the toolbox's combo / hitsound state applied. The
  /// new-combo toggle is one-shot (cleared after placing), as in stable.
  HitObject _placed(HitObject h) {
    final nc = _placeNewCombo, skip = _placeComboSkip;
    _placeNewCombo = false;
    _placeComboSkip = 0;
    final r = _withSounds(h,
        sound: (v) => v | _placeAdditions, normalSet: _placeNormalSet, additionSet: _placeAdditionSet);
    return nc && (!r.newCombo || skip != r.comboSkip) ? r.copyWithBase(newCombo: true, comboSkip: skip) : r;
  }

  // Grid / distance snap, lock notes, the transform pivot and "keep slider
  // nodes" are app settings (the same for every map, kept between runs).
  final EditSettings _fallbackEdit = EditSettings();
  EditSettings get editSettings => settings?.edit ?? _fallbackEdit;

  void _setEdit(void Function(EditSettings e) change) {
    change(editSettings);
    settings?.save();
    notifyListeners();
  }

  bool get gridSnap => editSettings.gridSnap;
  set gridSnap(bool v) {
    if (v != gridSnap) _setEdit((e) => e.gridSnap = v);
  }

  /// [Editor] GridSize (saved with the map, like stable).
  int get gridSize => _validGridSize(beatmap.getValue(SectionNames.editor, 'GridSize'));

  /// Sets the grid size (one undo step; written to the file).
  void setGridSize(int size) {
    if (!gridSizes.contains(size) || size == gridSize) return;
    history.execute(SetValueCommand(SectionNames.editor, 'GridSize', '$size'));
  }

  /// Steps through [gridSizes] (4 → 8 → 16 → 32 → 4).
  void cycleGridSize() => setGridSize(gridSizes[(gridSizes.indexOf(gridSize) + 1) % gridSizes.length]);

  bool get distanceSnap => editSettings.distanceSnap;
  set distanceSnap(bool v) {
    if (v != distanceSnap) _setEdit((e) => e.distanceSnap = v);
  }

  /// Locked notes can't be dragged on the playfield (stable's "Lock notes").
  bool get lockNotes => editSettings.lockNotes;
  set lockNotes(bool v) {
    if (v != lockNotes) _setEdit((e) => e.lockNotes = v);
  }

  /// Curve type of newly drawn sliders (Display options).
  DefaultSliderType get defaultSliderType => editSettings.defaultSliderType;
  set defaultSliderType(DefaultSliderType v) {
    if (v != defaultSliderType) _setEdit((e) => e.defaultSliderType = v);
  }

  /// [p] rounded to the grid when grid snap is on.
  Vec2 snapPosition(Vec2 p) {
    if (!gridSnap) return p;
    final g = gridSize.toDouble();
    return Vec2((p.x / g).roundToDouble() * g, (p.y / g).roundToDouble() * g);
  }

  /// [Editor] DistanceSpacing: the distance snap multiplier.
  double get distanceSpacing =>
      double.tryParse(beatmap.getValue(SectionNames.editor, 'DistanceSpacing')?.trim() ?? '') ?? 1;

  static const minDistanceSpacing = 0.1, maxDistanceSpacing = 6.0;

  /// Sets the distance spacing, rounded to 0.01 (stable: Alt+scroll steps
  /// 0.1, Alt+Shift+scroll 0.01; one undo step; saved).
  void setDistanceSpacing(double v) {
    final x = (v.clamp(minDistanceSpacing, maxDistanceSpacing) * 100).roundToDouble() / 100;
    if ((x - distanceSpacing).abs() < 1e-9) return;
    history.execute(SetValueCommand(SectionNames.editor, 'DistanceSpacing', formatNumber(x)));
  }

  /// Distance snap ring for an object placed at [t], like stable's: the
  /// object is placed at [t] (the playhead; lazer's "limit distance snap
  /// placement to current time") on a ring around where the previous
  /// object ends, as drawn (stack offset included, lazer's
  /// StackedEndPosition), radius = spacing × the slider velocity of the
  /// timing / green line at [t] (stable: "the current timing point";
  /// lazer would use the last slider's) × the gap. Null when distance snap
  /// is off, nothing precedes [t], or the previous object is a spinner
  /// (lazer: no grid after a spinner). The previous object is the latest
  /// one starting before [t] (objects at [t] are where we place); one still
  /// running at [t] (inside a long slider) counts with the gap taken the
  /// other way (lazer anchors on it too). Objects in [exclude] (the ones
  /// being moved) don't count.
  (Vec2, double)? distanceSnapGuide(double t, {Set<HitObject>? exclude}) {
    if (!distanceSnap) return null;
    final objs = beatmap.hitObjects;
    for (var i = Beatmap.lowerBound(objs, t - 1, (h) => h.time) - 1; i >= 0; i--) {
      final h = objs[i];
      if (exclude != null && exclude.contains(h)) continue;
      if (h is Spinner || h is HoldNote) return null;
      final end = endTimeOf(h);
      final pos = (h is SliderObject && h.slides.isOdd ? sliderPath(h).positionAt(1) : h.position) + stackOffsetOf(h);
      final r = distanceSpacing * timing.sliderVelocityPxPerMs(t, beatmap.sliderMultiplier) * (t - end).abs();
      return (pos, r);
    }
    return null;
  }

  /// Where a new object tapped at [pos] goes at time [t]: on the distance
  /// snap ring (if on; not when that point is off the playfield — lazer
  /// gives up distance snap there), then on the grid (grid snap wins, as in
  /// stable and lazer); clamped (to [clampToSliderBounds] for a [slider]
  /// head, else the playfield) and rounded.
  Vec2 placementPosition(Vec2 pos, double t, {bool slider = false}) {
    final p = snapPosition(_ringSnapped(pos, distanceSnapGuide(t)));
    return (slider ? clampToSliderBounds(p) : clampToPlayfield(p)).roundToInt();
  }

  /// [p] moved onto [guide]'s ring, unless that point is off the playfield
  /// (or there is no ring).
  static Vec2 _ringSnapped(Vec2 p, (Vec2, double)? guide) {
    if (guide == null) return p;
    final q = _onRing(guide.$1, guide.$2, p);
    const eps = 1e-6;
    final inside = q.x >= -eps && q.x <= OsuRules.playfieldWidth + eps && q.y >= -eps && q.y <= OsuRules.playfieldHeight + eps;
    return inside ? q : p;
  }

  /// The point of the circle ([c], [r]) nearest [p].
  static Vec2 _onRing(Vec2 c, double r, Vec2 p) {
    final d = p - c;
    final len = d.length;
    return len < 1e-6 ? c + Vec2(r, 0) : c + d * (r / len);
  }

  // ---------------------------------------------------------------------------
  // Saving


  String serialize() => OsuWriter.write(beatmap);

  /// The stable-style file name for the metadata at the last load / save.
  /// Saving renames a library difficulty only when this changes, so maps
  /// imported with unusual names keep them until their metadata is edited.
  /// (Set in the constructor: a lazy initializer would only run at the
  /// first save, after the metadata may have changed.)
  String _namedFor;

  /// Song setup values at the last load / save, keyed `Section.Key` (plus
  /// `Files.Audio` / `Files.Background`), so the panel can highlight what
  /// differs from the file on disk.
  /// Taken in the constructor (not lazily: edits made before Song setup is
  /// first shown must still count as changes).
  late Map<String, String?> _savedSetup;

  Map<String, String?> _setupSnapshot() => {
    for (final (s, k) in songSetupKeys) '$s.$k': beatmap.getValue(s, k),
    'Files.Audio': beatmap.audioFilename,
    'Files.Background': beatmap.backgroundFilename,
    'Colours.Combo': _comboColoursKey(),
    'Colours.${ComboColours.sliderTrack}': mapColour(ComboColours.sliderTrack)?.hex,
    'Colours.${ComboColours.sliderBorder}': mapColour(ComboColours.sliderBorder)?.hex,
  };

  String _comboColoursKey() => ComboColours.of(beatmap).join(' ');

  /// `[section, key]` pairs the Song setup panel edits.
  static const List<(String, String)> songSetupKeys = [
    (SectionNames.metadata, 'Artist'),
    (SectionNames.metadata, 'ArtistUnicode'),
    (SectionNames.metadata, 'Title'),
    (SectionNames.metadata, 'TitleUnicode'),
    (SectionNames.metadata, 'Creator'),
    (SectionNames.metadata, 'Version'),
    (SectionNames.metadata, 'Source'),
    (SectionNames.metadata, 'Tags'),
    (SectionNames.difficulty, 'HPDrainRate'),
    (SectionNames.difficulty, 'CircleSize'),
    (SectionNames.difficulty, 'ApproachRate'),
    (SectionNames.difficulty, 'OverallDifficulty'),
    (SectionNames.difficulty, 'SliderMultiplier'),
    (SectionNames.difficulty, 'SliderTickRate'),
    (SectionNames.general, 'PreviewTime'),
    (SectionNames.general, 'SampleSet'),
    (SectionNames.general, 'AudioLeadIn'),
    (SectionNames.general, 'StackLeniency'),
    (SectionNames.general, 'Countdown'),
    (SectionNames.general, 'CountdownOffset'),
    (SectionNames.general, 'LetterboxInBreaks'),
    (SectionNames.general, 'WidescreenStoryboard'),
    (SectionNames.general, 'EpilepsyWarning'),
  ];

  /// Whether Song setup entry [id] (`Section.Key`, `Files.Audio`,
  /// `Files.Background`) differs from the last saved state.
  bool songSetupChanged(String id) {
    final now = switch (id) {
      'Files.Audio' => beatmap.audioFilename,
      'Files.Background' => beatmap.backgroundFilename,
      'Colours.Combo' => _comboColoursKey(),
      'Colours.${ComboColours.sliderTrack}' => mapColour(ComboColours.sliderTrack)?.hex,
      'Colours.${ComboColours.sliderBorder}' => mapColour(ComboColours.sliderBorder)?.hex,
      _ => beatmap.getValue(id.substring(0, id.indexOf('.')), id.substring(id.indexOf('.') + 1)),
    };
    return _norm(now) != _norm(_savedSetup[id]);
  }

  static String? _norm(String? s) => s?.trim();

  /// The `.osb` name (`Artist - Title (Creator).osb`) for the metadata at the
  /// last load / save: saving with other metadata renames the set's
  /// storyboard to match, as osu!stable finds it by that name.
  String _osbNamedFor;

  /// Returns false if the user cancelled.
  Future<bool> save() async {
    final before = document.path;
    var saved = await files.save(document, serialize());
    if (saved == null) return false;
    if (before != null) await recovery?.clear(before);
    _autosaved = false;
    final lib = library, path = saved.path, setPath = saved.setPath;
    final osb = DifficultyOps.osbFileNameOf(beatmap);
    if (lib != null && saved.isInLibrary && setPath != null && osb != _osbNamedFor) {
      await lib.renameStoryboard(setPath, _osbNamedFor, osb);
    }
    _osbNamedFor = osb;
    final name = DifficultyOps.fileNameOf(beatmap);
    if (lib != null && saved.isInLibrary && path != null && name != _namedFor) {
      final renamed = await lib.renameDifficulty(path, name);
      saved = BeatmapDocument(
        fileName: renamed.substring(renamed.lastIndexOf(RegExp(r'[\\/]')) + 1),
        path: renamed,
        setPath: saved.setPath,
        encoding: saved.encoding,
      );
    }
    _namedFor = name;
    document = saved;
    _savedSetup = _setupSnapshot();
    history.markSaved();
    return true;
  }

  bool get canExportOsz => library != null && document.isInLibrary;

  // ---------------------------------------------------------------------------
  // Autosave (crash / kill recovery)

  bool _autosaved = false;

  /// Writes the unsaved state to [recovery] (library maps), or removes an
  /// earlier autosave once nothing is unsaved any more (undone, reverted).
  Future<void> autosave() async {
    final store = recovery, path = document.path;
    if (store == null || path == null || !document.isInLibrary) return;
    if (isDirty) {
      await store.write(path, serialize());
      _autosaved = true;
    } else if (_autosaved) {
      await store.clear(path);
      _autosaved = false;
    }
  }

  /// The changes are being thrown away (closed without saving, reopened).
  Future<void> discardAutosave() async {
    final path = document.path;
    if (path != null) await recovery?.clear(path);
    _autosaved = false;
  }

  /// This map was opened from an autosave: it differs from the file.
  void markRecovered() {
    _autosaved = true;
    history.markUnsaved();
  }

  /// Saves pending changes (export reads the set from disk), then lets the
  /// user pick where to put the `.osz`. Returns false if cancelled.
  Future<bool> exportOsz() async {
    final lib = library, setPath = document.setPath;
    if (lib == null || setPath == null) return false;
    if (isDirty && !await save()) return false;
    final bytes = await lib.exportOsz(setPath);
    final set = LibrarySet(setPath, const []);
    return files.saveOsz(BeatmapLibrary.oszFileName(set), bytes);
  }
}
