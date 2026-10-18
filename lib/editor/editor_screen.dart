import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../app_fonts.dart';
import '../core/core.dart';
import '../home/dev_badge.dart';
import '../platform/app_settings.dart';
import '../platform/audio_session.dart';
import '../platform/beatmap_file_service.dart';
import '../platform/beatmap_library.dart';
import '../platform/map_folder.dart';
import 'editor_controller.dart';
import 'song_setup_screen.dart';
import 'timing_mode_panel.dart';
import 'timing_screen.dart';
import 'render/playfield_transform.dart';
import 'render/timeline_painter.dart';
import 'widgets/editor_mode_button.dart';
import 'widgets/editor_toolbars.dart';
import 'widgets/go_to_time_dialog.dart';
import 'widgets/hitsound_view.dart';
import 'widgets/mini_timeline.dart';
import 'widgets/playfield_view.dart';
import 'widgets/skin_picker.dart';
import 'widgets/timeline_view.dart';

String formatEditorTime(double ms) {
  final neg = ms < 0;
  final t = ms.abs().round();
  final m = t ~/ 60000, s = (t ~/ 1000) % 60, x = t % 1000;
  String p(int v, int w) => v.toString().padLeft(w, '0');
  return '${neg ? '-' : ''}${p(m, 2)}:${p(s, 2)}:${p(x, 3)}';
}

/// Landscape-only editor laid out like osu!stable's: zoomed timeline + snap /
/// undo / save / menu (top), compose toolbox (left), playfield (centre, most
/// of the screen), hitsound / snap toolbox (right), time + whole-map
/// overview + play / rate (bottom). No app bar — leaving goes through the
/// system back gesture or the menu's "Close editor".
///
/// The route pops with the path of another difficulty of the set when the
/// user asks to switch to it (after creating it); the caller opens it.
class EditorScreen extends StatefulWidget {
  final EditorController controller;
  const EditorScreen({super.key, required this.controller});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  /// Pauses playback when the app is backgrounded (an editor should not keep
  /// playing music nobody is looking at).
  late final AppLifecycleListener _lifecycle;

  Timer? _autosave;

  EditorController get c => widget.controller;

  /// Which screen is shown under the top bar (picked with the mode button).
  EditorMode _mode = EditorMode.compose;

  /// Holds keyboard focus for the shortcuts; taking it back also commits a
  /// Timing / Song setup field still being edited (its focus loss) before
  /// the mode switch disposes it.
  final FocusNode _keys = FocusNode(debugLabel: 'editor shortcuts');

  /// The ⋮ menu (system back closes it before the editor).
  final MenuController _menu = MenuController();

  /// The Control Points popup is open over the current mode's screen.
  bool _controlPoints = false;

  void _openControlPoints() => setState(() => _controlPoints = true);

  void _closeControlPoints() {
    _keys.requestFocus(); // commits a field still being edited
    setState(() => _controlPoints = false);
  }

  void _setMode(EditorMode mode) {
    if (mode == _mode) return;
    _keys.requestFocus();
    c.metronome = mode == EditorMode.timing;
    setState(() => _mode = mode);
  }

  @override
  void initState() {
    super.initState();
    // Drives `controller.time` from the clock every frame, only while
    // playing (an always-running ticker would keep the GPU busy when idle).
    _ticker = createTicker((_) => c.tick());
    c.trackDifficulty();
    // Unsaved edits are autosaved now and then, and whenever the app goes
    // to the background (where Android may kill it).
    _autosave = Timer.periodic(const Duration(seconds: 20), (_) => c.autosave());
    _lifecycle = AppLifecycleListener(
      onHide: () {
        c.pause();
        c.autosave();
      },
      // The audio route may have changed meanwhile (headphones plugged in).
      onShow: () {
        if (c.hasAudio) AudioSession.instance.refreshLatency();
      },
    );
    c.addListener(_syncTicker);
    c.lastHistoryStep.addListener(_showHistoryStep);
    _interruptions = AudioSession.instance.interruptions.listen(_onInterruption);
    // The device's output latency (current route), for the auto offset.
    if (c.hasAudio) AudioSession.instance.refreshLatency();
  }

  /// After an undo / redo: go to the mode or panel where the change can be
  /// seen (the controller already selected / seeked to it).
  void _showHistoryStep() {
    final step = c.lastHistoryStep.value;
    if (step == null || !mounted) return;
    final f = step.focus;
    void compose() {
      if (_controlPoints) _closeControlPoints();
      _setMode(EditorMode.compose);
    }

    // Hitsound edits (and timing points changed in place: sample settings)
    // are shown by the Hitsound screen itself: stay there.
    if (_mode == EditorMode.hitsound && !_controlPoints) {
      if (f.area == EditArea.objects && EditorController.hitsoundEditLabels.contains(f.label)) return;
      if (f.area == EditArea.timing &&
          f.timingPoints.length == f.removedTimingPoints.length &&
          [for (var i = 0; i < f.timingPoints.length; i++) f.timingPoints[i].time == f.removedTimingPoints[i].time]
              .every((same) => same)) {
        return;
      }
    }

    switch (f.area) {
      case EditArea.objects || EditArea.breaks || EditArea.composeSettings:
        compose();
      case EditArea.timing:
        // The popup, when open, selects the point itself.
        if (_controlPoints) break;
        if (f.inheritedOnly) {
          _openControlPoints();
        } else {
          _setMode(EditorMode.timing);
        }
      case EditArea.sliderSettings:
        if (_mode != EditorMode.timing && _mode != EditorMode.songSetup) _setMode(EditorMode.timing);
      case EditArea.songSetup:
        if (_controlPoints) _closeControlPoints();
        _setMode(EditorMode.songSetup);
      case EditArea.bookmarks || EditArea.other:
        break;
    }
  }

  void _syncTicker() {
    if (c.isPlaying && !_ticker.isActive) {
      _ticker.start();
    } else if (!c.isPlaying && _ticker.isActive) {
      _ticker.stop();
    }
    _syncAudioFocus();
  }

  // Audio focus (Android): held while playing; losing it (a call, another
  // app), unplugging headphones or the output failing pauses playback.
  StreamSubscription<AudioInterruption>? _interruptions;
  bool _focusHeld = false;

  void _syncAudioFocus() {
    if (c.isPlaying == _focusHeld) return;
    _focusHeld = c.isPlaying;
    if (!_focusHeld) {
      AudioSession.instance.release();
      return;
    }
    AudioSession.instance.acquire().then((granted) {
      if (granted || !mounted || !c.isPlaying) return;
      c.pause();
      _audioNote('Another app (or a call) is using the audio');
    });
  }

  void _onInterruption(AudioInterruption reason) {
    if (!mounted) return;
    // Unplugged: the sound now goes elsewhere, with another latency.
    if (reason == AudioInterruption.noisy) AudioSession.instance.refreshLatency();
    final playing = c.isPlaying;
    c.pause();
    if (!playing && reason != AudioInterruption.outputFailed) return;
    _audioNote(switch (reason) {
      AudioInterruption.focusLoss => 'Paused: another app or a call took the audio',
      AudioInterruption.noisy => 'Paused: headphones disconnected',
      AudioInterruption.outputFailed => 'Audio output unavailable; playback paused',
    });
  }

  /// A narrow floating note: the play button (bottom right) stays usable.
  void _audioNote(String text) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        width: 380,
        duration: const Duration(seconds: 3),
      ));

  @override
  void dispose() {
    c.removeListener(_syncTicker);
    c.lastHistoryStep.removeListener(_showHistoryStep);
    _interruptions?.cancel();
    if (_focusHeld) AudioSession.instance.release();
    _lifecycle.dispose();
    _ticker.dispose();
    _autosave?.cancel();
    _keys.dispose();
    c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ok = await c.save();
      if (ok) messenger.showSnackBar(SnackBar(content: Text('Saved ${c.document.fileName}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  /// Mapping Tools' "Hitsound copier": this difficulty's hitsounds into the
  /// chosen other difficulties of the set (on disk), with an Undo.
  Future<void> _copyHitsounds() async {
    final messenger = ScaffoldMessenger.of(context);
    final others = await c.otherDifficulties();
    if (!mounted) return;
    if (others.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('No other difficulties in this set')));
      return;
    }
    final choice = await showDialog<_HitsoundCopyChoice>(
      context: context,
      builder: (_) => _CopyHitsoundsDialog(difficulties: others),
    );
    if (choice == null || !mounted) return;
    final previous = await c.copyHitsoundsTo(
      choice.paths,
      leniency: choice.leniency,
      samplePoints: choice.samplePoints,
      clearUnmatched: choice.clearUnmatched,
    );
    if (!mounted) return;
    final n = previous.length;
    messenger.showSnackBar(SnackBar(
      content: Text(n == 0
          ? 'The chosen difficulties already sound like this one'
          : 'Copied hitsounds to $n difficult${n == 1 ? 'y' : 'ies'}'),
      action: n == 0 ? null : SnackBarAction(label: 'Undo', onPressed: () => c.restoreDifficulties(previous)),
      duration: const Duration(seconds: 8),
    ));
  }

  /// osu!'s "Open song folder": the set's folder in the system file browser
  /// (on Android the Files app, through the app's documents provider).
  Future<void> _openMapFolder() async {
    final dir = _mapFolderOf(c);
    if (dir == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final result = await MapFolder.open(dir);
    final text = switch (result) {
      MapFolderResult.opened => c.isDirty ? 'Unsaved changes are not in the folder until you save' : null,
      MapFolderResult.openedLibraryRoot => 'Opened the osuEdit library in Files: the map is in "${dir.split(RegExp(r'[\\/]')).last}"',
      MapFolderResult.failed => 'Could not open the folder (no file manager found)',
    };
    if (text != null) messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _exportOsz() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ok = await c.exportOsz();
      if (ok) messenger.showSnackBar(const SnackBar(content: Text('Exported .osz')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  /// Picks a file and copies it into the set via [import].
  Future<void> _setFile(
    Future<PickedFile?> Function() pick,
    Future<void> Function(PickedFile) import,
    String done,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await pick();
      if (file == null) return;
      await import(file);
      final error = c.audioError;
      messenger.showSnackBar(SnackBar(content: Text(error ?? done)));
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _setAudio() => _setFile(c.files.pickAudioFile, c.importAudioFile, 'Audio file set');
  Future<void> _setBackground() => _setFile(c.files.pickImageFile, c.importBackgroundFile, 'Background set');

  Future<bool> _confirmDiscard() async {
    if (!c.isDirty) return true;
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unsaved changes'),
        content: const Text('Discard changes and close the editor?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Discard')),
        ],
      ),
    );
    return r ?? false;
  }

  Future<void> _close() async {
    final navigator = Navigator.of(context);
    if (!await _confirmDiscard()) return;
    await c.discardAutosave();
    navigator.pop();
  }



  /// Creates a new (empty or duplicated) difficulty in the set and offers
  /// to switch to it.
  Future<void> _newDifficulty({required bool copy}) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _TextPromptDialog(
        title: copy ? 'Duplicate difficulty' : 'New difficulty',
        label: 'Difficulty name',
        initial: copy ? '${c.beatmap.version} (copy)' : '',
        action: 'Create',
      ),
    );
    if (name == null || !mounted) return;
    final String? path;
    try {
      path = await c.createDifficulty(name, copyObjects: copy);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not create difficulty: $e')));
      return;
    }
    if (path == null || !mounted) return;
    final open = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Created "$name"'),
        content: Text(c.isDirty ? 'Open it now? Your changes here will be saved first.' : 'Open it now?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Stay here')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Open')),
        ],
      ),
    );
    if (open != true) return;
    if (c.isDirty && !await c.save()) return;
    navigator.pop(path);
  }

  /// Copies (or cuts) the selection, and puts stable's timestamp text for
  /// it (`00:01:234 (1,2,3) - `) on the system clipboard for modding posts.
  void _copy({bool cut = false}) {
    final ts = c.selectionTimestamp;
    if (ts == null) return;
    cut ? c.cutSelection() : c.copySelection();
    Clipboard.setData(ClipboardData(text: ts)).catchError((Object _) {});
  }

  /// The bottom-left time readout's dialog: minute / second / millisecond
  /// wheels, or the manual (pasted timestamp) input behind its button.
  Future<void> _goToTime() async {
    final maxT = c.maxTime;
    final lastObj = c.beatmap.hitObjects.isEmpty ? 0.0 : c.beatmap.hitObjects.last.time;
    final r = await showDialog<GoToTimeResult>(
      context: context,
      builder: (_) => GoToTimeDialog(
        initialMs: math.max(0, c.time.value.round()),
        maxMs: (maxT.isFinite ? maxT : math.max(lastObj, 10 * 60000.0)).round(),
      ),
    );
    if (!mounted) return;
    switch (r) {
      case GoToTimePicked(:final ms):
        c.pause();
        c.seek(ms.toDouble());
      case GoToTimeManual():
        await _goToTimestamp();
      case null:
        break;
    }
  }

  /// Seeks to a pasted modding timestamp and selects the objects it names.
  Future<void> _goToTimestamp() async {
    final messenger = ScaffoldMessenger.of(context);
    var initial = '';
    try {
      final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
      if (EditorTimestamp.parse(clip) != null) initial = clip.trim();
    } catch (_) {
      // No clipboard access: start empty.
    }
    if (!mounted) return;
    final text = await showDialog<String>(
      context: context,
      builder: (_) => _TextPromptDialog(
        title: 'Go to timestamp',
        label: 'e.g. 00:01:234 (1,2,3) -',
        initial: initial,
        action: 'Go',
      ),
    );
    if (text == null) return;
    final ts = EditorTimestamp.parse(text);
    if (ts == null) {
      messenger.showSnackBar(const SnackBar(content: Text('No timestamp found (mm:ss:mmm)')));
      return;
    }
    final n = c.goToTimestamp(ts);
    if (n < ts.combos.length) {
      messenger.showSnackBar(SnackBar(content: Text('Selected $n of ${ts.combos.length} objects')));
    }
  }

  /// The Rotate or Scale panel with a live preview; dismissing it cancels.
  Future<void> _transform(_TransformKind kind) async {
    if (!c.beginTransform(label: kind == _TransformKind.rotate ? 'Rotate' : 'Scale')) return;
    final apply = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Cancel',
      barrierColor: Colors.transparent,
      pageBuilder: (_, _, _) => SafeArea(
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: EdgeInsets.only(
              top: EditorLayout.of(context).topBarHeight + 4,
              right: EditorLayout.of(context).toolboxWidth + 4,
            ),
            child: _TransformPanel(controller: c, kind: kind),
          ),
        ),
      ),
    );
    c.endTransform(apply: apply ?? false);
  }

  /// stable's "Polygon circles": a panel with a live preview at the current
  /// time (Compose); dismissing it cancels.
  Future<void> _polygon() async {
    _setMode(EditorMode.compose);
    if (_controlPoints) _closeControlPoints();
    if (!c.beginPolygon()) return;
    final fits = c.updatePolygon(vertices: PolygonOps.minVertices);
    final apply = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Cancel',
      barrierColor: Colors.transparent,
      pageBuilder: (_, _, _) => SafeArea(
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: EdgeInsets.only(
              top: EditorLayout.of(context).topBarHeight + 4,
              right: EditorLayout.of(context).toolboxWidth + 4,
            ),
            child: _PolygonPanel(controller: c, fitsAtStart: fits),
          ),
        ),
      ),
    );
    c.endPolygon(apply: apply ?? false);
  }

  /// stable's "Reset samples" / "Reset combo colours" (selection, or the
  /// whole map), one undo step.
  void _reset({required bool samples}) {
    final all = c.selection.isEmpty;
    final n = samples ? c.resetSamples() : c.resetComboColours();
    final what = samples ? 'samples' : 'combo colour skips';
    final text = n == 0
        ? 'No $what to reset${all ? '' : ' in the selection'}'
        : 'Reset $what on $n object${n == 1 ? '' : 's'}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// stable's "Resnap all notes" (or the selection) to the current snap.
  void _resnap() {
    final all = c.selection.isEmpty;
    final n = c.resnapNotes();
    final text = n == 0
        ? 'Every ${all ? 'note' : 'selected note'} is already on 1/${c.divisor}'
        : 'Resnapped $n object${n == 1 ? '' : 's'} to 1/${c.divisor}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Asks for an offset in ms and moves all notes (or the selection) by it.
  Future<void> _moveNotesInTime() async {
    final all = c.selection.isEmpty;
    final ms = await showDialog<int>(context: context, builder: (_) => _MoveNotesDialog(all: all));
    if (ms == null || !mounted) return;
    final n = c.moveNotesInTime(ms.toDouble());
    final text = n == 0 ? 'Nothing to move' : 'Moved $n object${n == 1 ? '' : 's'} by ${ms > 0 ? '+' : ''}$ms ms';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// stable's "Revert to saved": back through the history when the saved
  /// state is still on it (redo brings the changes back), otherwise reopen
  /// the file from the library.
  Future<void> _revert() async {
    if (!c.isDirty) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final inHistory = c.canRevertInHistory;
    final path = c.document.path;
    final reopen = !inHistory && c.document.isInLibrary && path != null;
    if (!inHistory && !reopen) {
      messenger.showSnackBar(const SnackBar(content: Text('The saved version is no longer in the undo history.')));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revert to saved?'),
        content: Text(
          inHistory
              ? 'All changes since the last save are undone. Redo brings them back.'
              : "All changes since the last save are discarded and the file is reopened. This can't be undone.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Revert')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (inHistory) {
      c.revertToSaved();
      messenger.showSnackBar(const SnackBar(content: Text('Reverted to the saved version')));
    } else {
      await c.discardAutosave();
      navigator.pop(path); // the library screen reopens it from disk
    }
  }

  /// Deletes this difficulty from the set (asks first; not undoable) and
  /// closes the editor.
  Future<void> _deleteDifficulty() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final count = await c.setDifficultyCount();
    if (!mounted) return;
    if (count < 2) {
      messenger.showSnackBar(const SnackBar(
        content: Text('This is the only difficulty of the set; delete the set from the library instead.'),
      ));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${c.beatmap.version}"?'),
        content: Text("The file ${c.document.fileName} is deleted from the set. This can't be undone."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      if (!await c.deleteThisDifficulty()) return;
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not delete: $e')));
      return;
    }
    await c.discardAutosave();
    messenger.showSnackBar(SnackBar(content: Text('Deleted ${c.document.fileName}')));
    navigator.pop();
  }

  /// Earlier / later and pixel nudges; stays open for repeated taps, each
  /// one its own undo step.
  void _nudge() => showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.transparent,
    pageBuilder: (_, _, _) => SafeArea(
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: EdgeInsets.only(
            top: EditorLayout.of(context).topBarHeight + 4,
            right: EditorLayout.of(context).toolboxWidth + 4,
          ),
          child: _NudgePanel(controller: c),
        ),
      ),
    ),
  );

  /// View preferences (not part of the map), applied live. Compact so every
  /// row fits a landscape phone without scrolling.
  void _showDisplaySettings() => showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 12),
      titlePadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      title: Text('Display', style: Theme.of(context).textTheme.titleMedium),
      content: SingleChildScrollView(
        child: ListTileTheme(
          data: const ListTileThemeData(dense: true, visualDensity: VisualDensity.compact),
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Text('Background dim'),
                    Expanded(
                      child: Slider(
                        value: c.backgroundDim,
                        divisions: 20,
                        onChanged: c.background == null && !c.hasStoryboard ? null : (v) => c.backgroundDim = v,
                      ),
                    ),
                    SizedBox(width: 44, child: Text('${(c.backgroundDim * 100).round()}%', textAlign: TextAlign.end)),
                  ],
                ),
                _displaySwitch(
                    c.hasAudio ? 'Timeline waveform (Timing, Hitsounds)' : 'Timeline waveform (no audio)', c.showWaveform,
                    (v) => c.showWaveform = v),
                _displaySwitch(c.hasStoryboard ? 'Storyboard' : 'Storyboard (none)', c.showStoryboard,
                    (v) => c.showStoryboard = v),
                _displaySwitch('Follow points', c.showFollowPoints, (v) => c.showFollowPoints = v),
                _displaySwitch('Stacking', c.showStacking, (v) => c.showStacking = v),
                _displaySwitch('Hit animations', c.hitAnimations, (v) => c.hitAnimations = v),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Skin', style: TextStyle(fontSize: 15)),
                  subtitle: Text(c.skin?.info.name ?? 'Default', maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showSkinPicker(context, files: c.files),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
    ),
  );

  static Widget _displaySwitch(String title, bool value, ValueChanged<bool> onChanged) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title, style: const TextStyle(fontSize: 15)),
    value: value,
    onChanged: onChanged,
  );

  void _showAudioSettings() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _AudioSettingsSheet(controller: c, onSetAudio: _setAudio),
  );

  /// Enter finishes a slider being drawn; Esc cancels it (or deselects).
  void _enter() {
    if (c.isDrafting) c.finishSlider();
  }

  Map<ShortcutActivator, VoidCallback> get _shortcuts => {
    const SingleActivator(LogicalKeyboardKey.space): c.togglePlay,
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true): c.undo,
    const SingleActivator(LogicalKeyboardKey.keyY, control: true): c.redo,
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): c.redo,
    const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
    const SingleActivator(LogicalKeyboardKey.delete): c.deleteSelection,
    const SingleActivator(LogicalKeyboardKey.backspace): c.deleteSelection,
    const SingleActivator(LogicalKeyboardKey.keyQ): c.toggleNewCombo,
    const SingleActivator(LogicalKeyboardKey.keyW): () => c.toggleAddition(HitSoundFlags.whistle),
    const SingleActivator(LogicalKeyboardKey.keyE): () => c.toggleAddition(HitSoundFlags.finish),
    const SingleActivator(LogicalKeyboardKey.keyR): () => c.toggleAddition(HitSoundFlags.clap),
    const SingleActivator(LogicalKeyboardKey.keyT): () => c.gridSnap = !c.gridSnap,
    const SingleActivator(LogicalKeyboardKey.keyY): () => c.distanceSnap = !c.distanceSnap,
    const SingleActivator(LogicalKeyboardKey.keyL): () => c.lockNotes = !c.lockNotes,
    const SingleActivator(LogicalKeyboardKey.digit1): () => c.tool = EditorTool.select,
    const SingleActivator(LogicalKeyboardKey.digit2): () => c.tool = EditorTool.circle,
    const SingleActivator(LogicalKeyboardKey.digit3): () => c.tool = EditorTool.slider,
    const SingleActivator(LogicalKeyboardKey.digit4): () => c.tool = EditorTool.spinner,
    const SingleActivator(LogicalKeyboardKey.enter): _enter,
    const SingleActivator(LogicalKeyboardKey.arrowLeft): () => c.stepBeat(forward: false),
    const SingleActivator(LogicalKeyboardKey.arrowRight): () => c.stepBeat(forward: true),
    const SingleActivator(LogicalKeyboardKey.escape): c.clearSelection,
    const SingleActivator(LogicalKeyboardKey.keyA, control: true): c.selectAll,
    const SingleActivator(LogicalKeyboardKey.keyC, control: true): _copy,
    const SingleActivator(LogicalKeyboardKey.keyX, control: true): () => _copy(cut: true),
    const SingleActivator(LogicalKeyboardKey.keyV, control: true): c.paste,
    const SingleActivator(LogicalKeyboardKey.keyH, control: true): () => c.flipSelection(horizontal: true),
    const SingleActivator(LogicalKeyboardKey.keyJ, control: true): () => c.flipSelection(horizontal: false),
    // stable's Ctrl+Shift+R (rotate) and Ctrl+Shift+S (scale) dialogs.
    const SingleActivator(LogicalKeyboardKey.keyR, control: true, shift: true): () =>
        _transform(_TransformKind.rotate),
    const SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true): () =>
        _transform(_TransformKind.scale),
    // lazer's Reverse and Convert to stream.
    const SingleActivator(LogicalKeyboardKey.keyG, control: true): c.reverseSelection,
    const SingleActivator(LogicalKeyboardKey.keyF, control: true, shift: true): c.convertSelectionToStream,
    const SingleActivator(LogicalKeyboardKey.keyM, control: true, shift: true): c.mergeSelection,
    // Stable's Ctrl+< / Ctrl+> (with or without shift).
    const SingleActivator(LogicalKeyboardKey.comma, control: true): () => c.rotateSelection(clockwise: false),
    const SingleActivator(LogicalKeyboardKey.period, control: true): () => c.rotateSelection(clockwise: true),
    const SingleActivator(LogicalKeyboardKey.comma, control: true, shift: true): () =>
        c.rotateSelection(clockwise: false),
    const SingleActivator(LogicalKeyboardKey.period, control: true, shift: true): () =>
        c.rotateSelection(clockwise: true),
    const SingleActivator(LogicalKeyboardKey.keyB, control: true): c.toggleBookmark,
    const SingleActivator(LogicalKeyboardKey.keyB, control: true, shift: true): c.removeAllBookmarks,
    const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () => c.seekBookmark(forward: false),
    const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): () => c.seekBookmark(forward: true),
    const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true): () => c.moveSelectionInTime(forward: false),
    const SingleActivator(LogicalKeyboardKey.arrowRight, control: true): () => c.moveSelectionInTime(forward: true),
  };

  /// Shortcuts outside Compose: no placement / selection keys, and none
  /// that a Timing / Song setup text field could also want.
  Map<ShortcutActivator, VoidCallback> get _modeShortcuts => {
    const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
    if (_mode == EditorMode.hitsound) ...{
      const SingleActivator(LogicalKeyboardKey.space): c.togglePlay,
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true): c.undo,
      const SingleActivator(LogicalKeyboardKey.keyY, control: true): c.redo,
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): c.redo,
    },
  };

  /// While the Control Points popup is open: its fields take the keys.
  Map<ShortcutActivator, VoidCallback> get _controlPointsShortcuts => {
    const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
    const SingleActivator(LogicalKeyboardKey.escape): _closeControlPoints,
  };

  /// A non-Compose mode's screen above the bottom strip (the strip keeps
  /// time and playback available in every mode).
  Widget _modeBody(BuildContext context) {
    final barHeight = EditorLayout.of(context).bottomBarHeight;
    return Stack(
      children: [
        Positioned.fill(
          bottom: barHeight,
          child: switch (_mode) {
            EditorMode.songSetup => SongSetupPanel(
              controller: c,
              onSetAudio: _setAudio,
              onSetBackground: _setBackground,
              onNewDifficulty: (copy) => _newDifficulty(copy: copy),
              onDeleteDifficulty: _deleteDifficulty,
            ),
            EditorMode.timing => TimingModePanel(controller: c),
            EditorMode.hitsound => HitsoundView(controller: c),
            EditorMode.compose => const SizedBox.shrink(), // not shown here (see _body)
          },
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: barHeight,
          child: _BottomBar(controller: c, onTime: _goToTime),
        ),
      ],
    );
  }

  /// Toolboxes, playfield and the bottom strip. With the overview hidden
  /// the strip shrinks to two corner pills and the playfield runs down to
  /// the bottom edge between them.
  Widget _body(BuildContext context) {
    final barHeight = EditorLayout.of(context).bottomBarHeight;
    final below = EdgeInsets.only(bottom: barHeight);
    return Stack(
      children: [
        Positioned.fill(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: below,
                child: ComposeToolbox(controller: c),
              ),
              Expanded(
                child: Padding(
                  padding: c.showMiniTimeline ? below : EdgeInsets.zero,
                  child: LayoutBuilder(
                    builder: (context, box) => Stack(
                      children: [
                        Positioned.fill(child: PlayfieldView(controller: c)),
                        // While zoomed in: the whole playfield at 1x, above
                        // the right corner pill when the overview is hidden.
                        Positioned(
                          right: 8,
                          bottom: (c.showMiniTimeline ? 0 : barHeight) + 8,
                          child: PlayfieldOverview(controller: c, viewport: box.biggest),
                        ),
                        // Top left of the inner area (just right of Sample /
                        // Addition), while the side strips are hidden.
                        Positioned(
                          left: 6,
                          top: 6,
                          child: _StarRatingChip(controller: c, area: box.biggest),
                        ),
                        Positioned.fill(
                          child: _ContextOverlay(
                            controller: c,
                            onCopy: _copy,
                            onCut: () => _copy(cut: true),
                            onRotate: () => _transform(_TransformKind.rotate),
                            onScale: () => _transform(_TransformKind.scale),
                            onNudge: _nudge,
                            area: box.biggest,
                            // Collapsed, the corner pills sit over the
                            // playfield's bottom corners.
                            bottomInset: c.showMiniTimeline ? 0 : barHeight,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: below,
                child: HitsoundToolbox(controller: c),
              ),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: barHeight,
          child: _BottomBar(controller: c, onTime: _goToTime, compose: true),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // Back closes an open ⋮ menu first (it is not a route of its own).
        if (_menu.isOpen) return _menu.close();
        if (_controlPoints) return _closeControlPoints();
        await _close();
      },
      child: CallbackShortcuts(
        bindings: _controlPoints
            ? _controlPointsShortcuts
            : _mode == EditorMode.compose
                ? _shortcuts
                : _modeShortcuts,
        child: Focus(
          focusNode: _keys,
          autofocus: true,
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) => Scaffold(
              body: SafeArea(
                child: Column(
                  children: [
                    SizedBox(
                      height: EditorLayout.of(context).topBarHeight,
                      child: _TopBar(
                        controller: c,
                        mode: _mode,
                        onMode: _setMode,
                        onControlPoints: _openControlPoints,
                        menu: _menu,
                        onSave: _save,
                        onMenu: (v) => switch (v) {
                          'controlpoints' => _openControlPoints(),
                          'setup' => _setMode(EditorMode.songSetup),
                          'audiosettings' => _showAudioSettings(),
                          'display' => _showDisplaySettings(),
                          'export' => _exportOsz(),
                          'folder' => _openMapFolder(),
                          'copyhitsounds' => _copyHitsounds(),
                          'selectall' => c.selectAll(),
                          'paste' => c.paste(),
                          'bookmark' => c.toggleBookmark(),
                          'prevbookmark' => c.seekBookmark(forward: false),
                          'nextbookmark' => c.seekBookmark(forward: true),
                          'clearbookmarks' => c.removeAllBookmarks(),
                          'polygon' => _polygon(),
                          'resetsamples' => _reset(samples: true),
                          'resetcolours' => _reset(samples: false),
                          'resnap' => _resnap(),
                          'movetime' => _moveNotesInTime(),
                          'revert' => _revert(),
                          _ => _close(),
                        },
                      ),
                    ),
                    Divider(height: 1, thickness: 1, color: Theme.of(context).colorScheme.outlineVariant),
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(child: _mode == EditorMode.compose ? _body(context) : _modeBody(context)),
                          if (_controlPoints)
                            Positioned.fill(
                              bottom: EditorLayout.of(context).bottomBarHeight,
                              child: _ControlPointsPopup(controller: c, onClose: _closeControlPoints),
                            ),
                          const Positioned(top: 1, left: 0, right: 0, child: Center(child: DevBadge())),
                          Positioned(
                            // Keyed: the popup appearing before it must not
                            // take over its state (the toast being shown).
                            key: const ValueKey('history toast'),
                            // Just above the bottom strip.
                            bottom: EditorLayout.of(context).bottomBarHeight + 12,
                            left: 0,
                            right: 0,
                            child: IgnorePointer(child: Center(child: HistoryToast(step: c.lastHistoryStep))),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Control Points panel as a popup over the current screen, between
/// the top bar (left free: its timeline still scrubs) and the bottom strip.
/// Tapping the dimmed area around it closes it.
class _ControlPointsPopup extends StatelessWidget {
  final EditorController controller;
  final VoidCallback onClose;
  const _ControlPointsPopup({required this.controller, required this.onClose});

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onClose,
          child: const ColoredBox(color: Color(0x99000000)),
        ),
      ),
      Positioned.fill(
        child: Padding(
          // Wide margins and a light dim so the screen underneath shows.
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
          child: Material(
            elevation: 8,
            // Outlined so the panel stands out from the dimmed screen.
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: Theme.of(context).colorScheme.outline),
            ),
            clipBehavior: Clip.antiAlias,
            child: ControlPointsPanel(controller: controller, onClose: onClose),
          ),
        ),
      ),
    ],
  );
}

/// Placeholder for a mode that has no screen yet.
/// Top strip: the mode button, the zoomed timeline, then beat snap, undo / redo, save and
/// the menu (file, audio and map setup actions).
class _TopBar extends StatelessWidget {
  final EditorController controller;
  final VoidCallback onSave;
  final void Function(String) onMenu;
  final EditorMode mode;
  final ValueChanged<EditorMode> onMode;
  final VoidCallback onControlPoints;
  final MenuController menu;

  const _TopBar({
    required this.menu,
    required this.controller,
    required this.mode,
    required this.onMode,
    required this.onControlPoints,
    required this.onSave,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final height = EditorLayout.of(context).topBarHeight - EditorLayout.topDeadZone;
    final scheme = Theme.of(context).colorScheme;
    const dense = VisualDensity.compact;
    return Material(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.only(top: EditorLayout.topDeadZone),
        child: Row(
          children: [
            // Same width as the toolbox below it.
            SizedBox(
              width: EditorLayout.of(context).toolboxWidth,
              child: EditorModeButton(mode: mode, onChanged: onMode, onControlPoints: onControlPoints),
            ),
            Expanded(
              child: TimelineView(
                controller: c,
                height: height,
                // Outside Compose: objects are faded context, not editable.
                objectsInBackground: mode != EditorMode.compose,
              ),
            ),
            const SizedBox(width: 6),
            Tooltip(
              message: 'Beat snap divisor',
              child: DropdownButton<int>(
                value: c.divisor,
                isDense: true,
                underline: const SizedBox(),
                items: [for (final d in EditorController.divisors) DropdownMenuItem(value: d, child: Text('1/$d'))],
                onChanged: (d) => c.divisor = d ?? c.divisor,
              ),
            ),
            IconButton(
              tooltip: 'Undo',
              visualDensity: dense,
              onPressed: c.canUndo ? c.undo : null,
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              tooltip: 'Redo',
              visualDensity: dense,
              onPressed: c.canRedo ? c.redo : null,
              icon: const Icon(Icons.redo),
            ),
            IconButton(
              tooltip: c.isDirty ? 'Save (unsaved changes)' : 'Save',
              visualDensity: dense,
              onPressed: onSave,
              icon: Badge(isLabelVisible: c.isDirty, smallSize: 8, child: const Icon(Icons.save)),
            ),
            _EditorMenu(controller: c, menu: menu, onMenu: onMenu),
          ],
        ),
      ),
    );
  }
}

/// The folder "Open map folder" opens: the library set, or for a map opened
/// from elsewhere its file's folder (desktop only: on a phone that is a
/// private copy no file manager can reach).
String? _mapFolderOf(EditorController c) {
  final set = c.document.setPath;
  if (set != null) return set;
  final path = c.document.path;
  if (path == null || Platform.isAndroid || Platform.isIOS) return null;
  return File(path).parent.path;
}

/// The ⋮ menu: five groups that open beside it, so it fits a landscape
/// phone without scrolling (it had grown to 16 items).
class _EditorMenu extends StatelessWidget {
  final EditorController controller;
  final MenuController menu;
  final void Function(String) onMenu;
  const _EditorMenu({required this.controller, required this.menu, required this.onMenu});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    Widget item(String value, String label, {bool enabled = true}) => MenuItemButton(
          onPressed: enabled ? () => onMenu(value) : null,
          child: Text(label),
        );
    Widget group(String label, IconData icon, List<Widget> items) => SubmenuButton(
          leadingIcon: Icon(icon, size: 20),
          menuChildren: items,
          child: Text(label),
        );
    return MenuAnchor(
      controller: menu,
      menuChildren: [
        group('Edit', Icons.edit_note, [
          item('selectall', 'Select all'),
          item('paste', c.clipboardCount > 0 ? 'Paste ${c.clipboardCount} at current time' : 'Paste',
              enabled: c.clipboardCount > 0),
          const Divider(height: 1),
          // stable's pattern / reset tools: on the selection, or the whole
          // map when nothing is selected.
          item('polygon', 'Polygon circles…'),
          item('resetsamples', c.selection.isEmpty ? 'Reset all samples' : 'Reset samples of selection'),
          item('resetcolours',
              c.selection.isEmpty ? 'Reset all combo colours' : 'Reset combo colours of selection'),
          // Curve type of newly drawn sliders ("Default" picks by point count).
          SubmenuButton(
            menuChildren: [
              for (final (type, label) in const [
                (DefaultSliderType.auto, 'Default'),
                (DefaultSliderType.bezier, 'Bezier'),
                (DefaultSliderType.linear, 'Linear'),
                (DefaultSliderType.catmull, 'Catmull'),
              ])
                MenuItemButton(
                  leadingIcon: Icon(c.defaultSliderType == type ? Icons.check : null, size: 20),
                  onPressed: () => c.defaultSliderType = type,
                  child: Text(label),
                ),
            ],
            child: const Text('New slider type'),
          ),
          const Divider(height: 1),
          item('resnap', c.selection.isEmpty ? 'Resnap all notes (1/${c.divisor})' : 'Resnap selection (1/${c.divisor})'),
          item('movetime', c.selection.isEmpty ? 'Move all notes in time…' : 'Move selection in time…'),
        ]),
        group('Bookmarks', Icons.bookmark_border, [
          item('bookmark', c.bookmarkHere == null ? 'Add bookmark here' : 'Remove bookmark here'),
          if (c.beatmap.bookmarks.isNotEmpty) ...[
            item('prevbookmark', 'Previous bookmark'),
            item('nextbookmark', 'Next bookmark'),
            item('clearbookmarks', 'Remove all bookmarks'),
          ],
        ]),
        group('Map', Icons.library_music_outlined, [
          item('controlpoints', 'Control points…'),
          // Files and difficulties of the set are managed there.
          item('setup', 'Song setup'),
          if (c.canExportOsz) item('export', 'Export .osz…'),
          if (MapFolder.supported && _mapFolderOf(c) != null) item('folder', 'Open map folder'),
          if (c.document.isInLibrary) item('copyhitsounds', 'Copy hitsounds to…'),
          const Divider(height: 1),
          item('revert', 'Revert to saved…', enabled: c.isDirty),
        ]),
        group('Settings', Icons.tune, [
          item('audiosettings', c.hasAudio ? 'Audio settings…' : 'Audio settings… (no audio)'),
          item('display', 'Display…'),
        ]),
        const Divider(height: 1),
        MenuItemButton(
          leadingIcon: const Icon(Icons.close, size: 20),
          onPressed: () => onMenu('close'),
          child: const Text('Close editor'),
        ),
      ],
      builder: (context, menu, _) => IconButton(
        tooltip: 'Menu',
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        icon: const Icon(Icons.more_vert),
      ),
    );
  }
}

/// Bottom strip (stable's layout): current time, whole-map overview,
/// play / pause, playback rate. The overview is collapsible; collapsed, only
/// the two corner groups are drawn and everything between them is left to
/// the playfield underneath.
class _BottomBar extends StatelessWidget {
  final EditorController controller;
  final VoidCallback onTime;
  /// Compose: the star rating and the difficulty graph on the overview.
  final bool compose;
  const _BottomBar({required this.controller, required this.onTime, this.compose = false});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final color = Theme.of(context).colorScheme.surfaceContainer;
    final expanded = c.showMiniTimeline;
    final left = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: 'Go to time',
          child: InkWell(
            onTap: onTime,
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 96,
              height: 40,
              child: Center(
                child: ValueListenableBuilder<double>(
                  valueListenable: c.time,
                  builder: (context, t, _) => Text(
                    formatEditorTime(t),
                    maxLines: 1,
                    style: monoNumbers,
                  ),
                ),
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: expanded ? 'Hide map overview' : 'Show map overview',
          visualDensity: VisualDensity.compact,
          onPressed: () => c.showMiniTimeline = !expanded,
          icon: Icon(expanded ? Icons.expand_more : Icons.expand_less),
        ),
      ],
    );
    final layout = EditorLayout.of(context);
    final toolboxWidth = layout.toolboxWidth;
    final right = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: c.isPlaying ? 'Pause (Space)' : 'Play (Space)',
          onPressed: c.togglePlay,
          iconSize: 32,
          style: IconButton.styleFrom(
            fixedSize: Size(64, layout.bottomBarHeight), // fills the strip, icon centred
            // The default 8 dp padding leaves less than the 32 dp icon in the
            // strip's height; the squeezed glyph then hangs below centre.
            padding: EdgeInsets.zero,
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          // The play triangle's glyph sits right of its box's centre; nudge it.
          icon: c.isPlaying
              ? const Icon(Icons.pause)
              : Transform.translate(offset: const Offset(-2, 0), child: const Icon(Icons.play_arrow)),
        ),
        // Exactly the toolbox column's width, so the border between play
        // and rate lines up with the column's left edge above.
        SizedBox(
          width: toolboxWidth,
          child: Tooltip(
            message: 'Playback rate',
            child: DropdownButtonHideUnderline(
              child: DropdownButton<double>(
                value: c.rate,
                isDense: true,
                isExpanded: true,
                alignment: Alignment.center,
                iconSize: 16,
                padding: const EdgeInsets.only(left: 4, right: 2),
                items: [
                  for (final r in EditorController.rates)
                    DropdownMenuItem(
                      value: r,
                      alignment: Alignment.center,
                      child: Text('${(r * 100).round()}%', style: const TextStyle(fontSize: 13)),
                    ),
                ],
                onChanged: (r) => c.rate = r ?? c.rate,
              ),
            ),
          ),
        ),
      ],
    );
    if (expanded) {
      return Material(
        color: color,
        child: Row(
          children: [
            left,
            Expanded(
              // As tall as the strip, like the play button beside it.
              child: MiniTimeline(controller: c, difficultyGraph: compose),
            ),
            right,
          ],
        ),
      );
    }
    const r = Radius.circular(10);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: color,
          borderRadius: const BorderRadius.only(topRight: r),
          child: left,
        ),
        const Spacer(),
        Material(
          color: color,
          borderRadius: const BorderRadius.only(topLeft: r),
          child: right,
        ),
      ],
    );
  }
}

/// Buttons for whatever is being edited, placed in the free space to the
/// left and right of the playfield (outside the margin where circles can be
/// drawn), so they never cover objects or the toolboxes. Left: selection
/// actions (delete, copy / cut, flip, rotate, move in time). Right: the
/// slider being drawn, or the selected slider's shape / repeats / control
/// points. Nothing when there is nothing to act on.
class _ContextOverlay extends StatelessWidget {
  final EditorController controller;
  final Size area;
  final double bottomInset;
  final VoidCallback onCopy;
  final VoidCallback onCut;
  final VoidCallback onRotate;
  final VoidCallback onScale;
  final VoidCallback onNudge;
  const _ContextOverlay({
    required this.controller,
    required this.area,
    required this.bottomInset,
    required this.onCopy,
    required this.onCut,
    required this.onRotate,
    required this.onScale,
    required this.onNudge,
  });

  /// Width of the free strip on each side of the playfield's object area
  /// (the playfield plus the margin its edge circles may reach into). Where
  /// that strip is too narrow for the buttons (screens close to the
  /// playfield's own aspect ratio), the panels reach into the margin only as
  /// far as needed, never over the playfield itself.
  static double sideWidth(Size area) {
    final tf = PlayfieldTransform.fit(area);
    final beyondMargin = tf.origin.dx - PlayfieldTransform.marginX * tf.scale - 4;
    if (beyondMargin >= _minWidth) return math.min(beyondMargin, _maxWidth);
    return math.min(tf.origin.dx - 4, _minWidth);
  }

  static const _minWidth = 110.0;
  static const _maxWidth = 160.0;

  /// Width of the one-column action strips (room for "99 selected" and the
  /// button captions).
  static const _stripWidth = 76.0;

  /// Whether the side strips show: a slider being drawn, a selection, or
  /// something to paste (and room for them).
  static bool showsStrips(EditorController c, Size area) =>
      sideWidth(area) >= 40 && (c.isDrafting || c.selection.isNotEmpty || c.clipboardCount > 0);

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final width = sideWidth(area);
    final hasSelection = c.selection.isNotEmpty;
    if (!showsStrips(c, area)) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    Widget panel(Widget body) => Material(
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(10),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: IconButtonTheme(
          data: const IconButtonThemeData(style: ButtonStyle(visualDensity: VisualDensity.compact)),
          child: body,
        ),
      ),
    );
    // Bounded height; the panel is only as tall as its content.
    Widget side(Widget panel, {required bool left, bool narrow = false}) => Positioned(
      top: 4,
      bottom: bottomInset + 4,
      left: left ? 2 : null,
      right: left ? null : 2,
      width: narrow ? math.min(width, _stripWidth) : width,
      child: Align(alignment: Alignment.topCenter, child: panel),
    );
    return Stack(
      children: [
        if (c.isDrafting)
          side(panel(_drafting(c)), left: false)
        else ...[
          side(panel(_selectionLeft(c)), left: true, narrow: true),
          if (hasSelection) side(panel(_selectionRight(c)), left: false, narrow: true),
        ],
      ],
    );
  }

  Widget _drafting(EditorController c) {
    final n = c.draftPointCount;
    const dense = ButtonStyle(visualDensity: VisualDensity.compact);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(6, 6, 6, 6),
          child: Text('New slider'),
        ),
        FilledButton(style: dense, onPressed: n >= 2 ? c.finishSlider : null, child: const Text('Create')),
        const SizedBox(height: 4),
        OutlinedButton(style: dense, onPressed: c.cancelSlider, child: const Text('Cancel')),
      ],
    );
  }

  /// Left strip: what is selected, and the basic actions on it. Paste is
  /// there whenever something was copied, selection or not (cutting leaves
  /// nothing selected).
  /// "n selected", or the slider edge whose hitsounds the toolbox edits.
  static Widget _selectionLabel(EditorController c) {
    final s = c.editedSlider, edge = c.selectedEdge;
    if (s == null || edge == null) {
      return Text('${c.selection.length} selected', maxLines: 1, style: const TextStyle(fontSize: 12));
    }
    return Text(
      'Slider ${EditorController.edgeName(s, edge).toLowerCase()}',
      maxLines: 1,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: TimelinePainter.edgeColour),
    );
  }

  Widget _selectionLeft(EditorController c) {
    final pivotNote = c.pivot == TransformPivot.playfield ? ' · playfield centre' : ' · selection centre';
    final selected = c.selection.isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (selected) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 6, 2, 2),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: _selectionLabel(c),
            ),
          ),
          _ActionButton(
            tooltip: 'Delete (Del)',
            label: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: c.deleteSelection,
          ),
          _ActionButton(
            tooltip: 'Copy (Ctrl+C)',
            label: 'Copy',
            icon: const Icon(Icons.content_copy),
            onPressed: onCopy,
          ),
          _ActionButton(tooltip: 'Cut (Ctrl+X)', label: 'Cut', icon: const Icon(Icons.content_cut), onPressed: onCut),
        ],
        if (c.clipboardCount > 0)
          _ActionButton(
            tooltip: 'Paste ${c.clipboardCount} at current time (Ctrl+V)',
            label: 'Paste',
            icon: const Icon(Icons.content_paste),
            onPressed: c.paste,
          ),
        // One Flip button; its menu (beside it) offers the two directions.
        if (selected)
          MenuAnchor(
            alignmentOffset: const Offset(72, -56),
            menuChildren: [
              MenuItemButton(
                leadingIcon: const Icon(Icons.flip),
                onPressed: () => c.flipSelection(horizontal: true),
                child: Tooltip(message: 'Ctrl+H$pivotNote', child: const Text('Flip horizontally')),
              ),
              MenuItemButton(
                leadingIcon: const RotatedBox(quarterTurns: 1, child: Icon(Icons.flip)),
                onPressed: () => c.flipSelection(horizontal: false),
                child: Tooltip(message: 'Ctrl+J$pivotNote', child: const Text('Flip vertically')),
              ),
            ],
            builder: (context, menu, _) => _ActionButton(
              tooltip: 'Flip…$pivotNote',
              label: 'Flip',
              icon: const Icon(Icons.flip),
              onPressed: () => menu.isOpen ? menu.close() : menu.open(),
            ),
          ),
      ],
    );
  }

  /// Right strip: rotate, nudge (time / position), rotate / scale, reverse,
  /// and slider → stream when a slider is selected.
  Widget _selectionRight(EditorController c) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 90° turns are in the Rotate panel (and Ctrl+< / Ctrl+>).
        _ActionButton(
          tooltip: 'Rotate… (Ctrl+Shift+R)',
          label: 'Rotate',
          icon: const Icon(Icons.rotate_right),
          onPressed: onRotate,
        ),
        _ActionButton(
          tooltip: 'Scale… (Ctrl+Shift+S)',
          label: 'Scale',
          icon: const Icon(Icons.open_in_full),
          onPressed: onScale,
        ),
        _ActionButton(
          tooltip: 'Nudge in time / position…',
          label: 'Nudge',
          icon: const Icon(Icons.open_with),
          onPressed: onNudge,
        ),
        _ActionButton(
          tooltip: 'Reverse in time (Ctrl+G)',
          label: 'Reverse',
          icon: const Icon(Icons.swap_horiz),
          onPressed: c.reverseSelection,
        ),
        if (c.canConvertToStream)
          _ActionButton(
            tooltip: 'Convert sliders to a stream at the beat snap (Ctrl+Shift+F)',
            label: 'Convert',
            icon: const Icon(Icons.more_horiz),
            onPressed: c.convertSelectionToStream,
          ),
        if (c.canMergeSelection)
          _ActionButton(
            tooltip: 'Merge into one slider (Ctrl+Shift+M)',
            label: 'Merge',
            icon: const Icon(Icons.timeline),
            onPressed: c.mergeSelection,
          ),
      ],
    );
  }
}

/// Icon with a small caption underneath, for the strips beside the playfield.
class _ActionButton extends StatelessWidget {
  final String tooltip;
  final String label;
  final Widget icon;
  final VoidCallback onPressed;
  const _ActionButton({required this.tooltip, required this.label, required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: 34,
        child: SizedBox(
          width: double.infinity,
          height: 56,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconTheme.merge(data: const IconThemeData(size: 26), child: icon),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(label, maxLines: 1, style: const TextStyle(fontSize: 10.5)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Asks for one line of text; pops it trimmed (never empty) or null.
class _TextPromptDialog extends StatefulWidget {
  final String title;
  final String label;
  final String initial;
  final String action;
  const _TextPromptDialog({required this.title, required this.label, required this.initial, required this.action});

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _name.text.trim();
    if (v.isNotEmpty) Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _name,
      autofocus: true,
      decoration: InputDecoration(labelText: widget.label),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      TextButton(onPressed: _name.text.trim().isEmpty ? null : _submit, child: Text(widget.action)),
    ],
  );
}

/// What the device latency measurement found and adds to the offset.
String _latencyNote(EditorController c) {
  final measured = AudioSession.instance.deviceLatency.value;
  if (measured == null) return 'Not measured on this device';
  final add = AudioSession.instance.latencyCorrection.round();
  return 'Output latency ${measured.round()} ms '
      '(reference ${AudioSession.referenceLatencyMs.round()} ms): ${add >= 0 ? '+' : ''}$add ms';
}

class _AudioSettingsSheet extends StatelessWidget {
  final EditorController controller;
  final VoidCallback onSetAudio;
  const _AudioSettingsSheet({required this.controller, required this.onSetAudio});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final a = c.audioSettings;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Audio', style: Theme.of(context).textTheme.titleMedium),
                if (!c.hasAudio)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      c.audioError ??
                          (c.canChangeSetFiles
                              ? 'This map has no audio yet.'
                              : 'This map has no loaded audio (open it from the library with its audio file).'),
                    ),
                  ),
                if (c.canChangeSetFiles)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        onSetAudio();
                      },
                      icon: const Icon(Icons.audio_file_outlined),
                      label: Text(c.hasAudio ? 'Change audio file…' : 'Choose audio file…'),
                    ),
                  ),
                const SizedBox(height: 8),
                Text('Offset: ${a.offsetMs.round()} ms (positive = audio is heard late)'),
                Slider(
                  value: a.offsetMs.clamp(-200, 200),
                  min: -200,
                  max: 200,
                  divisions: 80,
                  label: '${a.offsetMs.round()} ms',
                  onChanged: (v) => c.updateAudioSettings(offsetMs: v),
                ),
                Text('Music volume: ${(a.musicVolume * 100).round()}%'),
                Slider(
                  value: a.musicVolume,
                  onChanged: (v) => c.updateAudioSettings(musicVolume: v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Hitsounds'),
                  value: a.hitsoundsEnabled,
                  onChanged: (v) => c.updateAudioSettings(hitsoundsEnabled: v),
                ),
                Slider(
                  value: a.hitsoundVolume,
                  onChanged: a.hitsoundsEnabled ? (v) => c.updateAudioSettings(hitsoundVolume: v) : null,
                ),
                ExpansionTile(
                  title: const Text('Advanced'),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  shape: const Border(),
                  collapsedShape: const Border(),
                  expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Auto-correct device latency'),
                      subtitle: Text(_latencyNote(c)),
                      value: a.autoLatency,
                      onChanged: (v) => c.updateAudioSettings(autoLatency: v),
                    ),
                    Text(
                      'Map timing: ${c.mapAudioOffsetMs.round()} ms (fixed). Notes are timed this much ahead '
                      'of the song, as in ranked maps (osu!stable latency'
                      '${c.beatmap.formatVersion < 5 ? ', +${EditorController.earlyVersionTimingOffsetMs.round()} ms '
                          'for v${c.beatmap.formatVersion} files' : ''}).',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Rotate / scale panel shown over the playfield (top right) while the
/// controller previews the transform; pops true to apply.
/// Moves the selection one beat snap earlier / later (Ctrl+← / Ctrl+→), or
/// a few osu!pixels up / down / left / right.
class _NudgePanel extends StatefulWidget {
  final EditorController controller;
  const _NudgePanel({required this.controller});

  @override
  State<_NudgePanel> createState() => _NudgePanelState();
}

class _NudgePanelState extends State<_NudgePanel> {
  static const _steps = [1, 2, 4];
  static int _step = 1; // kept between openings

  EditorController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const size = 40.0;
    const tight = BoxConstraints.tightFor(width: size, height: size);
    return Material(
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(12),
      elevation: 4,
      child: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final on = c.selection.isNotEmpty;
          final s = _step.toDouble();
          Widget button(String tip, IconData icon, VoidCallback action) => IconButton.filledTonal(
            tooltip: tip,
            padding: EdgeInsets.zero,
            constraints: tight,
            iconSize: 22,
            icon: Icon(icon),
            onPressed: on ? action : null,
          );
          Widget arrow(String tip, IconData icon, double dx, double dy) =>
              button('$tip $_step px', icon, () => c.nudgeSelection(dx * s, dy * s));
          const gap = SizedBox.square(dimension: size);
          return Padding(
            padding: const EdgeInsets.all(6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Time: one beat snap.
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    button(
                      'Earlier by one snap (Ctrl+←)',
                      Icons.keyboard_double_arrow_left,
                      () => c.moveSelectionInTime(forward: false),
                    ),
                    const SizedBox(height: 6),
                    button(
                      'Later by one snap (Ctrl+→)',
                      Icons.keyboard_double_arrow_right,
                      () => c.moveSelectionInTime(forward: true),
                    ),
                  ],
                ),
                Container(
                  width: 1,
                  height: 3 * size - 16,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  color: scheme.outlineVariant,
                ),
                // Position: a D-pad; the middle cycles the step.
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        gap,
                        arrow('Up', Icons.keyboard_arrow_up, 0, -1),
                        IconButton(
                          tooltip: 'Close',
                          padding: EdgeInsets.zero,
                          constraints: tight,
                          iconSize: 18,
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        arrow('Left', Icons.keyboard_arrow_left, -1, 0),
                        SizedBox.square(
                          dimension: size,
                          child: Tooltip(
                            message: 'Step: $_step px (tap to change)',
                            child: InkResponse(
                              radius: size / 2,
                              onTap: () => setState(() => _step = _steps[(_steps.indexOf(_step) + 1) % _steps.length]),
                              child: Center(
                                child: Text(
                                  '${_step}px',
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary),
                                ),
                              ),
                            ),
                          ),
                        ),
                        arrow('Right', Icons.keyboard_arrow_right, 1, 0),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [gap, arrow('Down', Icons.keyboard_arrow_down, 0, 1), gap],
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// "Polygon circles" settings with a live preview (lazer's popover:
/// distance, offset angle, repeats, vertices).
class _PolygonPanel extends StatefulWidget {
  final EditorController controller;

  /// Whether the preview [EditorController.updatePolygon] already shows
  /// (the defaults) fits.
  final bool fitsAtStart;
  const _PolygonPanel({required this.controller, required this.fitsAtStart});

  @override
  State<_PolygonPanel> createState() => _PolygonPanelState();
}

class _PolygonPanelState extends State<_PolygonPanel> {
  int _vertices = PolygonOps.minVertices;
  int _repeats = 1;
  double _distance = 1;
  double _angle = 0;
  late bool _fits = widget.fitsAtStart;

  EditorController get c => widget.controller;

  void _update({int? vertices, int? repeats, double? distance, double? angle}) {
    setState(() {
      _vertices = vertices ?? _vertices;
      _repeats = repeats ?? _repeats;
      _distance = distance ?? _distance;
      _angle = angle ?? _angle;
      _fits = c.updatePolygon(vertices: _vertices, repeats: _repeats, distance: _distance, angleDegrees: _angle);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const tabular = monoNumbers;
    Widget row(String label, String value, Widget slider) => SizedBox(
      height: 36,
      child: Row(
        children: [
          SizedBox(width: 60, child: Text(label, style: const TextStyle(fontSize: 13))),
          Expanded(child: slider),
          SizedBox(width: 36, child: Text(value, textAlign: TextAlign.end, style: tabular.copyWith(fontSize: 13))),
        ],
      ),
    );
    return Material(
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(12),
      elevation: 4,
      child: SizedBox(
        // Narrow: the polygon grows around the playfield centre next to it.
        width: 248,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Polygon · ${_vertices * _repeats} circles', style: Theme.of(context).textTheme.titleSmall),
              row(
                'Vertices',
                '$_vertices',
                Slider(
                  value: _vertices.toDouble(),
                  min: PolygonOps.minVertices.toDouble(),
                  max: PolygonOps.maxVertices.toDouble(),
                  divisions: PolygonOps.maxVertices - PolygonOps.minVertices,
                  onChanged: (v) => _update(vertices: v.round()),
                ),
              ),
              row(
                'Distance',
                '${_distance.toStringAsFixed(1)}×',
                Slider(value: _distance, min: 0.1, max: 6, divisions: 59, onChanged: (v) => _update(distance: v)),
              ),
              row(
                'Angle',
                '${_angle.round()}°',
                Slider(value: _angle, max: 180, divisions: 180, onChanged: (v) => _update(angle: v)),
              ),
              row(
                'Repeats',
                '$_repeats',
                Slider(
                  value: _repeats.toDouble(),
                  min: 1,
                  max: PolygonOps.maxRepeats.toDouble(),
                  divisions: PolygonOps.maxRepeats - 1,
                  onChanged: (v) => _update(repeats: v.round()),
                ),
              ),
              if (!_fits)
                Text("Doesn't fit the playfield", style: TextStyle(color: scheme.error)),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                  FilledButton(
                    onPressed: _fits ? () => Navigator.pop(context, true) : null,
                    child: const Text('Create'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small number box: shows [value] rounded (updated from outside while
/// not being edited); Enter or focus loss sends the typed number, clamped
/// to [min]..[max], to [onSubmit] (invalid text reverts).
class _NumberField extends StatefulWidget {
  final double value;
  final String suffix;
  final double min;
  final double max;
  final TextStyle? style;
  final ValueChanged<double> onSubmit;
  const _NumberField({
    required this.value,
    required this.suffix,
    required this.min,
    required this.max,
    required this.onSubmit,
    this.style,
  });

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _text = TextEditingController(text: _format(widget.value));
  final FocusNode _focus = FocusNode();

  static String _format(double v) => '${v.round()}';

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _submit();
    });
  }

  @override
  void didUpdateWidget(_NumberField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && old.value != widget.value) _text.text = _format(widget.value);
  }

  @override
  void dispose() {
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final v = double.tryParse(_text.text.trim().replaceAll(widget.suffix, ''));
    if (v == null || !v.isFinite) {
      _text.text = _format(widget.value);
      return;
    }
    final clamped = v.clamp(widget.min, widget.max).toDouble();
    _text.text = _format(clamped);
    if (clamped != widget.value) widget.onSubmit(clamped);
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _text,
        focusNode: _focus,
        textAlign: TextAlign.end,
        style: widget.style,
        keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
        decoration: InputDecoration(
          isDense: true,
          suffixText: widget.suffix,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        ),
        onSubmitted: (_) => _submit(),
      );
}

enum _TransformKind { rotate, scale }

/// The Rotate or Scale panel ([kind]): a slider and a number box, the
/// pivot, Apply / Cancel. Rotate also has 90° turn buttons (adding to the
/// angle, like the old Rotate L / R but previewed until Apply). Scale has a
/// lock: unlocked, width and height get a slider each.
class _TransformPanel extends StatefulWidget {
  final EditorController controller;
  final _TransformKind kind;
  const _TransformPanel({required this.controller, required this.kind});

  @override
  State<_TransformPanel> createState() => _TransformPanelState();
}

class _TransformPanelState extends State<_TransformPanel> {
  double _degrees = 0;
  double _scale = 1;

  /// Scale down while unlocked; [_scale] is then across.
  double _scaleY = 1;
  bool _fits = true;

  /// Width and height locked together: the shared setting (also the
  /// selection box's lock button).
  bool get _linked => c.scaleLocksAspect;

  EditorController get c => widget.controller;

  /// Adds [d] degrees (clockwise on screen) to the angle, kept in
  /// −180…180.
  ///
  /// Applied right away (no Apply needed), as its own undo step, together
  /// with any angle set on the slider; the panel stays open at 0°. A turn
  /// that would leave the playfield is refused (the preview stays).
  void _turn(double d) {
    var a = _degrees + d;
    while (a > 180) {
      a -= 360;
    }
    while (a < -180) {
      a += 360;
    }
    if (!c.updateTransform(degrees: a, scale: _scale)) {
      c.updateTransform(degrees: _degrees, scale: _scale);
      setState(() => _fits = false);
      return;
    }
    c.endTransform(apply: true);
    c.beginTransform(label: 'Rotate');
    setState(() {
      _degrees = 0;
      _fits = true;
    });
  }

  void _update({double? degrees, double? scale, double? scaleY}) {
    setState(() {
      _degrees = degrees ?? _degrees;
      _scale = scale ?? _scale;
      _scaleY = _linked ? _scale : scaleY ?? _scaleY;
      _fits = c.updateTransform(
        degrees: _degrees,
        scale: _scale,
        scaleY: _scaleY,
        keepSliderShape: widget.kind == _TransformKind.scale && c.scaleKeepsSliderShape,
      );
    });
  }

  /// Locks width and height together (both take the width's scale) or
  /// unlocks them.
  void _setLinked(bool v) {
    c.scaleLocksAspect = v;
    _update();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rotate = widget.kind == _TransformKind.rotate;
    const tabular = monoNumbers;
    // The value next to each slider can be typed too (stable's dialog has
    // number boxes): Enter / focus loss applies it, clamped to the range.
    Widget row(String label, Widget slider, Widget field) => Row(
      children: [
        SizedBox(width: 52, child: Text(label)),
        Expanded(child: slider),
        SizedBox(width: 64, child: field),
      ],
    );
    return Material(
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(12),
      elevation: 4,
      child: SizedBox(
        width: 300,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text(rotate ? 'Rotate' : 'Scale', style: Theme.of(context).textTheme.titleSmall)),
                  if (!rotate)
                    IconButton(
                      tooltip: _linked ? 'Unlock width / height' : 'Lock width / height',
                      isSelected: _linked,
                      // No taller than the title (the panel fits a phone).
                      style: IconButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(32, 22),
                        fixedSize: const Size(32, 22),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => _setLinked(!_linked),
                      icon: Icon(_linked ? Icons.link : Icons.link_off, size: 20),
                    ),
                ],
              ),
              if (rotate) ...[
              row(
                'Angle',
                Slider(
                  value: _degrees,
                  min: -180,
                  max: 180,
                  divisions: 360,
                  label: '${_degrees.round()}°',
                  // Sticks to 0 / ±90 / 180° when near (typed values don't).
                  onChanged: (v) {
                    final snapped = EditorController.snapRightAngle(v);
                    // A tick when it locks on (not on every move while locked).
                    if (snapped != v && snapped != _degrees) HapticFeedback.selectionClick();
                    _update(degrees: snapped);
                  },
                ),
                _NumberField(
                  value: _degrees,
                  suffix: '°',
                  min: -180,
                  max: 180,
                  style: tabular,
                  onSubmit: (v) => _update(degrees: v),
                ),
              ),
              Row(
                children: [
                  for (final (d, icon, label) in const [
                    (-90.0, Icons.rotate_left, '90°'),
                    (90.0, Icons.rotate_right, '90°'),
                    (180.0, null, '180°'),
                  ]) ...[
                    if (d != -90) const SizedBox(width: 6),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _turn(d),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          visualDensity: VisualDensity.compact,
                        ),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 4)],
                              Text(label, maxLines: 1),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              ] else
              for (final (label, value, set) in [
                if (_linked)
                  ('Scale', _scale, (double v) => _update(scale: v))
                else ...[
                  ('Width', _scale, (double v) => _update(scale: v)),
                  ('Height', _scaleY, (double v) => _update(scaleY: v)),
                ],
              ])
                row(
                  label,
                  Slider(
                    value: value,
                    min: 0.5,
                    max: 2,
                    divisions: 150,
                    label: '${(value * 100).round()}%',
                    onChanged: set,
                  ),
                  _NumberField(
                    value: value * 100,
                    suffix: '%',
                    min: 50,
                    max: 200,
                    style: tabular,
                    onSubmit: (v) => set(v / 100),
                  ),
                ),
              if (!rotate)
                // Sliders only move with their heads; nodes and length stay.
                SwitchListTile(
                  title: const Text('Keep slider nodes'),
                  value: c.scaleKeepsSliderShape,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  onChanged: (v) {
                    c.scaleKeepsSliderShape = v;
                    _update();
                  },
                ),
              const Text('Around (also for flips)'),
              const SizedBox(height: 4),
              SegmentedButton<TransformPivot>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(value: TransformPivot.selection, label: Text('Selection')),
                  ButtonSegment(value: TransformPivot.playfield, label: Text('Playfield')),
                ],
                selected: {c.pivot},
                onSelectionChanged: (s) {
                  c.pivot = s.first;
                  _update();
                },
              ),
              if (!_fits)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text("Doesn't fit the playfield", style: TextStyle(color: scheme.error)),
                ),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                overflowAlignment: OverflowBarAlignment.end,
                children: [
                  IconButton(
                    tooltip: 'Reset',
                    onPressed: () => _update(degrees: 0, scale: 1, scaleY: 1),
                    icon: const Icon(Icons.restart_alt),
                  ),
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                  FilledButton(
                    onPressed: _fits ? () => Navigator.pop(context, true) : null,
                    child: const Text('Apply'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A short in-app note naming the step an undo / redo just reverted or
/// re-applied ("Undo: Move objects · 00:12:345"). Fades out on its own.
class HistoryToast extends StatefulWidget {
  final ValueListenable<HistoryStep?> step;
  const HistoryToast({super.key, required this.step});

  static const shownFor = Duration(milliseconds: 1600);

  @override
  State<HistoryToast> createState() => _HistoryToastState();
}

class _HistoryToastState extends State<HistoryToast> {
  HistoryStep? _shown;
  bool _visible = false;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    widget.step.addListener(_onStep);
  }

  @override
  void didUpdateWidget(HistoryToast old) {
    super.didUpdateWidget(old);
    if (old.step != widget.step) {
      old.step.removeListener(_onStep);
      widget.step.addListener(_onStep);
    }
  }

  @override
  void dispose() {
    widget.step.removeListener(_onStep);
    _hide?.cancel();
    super.dispose();
  }

  void _onStep() {
    final s = widget.step.value;
    if (s == null) return;
    _hide?.cancel();
    _hide = Timer(HistoryToast.shownFor, () {
      if (mounted) setState(() => _visible = false);
    });
    setState(() {
      _shown = s;
      _visible = true;
    });
  }

  static String text(HistoryStep s) {
    final t = s.focus.time;
    final where = switch (s.focus.area) {
      EditArea.objects || EditArea.timing || EditArea.breaks || EditArea.bookmarks when t != null =>
        ' · ${formatEditorTime(t)}',
      _ => '',
    };
    return '${s.undo ? 'Undo' : 'Redo'}: ${s.focus.label}$where';
  }

  @override
  Widget build(BuildContext context) {
    final s = _shown;
    if (s == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: Duration(milliseconds: _visible ? 120 : 300),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.inverseSurface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 8, offset: Offset(0, 2))],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(s.undo ? Icons.undo : Icons.redo, size: 18, color: scheme.onInverseSurface),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  text(s),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onInverseSurface, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Offset in ms for "Move all notes in time" (negative = earlier).
class _MoveNotesDialog extends StatefulWidget {
  final bool all;
  const _MoveNotesDialog({required this.all});

  @override
  State<_MoveNotesDialog> createState() => _MoveNotesDialogState();
}

class _MoveNotesDialogState extends State<_MoveNotesDialog> {
  final _text = TextEditingController();

  int? get _value {
    final v = int.tryParse(_text.text.trim().replaceFirst('+', ''));
    return v == null || v == 0 ? null : v;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _value;
    if (v != null) Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.all ? 'Move all notes in time' : 'Move selection in time'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _text,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^[-+]?\d{0,7}'))],
            decoration: const InputDecoration(labelText: 'Offset', suffixText: 'ms', hintText: 'e.g. -20 or 15'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          Text(
            'Negative moves earlier. Timing points stay; nothing moves before 0.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _value == null ? null : _submit, child: const Text('Move')),
      ],
    );
  }
}

/// The map's star rating (updated after edits) at the top left of Compose's
/// inner area; tap for the aim / speed / reading parts and the graph's
/// colours. Shown only while the side strips are hidden: it fades in
/// [showDelay] after they go and disappears at once when they appear (an
/// object selected), so the two never overlap.
class _StarRatingChip extends StatefulWidget {
  final EditorController controller;
  final Size area;
  const _StarRatingChip({required this.controller, required this.area});

  static const showDelay = Duration(seconds: 1);
  static const fadeIn = Duration(milliseconds: 300);

  @override
  State<_StarRatingChip> createState() => _StarRatingChipState();
}

class _StarRatingChipState extends State<_StarRatingChip> {
  bool _shown = false;
  Timer? _timer;

  EditorController get c => widget.controller;

  bool get _wanted => !_ContextOverlay.showsStrips(c, widget.area);

  @override
  void initState() {
    super.initState();
    c.addListener(_update);
    _update();
  }

  @override
  void didUpdateWidget(_StarRatingChip old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_update);
      widget.controller.addListener(_update);
    }
    _update();
  }

  @override
  void dispose() {
    c.removeListener(_update);
    _timer?.cancel();
    super.dispose();
  }

  void _update() {
    if (!_wanted) {
      _timer?.cancel();
      _timer = null;
      if (_shown && mounted) setState(() => _shown = false);
      return;
    }
    if (_shown || _timer != null) return;
    _timer = Timer(_StarRatingChip.showDelay, () {
      _timer = null;
      if (mounted && _wanted) setState(() => _shown = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      ignoring: !_shown,
      child: AnimatedOpacity(
        opacity: _shown ? 1 : 0,
        // Fades in; hiding is immediate (the strips appear at once).
        duration: _shown ? _StarRatingChip.fadeIn : Duration.zero,
        child: ValueListenableBuilder<StarAnalysis?>(
          valueListenable: c.difficulty,
          builder: (context, a, _) {
            if (a == null) return const SizedBox.shrink();
            String f(double v) => v.toStringAsFixed(2);
            return Tooltip(
              triggerMode: TooltipTriggerMode.tap,
              showDuration: const Duration(seconds: 4),
              message: 'Aim ${f(a.aim)} · Speed ${f(a.speed)} · Reading ${f(a.reading)}',
              child: Material(
                color: scheme.surfaceContainerHigh.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    '★ ${f(a.stars)}',
                    key: const ValueKey('star rating'),
                    style: const TextStyle(fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// What "Copy hitsounds to…" was asked to do.
class _HitsoundCopyChoice {
  final List<String> paths;
  final double leniency;
  final bool samplePoints;
  final bool clearUnmatched;
  const _HitsoundCopyChoice(this.paths, this.leniency, this.samplePoints, this.clearUnmatched);
}

/// The target difficulties and options for copying this difficulty's
/// hitsounds (Mapping Tools' "Hitsound copier").
class _CopyHitsoundsDialog extends StatefulWidget {
  final List<LibraryDifficulty> difficulties;
  const _CopyHitsoundsDialog({required this.difficulties});

  @override
  State<_CopyHitsoundsDialog> createState() => _CopyHitsoundsDialogState();
}

class _CopyHitsoundsDialogState extends State<_CopyHitsoundsDialog> {
  late final Set<String> _chosen = {for (final d in widget.difficulties) d.path};
  final _leniency = TextEditingController(text: '5');
  bool _samplePoints = true;
  bool _clearUnmatched = false;

  double? get _leniencyMs {
    final v = double.tryParse(_leniency.text.trim());
    return v == null || v < 0 || v > 100 ? null : v;
  }

  @override
  void dispose() {
    _leniency.dispose();
    super.dispose();
  }

  static String _name(LibraryDifficulty d) => d.summary.version.isEmpty ? d.fileName : d.summary.version;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return AlertDialog(
      title: const Text('Copy hitsounds'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('From this difficulty (as it is now) to:', style: small),
              for (final d in widget.difficulties)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(_name(d), maxLines: 1, overflow: TextOverflow.ellipsis),
                  value: _chosen.contains(d.path),
                  onChanged: (v) => setState(() => v == true ? _chosen.add(d.path) : _chosen.remove(d.path)),
                ),
              const Divider(),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Sample sets and volumes'),
                subtitle: const Text('Timing points take this difficulty\'s sample set, index and volume'),
                value: _samplePoints,
                onChanged: (v) => setState(() => _samplePoints = v),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Clear unmatched'),
                subtitle: const Text('Remove hitsounds where this difficulty has no object'),
                value: _clearUnmatched,
                onChanged: (v) => setState(() => _clearUnmatched = v),
              ),
              TextField(
                controller: _leniency,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Leniency',
                  suffixText: 'ms',
                  helperText: 'Objects this close in time count as the same moment',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              Text('The other files are changed on disk; Undo is offered right after.', style: small),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: _chosen.isEmpty || _leniencyMs == null
              ? null
              : () => Navigator.of(context).pop(_HitsoundCopyChoice(
                    [for (final d in widget.difficulties) if (_chosen.contains(d.path)) d.path],
                    _leniencyMs!,
                    _samplePoints,
                    _clearUnmatched,
                  )),
          child: const Text('Copy'),
        ),
      ],
    );
  }
}
