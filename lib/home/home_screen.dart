import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/core.dart';
import '../editor/editor_controller.dart';
import '../editor/editor_screen.dart';
import '../editor/widgets/skin_picker.dart';
import '../platform/app_settings.dart';
import '../platform/audio_engine.dart';
import '../platform/background_image.dart';
import '../platform/incoming_files.dart';
import '../platform/beatmap_file_service.dart';
import '../platform/beatmap_library.dart';
import '../platform/map_folder.dart';
import '../platform/preview_audio.dart';
import '../platform/recovery_store.dart';
import '../platform/skin_library.dart';
import '../platform/storyboard_loader.dart';
import '../platform/web_links.dart';
import 'song_select.dart';

/// Start screen: the beatmap library plus import / sample / new map.
class HomeScreen extends StatefulWidget {
  final BeatmapFileService files;

  /// Injected in tests; otherwise opened from the app documents folder.
  final BeatmapLibrary? library;

  /// Loads music + hitsounds for library maps (injected in tests).
  final EditorAudioLoader audioLoader;
  final BackgroundLoader backgroundLoader;
  final StoryboardLoader storyboardLoader;

  /// Plays the open set's song (null = SoLoud).
  final PreviewPlayer? previewPlayer;

  const HomeScreen({
    super.key,
    this.files = const BeatmapFileService(),
    this.library,
    this.audioLoader = loadEditorAudio,
    this.backgroundLoader = loadBackgroundImage,
    this.storyboardLoader = loadStoryboard,
    this.previewPlayer,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  BeatmapLibrary? _library;
  List<LibrarySet>? _sets;
  List<File> _pending = const [];
  String? _error;
  bool _busy = false;

  /// The set whose background / info is shown, and whether its
  /// difficulties are open (only then its song previews).
  String? _selectedPath;
  bool _expanded = false;

  /// The selected difficulty (its stats show; tapping it again opens it).
  String? _selectedDiffPath;

  /// The difficulty being opened (dims the screen until the editor shows).
  OpeningMap? _opening;
  final _backgrounds = BackgroundFiles();
  final _listKeys = <String, GlobalKey>{};
  final _carousel = ScrollController();
  static const _carouselTop = 10.0;
  late final PreviewPlayer _preview = widget.previewPlayer ?? SoloudPreviewPlayer();

  BeatmapFileService get files => widget.files;

  /// Rescans for files other apps handed over while we were away.
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () {
        _refresh();
        _resumePreview();
      },
      onHide: () => _preview.stop(),
    );
    _ready = _init();
    // Files opened with / shared to the app: import them right away (the
    // user picked this app for them).
    IncomingFiles.listen(_receiveIncoming);
  }

  /// Completes once the library is open.
  late final Future<void> _ready;

  @override
  void dispose() {
    IncomingFiles.listen(null);
    _lifecycle.dispose();
    _preview.stop();
    _carousel.dispose();
    super.dispose();
  }

  Future<void> _receiveIncoming() async {
    await _ready; // on a cold start the files can be reported first
    if (!mounted) return;
    await _refresh();
    if (_pending.isNotEmpty) await _importPending();
  }

  Future<void> _init() async {
    try {
      final lib = _library = widget.library ?? await BeatmapLibrary.open();
      // The editor's skin (loads in the background).
      SkinManager.instance.attach(SkinLibrary.beside(lib)).ignore();
      // The first preview shouldn't wait for the audio engine to start.
      if (_preview is SoloudPreviewPlayer) AudioEngine.instance.ensureInitialized().ignore();
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = 'Library unavailable: $e');
    }
  }

  /// Bumped per refresh so a slow, older scan can't overwrite a newer one.
  int _refreshGeneration = 0;

  Future<void> _refresh() async {
    final lib = _library;
    if (lib == null) return;
    final gen = ++_refreshGeneration;
    final sets = await lib.listSets();
    final pending = await lib.pendingImports();
    if (!mounted || gen != _refreshGeneration) return;
    _backgrounds.clear();
    setState(() {
      _sets = sets;
      _pending = pending;
      if (!sets.any((s) => s.path == _selectedPath)) {
        if (_expanded) _preview.stop();
        _selectedPath = sets.isEmpty ? null : sets.first.path;
        _expanded = false;
      }
    });
    if (sets.any((s) => s.difficulties.any((d) => d.starRatingPending))) _rateDifficulties();
  }

  /// The refresh button: the same dim + spinner card as opening a map, held
  /// a moment so a quick scan is still noticeable.
  Future<void> _refreshWithFeedback() async {
    if (_busy || _opening != null) return;
    setState(() => _opening = const OpeningMap(title: 'Scanning the beatmap library', message: 'Refreshing…'));
    try {
      await Future.wait([_refresh(), Future<void>.delayed(const Duration(milliseconds: 700))]);
    } catch (e) {
      if (mounted) _snack('$e');
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  bool _rating = false;

  /// Rates new / changed difficulties in the background, then shows the
  /// ratings (the list appears right away without them).
  Future<void> _rateDifficulties() async {
    final lib = _library;
    if (lib == null || _rating) return;
    _rating = true;
    try {
      final rated = await lib.computeStarRatings();
      if (rated > 0 && mounted) await _refresh();
    } catch (_) {
      // Ratings are cosmetic; the list works without them.
    } finally {
      _rating = false;
    }
  }

  /// Runs [job] with a progress indicator and reports failures.
  Future<void> _run(Future<void> Function() job) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Actions

  Future<void> _importOsz() => _run(() async {
        final lib = _library;
        if (lib == null) return;
        final picked = await files.pickOszFile();
        if (picked == null) return;
        final set = await lib.importOsz(picked.bytes, fallbackName: picked.name);
        await _refresh();
        _revealSet(set.path);
        _snack('Imported ${set.folderName} (${set.difficulties.length} difficulties)');
        await _settleSliderFormat(set.path, set.folderName);
      });

  /// Picks a single `.osu` and asks whether to import it into the library
  /// as a new set (with its audio / background when they are beside it,
  /// like an `.osz`) or just open it.
  Future<void> _openOsuFile() async {
    final lib = _library;
    final PickedOsu? picked;
    try {
      picked = await files.pickOsu();
    } catch (e) {
      _snack('$e');
      return;
    }
    if (picked == null || !mounted) return;
    if (lib == null) return _openLoaded(Future.value(picked.loaded));
    final name = picked.loaded.document.fileName;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import beatmap?'),
        content: Text('Import "$name" into the library as a new beatmap set? '
            'Its audio and background are copied too when they are in the same folder.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'open'), child: const Text('Open without importing')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'import'), child: const Text('Import')),
        ],
      ),
    );
    if (choice == 'open') return _openLoaded(Future.value(picked.loaded));
    if (choice != 'import') return;
    await _run(() async {
      final osz = await _packOsu(picked!);
      final dot = name.lastIndexOf('.');
      final set = await lib.importOsz(osz, fallbackName: dot > 0 ? name.substring(0, dot) : name);
      await _refresh();
      _revealSet(set.path);
      _snack('Imported ${set.folderName}');
      await _settleSliderFormat(set.path, set.folderName);
    });
  }

  /// [picked] as an `.osz`: the `.osu` plus the audio and background it
  /// names, when they are in its folder.
  static Future<Uint8List> _packOsu(PickedOsu picked) async {
    final entries = [PackageEntry(picked.loaded.document.fileName, picked.bytes)];
    final folder = picked.folder;
    if (folder != null) {
      final summary = BeatmapSummary.scan(picked.loaded.text);
      for (final ref in {summary.audioFilename, summary.backgroundFile}) {
        if (ref.isEmpty) continue;
        final f = BeatmapLibrary.resolveFile(folder, ref);
        if (f != null && await f.exists()) entries.add(PackageEntry(ref.replaceAll(r'\', '/'), await f.readAsBytes()));
      }
    }
    return OszCodec.encode(entries);
  }

  /// Selects and opens the set at [setPath] in the carousel.
  void _revealSet(String setPath) {
    if (!mounted) return;
    final set = _sets?.where((s) => s.path == setPath).firstOrNull;
    if (set == null) return;
    if (!(_expanded && _selectedPath == setPath)) _toggleSet(set);
  }

  /// Imports every pending file; one bad file doesn't stop the others (it
  /// stays listed so it can be discarded). `.osk` skins (and archives that
  /// arrived without a name but hold a skin) go to the skins; the last one
  /// imported becomes the editor's skin (the user opened it with the app).
  Future<void> _importPending() => _run(() async {
        final lib = _library;
        if (lib == null) return;
        final skins = SkinManager.instance.library ?? SkinLibrary.beside(lib);
        var ok = 0;
        final failed = <String>[];
        final imported = <LibrarySet>[];
        SkinInfo? skin;
        for (final f in _pending) {
          try {
            if (f.path.toLowerCase().endsWith('.osk')) {
              skin = await skins.importAndRemove(f);
              continue;
            }
            try {
              imported.add(await lib.importAndRemove(f));
              ok++;
            } on FormatException catch (e) {
              // Maybe a skin handed over without its file name.
              try {
                skin = await skins.importAndRemove(f);
              } on FormatException {
                failed.add('${f.uri.pathSegments.last}: ${e.message}');
              }
            }
          } catch (e) {
            failed.add('${f.uri.pathSegments.last}: $e');
          }
        }
        if (skin != null) {
          await SkinManager.instance.attach(skins);
          await SkinManager.instance.select(skin);
        }
        await _refresh();
        _snack([
          if (ok > 0) 'Imported $ok ${ok == 1 ? 'set' : 'sets'}',
          if (skin != null) 'Skin "${skin.name}" imported and selected',
          if (failed.isNotEmpty) 'Failed: ${failed.join('; ')}',
        ].join('. '));
        for (final set in imported) {
          await _settleSliderFormat(set.path, set.folderName);
        }
      });

  /// If the set at [setPath] has sliders in osu!lazer's format and the user
  /// hasn't chosen yet, asks whether to convert them to stable's format
  /// (rewrites the set's `.osu` files) or keep them, and records the
  /// choice. Returns whether the set keeps lazer sliders.
  Future<bool> _settleSliderFormat(String setPath, String name) async {
    final lib = _library;
    if (lib == null) return false;
    final known = await lib.keepsLazerSliders(setPath);
    if (known != null) return known;
    final count = await lib.countLazerSliders(setPath);
    if (count == 0) {
      // Nothing to ask; don't scan this set again.
      await lib.setKeepsLazerSliders(setPath, false);
      return false;
    }
    if (!mounted) return false;
    final convert = await _askSliderFormat('"$name"', count);
    if (convert) {
      final n = await lib.convertSetToStable(setPath);
      await lib.setKeepsLazerSliders(setPath, false);
      _snack('Converted $n ${n == 1 ? 'slider' : 'sliders'} to osu!stable format');
      return false;
    }
    await lib.setKeepsLazerSliders(setPath, true);
    return true;
  }

  /// The stable-or-lazer question for [count] lazer-format sliders in
  /// [what]. True = convert to stable.
  Future<bool> _askSliderFormat(String what, int count) async {
    final convert = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('osu!lazer slider format'),
        content: Text(
          '$what has $count ${count == 1 ? 'slider' : 'sliders'} in osu!lazer\'s format '
          '(several curve types in one slider, or B-spline curves), which osu!stable can\'t show correctly.\n\n'
          'Convert to stable: they become Bézier curves of the same shape, and sliders are edited the stable way.\n\n'
          'Keep lazer format: sliders are saved and edited the lazer way — each control point can have its own curve type.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep lazer format')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Convert to stable')),
        ],
      ),
    );
    return convert ?? false;
  }

  Future<void> _discardPending() => _run(() async {
        for (final f in _pending) {
          if (await f.exists()) await f.delete();
        }
        await _refresh();
      });

  Future<void> _openSetFolder(LibrarySet set) async {
    final result = await MapFolder.open(set.path);
    switch (result) {
      case MapFolderResult.opened:
        break;
      case MapFolderResult.openedLibraryRoot:
        _snack('Opened the osuEdit library in Files: the map is in "${set.folderName}"');
      case MapFolderResult.failed:
        _snack('Could not open the folder (no file manager found)');
    }
  }

  Future<void> _exportSet(LibrarySet set) => _run(() async {
        final bytes = await _library!.exportOsz(set.path);
        if (await files.saveOsz(BeatmapLibrary.oszFileName(set), bytes)) _snack('Exported ${set.folderName}');
      });

  /// Long press on a difficulty: a drop-down at the finger with its actions.
  Future<void> _difficultyMenu(LibrarySet set, LibraryDifficulty d, Offset pos) async {
    final url = d.summary.websiteUrl(folderName: set.folderName);
    final size = MediaQuery.sizeOf(context);
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, size.width - pos.dx, size.height - pos.dy),
      items: [
        const PopupMenuItem(value: 'open', child: Text('Open .osu file')),
        if (url != null) const PopupMenuItem(value: 'page', child: Text('Open map page')),
        if (MapFolder.supported) const PopupMenuItem(value: 'folder', child: Text('Open song folder')),
        if (set.difficulties.length > 1) const PopupMenuItem(value: 'delete', child: Text('Delete difficulty')),
      ],
    );
    if (!mounted) return;
    switch (v) {
      case 'open':
        await _openDifficulty(set, d);
      case 'page':
        if (url != null && !await WebLinks.open(url)) _snack('Could not open $url');
      case 'folder':
        await _openSetFolder(set);
      case 'delete':
        await _deleteDifficulty(d);
    }
  }

  Future<void> _deleteDifficulty(LibraryDifficulty d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${d.summary.version.isEmpty ? d.fileName : d.summary.version}"?'),
        content: Text("The file ${d.fileName} is deleted from the set. This can't be undone."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await _library!.deleteDifficulty(d.path);
      await _refresh();
    });
  }

  Future<void> _deleteSet(LibrarySet set) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete set?'),
        content: Text('"${set.folderName}" and all its files will be removed from the library.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await _library!.deleteSet(set);
      await _refresh();
    });
  }

  /// Autosaves of unsaved edits, beside the library.
  RecoveryStore? get _recovery {
    final lib = _library;
    return lib == null ? null : RecoveryStore.besideLibrary(lib.root);
  }

  /// Offers the unsaved edits found for a map: true to open them.
  Future<bool> _askRecover(RecoveredMap rec) async {
    final t = rec.savedAt;
    String two(int n) => n.toString().padLeft(2, '0');
    final when = '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
    final r = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Recover unsaved changes?'),
        content: Text('This map has changes that were not saved (autosaved $when). '
            'Open them, or discard them and open the saved file?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Discard')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Recover')),
        ],
      ),
    );
    return r ?? false;
  }

  Future<void> _openDifficulty(LibrarySet set, LibraryDifficulty d) => _openLoaded(
        files.openLibraryFile(d.path, set.path),
        opening: OpeningMap(
          title: set.title,
          version: d.summary.version,
          color: d.starRating == null ? null : starRatingColor(d.starRating!),
        ),
      );

  /// Shows / hides the loading dim.
  void _setOpening(OpeningMap? o) {
    if (mounted && _opening != o) setState(() => _opening = o);
  }

  /// [opening]: dims the screen with it while loading (difficulties opened
  /// from the carousel).
  Future<void> _openLoaded(Future<LoadedBeatmapFile?> load, {OpeningMap? opening}) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    _setOpening(opening);
    try {
      final loaded = await load;
      if (loaded == null) return;
      final doc = loaded.document;
      final setPath = doc.setPath;
      final warnings = <String>[];
      var beatmap = OsuParser.parse(loaded.text, warnings: warnings);
      if (warnings.isNotEmpty) {
        messenger.showSnackBar(SnackBar(
          content: Text('${warnings.length} line(s) could not be parsed and will be dropped on save.'),
        ));
      }
      // Sliders in osu!lazer's format: library sets ask once per set (sets
      // imported before this was asked), other files every time.
      var lazerSliders = false, convert = false;
      if (setPath != null && _library != null) {
        final path = doc.path;
        final before = await _library!.keepsLazerSliders(setPath);
        lazerSliders = await _settleSliderFormat(setPath, setPath.substring(setPath.lastIndexOf(Platform.pathSeparator) + 1));
        if (before == null && !lazerSliders && path != null) {
          // The files may just have been converted: open what's on disk now.
          final (text, _) = OsuTextCodec.decode(await File(path).readAsBytes());
          beatmap = OsuParser.parse(text);
        }
      } else {
        final count = SliderFormatOps.lazerSliders(beatmap).length;
        if (count > 0 && mounted) {
          convert = await _askSliderFormat('This beatmap', count);
          lazerSliders = !convert;
        }
      }
      // Unsaved edits autosaved before the app was closed or killed.
      var recovered = false;
      final path = doc.path, store = _recovery;
      if (store != null && path != null && doc.isInLibrary) {
        final rec = await store.read(path);
        if (rec != null && mounted) {
          if (await _askRecover(rec)) {
            beatmap = OsuParser.parse(rec.text);
            recovered = true;
          } else {
            await store.clear(path);
          }
        }
      }
      await _openEditor(navigator, beatmap, doc,
          lazerSliders: lazerSliders, convertSliders: convert, recovered: recovered);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open: $e')));
    } finally {
      _setOpening(null);
    }
  }

  /// [lazerSliders]: edit sliders the osu!lazer way; [convertSliders]: first
  /// convert lazer-format sliders to stable's (an undoable edit).
  Future<void> _openEditor(NavigatorState navigator, Beatmap beatmap, BeatmapDocument doc,
      {bool lazerSliders = false, bool convertSliders = false, bool recovered = false}) async {
    EditorAudio? audio;
    final setPath = doc.setPath;
    if (setPath != null) {
      final messenger = ScaffoldMessenger.of(context);
      setState(() => _busy = true);
      try {
        // The editor's music takes over.
        await _preview.stop();
        audio = await widget.audioLoader(setPath, beatmap);
        if (audio == null && beatmap.audioFilename.isNotEmpty) {
          messenger.showSnackBar(SnackBar(content: Text('Audio file "${beatmap.audioFilename}" not found; editing without sound.')));
        }
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('Could not load audio ($e); editing without sound.')));
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
    if (setPath == null) await _preview.stop();
    final controller = EditorController(
      beatmap: beatmap,
      document: doc,
      files: files,
      library: doc.isInLibrary ? _library : null,
      clock: audio?.clock,
      hitsounds: audio?.hitsounds,
      // App-wide settings even when the map has no (loadable) audio.
      settings: audio?.settings ?? await _openSettings(),
      audioLoader: doc.isInLibrary ? widget.audioLoader : null,
      backgroundLoader: doc.isInLibrary ? widget.backgroundLoader : null,
      storyboardLoader: doc.isInLibrary ? widget.storyboardLoader : null,
      waveform: audio?.waveform,
      detailedWaveform: audio?.detailedWaveform,
      lazerSliders: lazerSliders,
      recovery: doc.isInLibrary ? _recovery : null,
    );
    if (recovered) controller.markRecovered();
    if (convertSliders) controller.convertSlidersToStable();
    // The editor pops with another difficulty's path to switch to it.
    final route = MaterialPageRoute<String>(builder: (_) => EditorScreen(controller: controller));
    final shown = navigator.push(route);
    // The dim stays under the editor sliding in, then goes (so it isn't
    // there when the editor closes).
    void lift(AnimationStatus s) {
      if (s != AnimationStatus.completed) return;
      route.animation?.removeStatusListener(lift);
      _setOpening(null);
    }
    route.animation?.addStatusListener(lift);
    final next = await shown;
    route.animation?.removeStatusListener(lift);
    _setOpening(null);
    if (doc.isInLibrary) await _refresh();
    if (next == null) _resumePreview();
    if (next != null && setPath != null && mounted) await _openLoaded(files.openLibraryFile(next, setPath));
  }

  /// The app's settings, or null where they can't be read (unit tests).
  static Future<SettingsStore?> _openSettings() async {
    try {
      return await SettingsStore.open();
    } catch (_) {
      return null;
    }
  }

  /// A new map starts from its song (like osu!stable): pick the audio,
  /// prefill title / artist from its tags, create the set and open it.
  Future<void> _newMap() async {
    final navigator = Navigator.of(context);
    Beatmap empty({String title = 'Untitled', String artist = '', String audio = ''}) {
      final b = Beatmap.empty();
      b.setValue(SectionNames.metadata, 'Title', title);
      if (artist.isNotEmpty) b.setValue(SectionNames.metadata, 'Artist', artist);
      b.setValue(SectionNames.metadata, 'Version', 'New Difficulty');
      b.setValue(SectionNames.general, 'AudioFilename', audio);
      b.insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
      b.revision = 0;
      return b;
    }

    final lib = _library;
    if (lib == null) {
      await _openEditor(navigator, empty(), const BeatmapDocument(fileName: 'new.osu'));
      return;
    }
    await _run(() async {
      final audio = await files.pickAudioFile();
      if (audio == null) return;
      final tags = AudioTags.read(audio.bytes);
      final dot = audio.name.lastIndexOf('.');
      final title = tags.title.isNotEmpty ? tags.title : (dot > 0 ? audio.name.substring(0, dot) : audio.name);
      var b = empty(title: title, artist: tags.artist);
      final d = await lib.createSet(b);
      final setPath = File(d.path).parent.path;
      final name = await lib.addFileToSet(setPath, audio.name, audio.bytes);
      b = empty(title: title, artist: tags.artist, audio: name);
      await File(d.path).writeAsBytes(OsuTextCodec.encode(OsuWriter.write(b), OsuTextEncoding.utf8), flush: true);
      await _refresh();
      _revealSet(setPath);
      // Re-open from disk so the editor works on exactly what was written.
      await _openLoaded(files.openLibraryFile(d.path, setPath));
    });
  }

  /// Opens the system page for changing which app opens `.osz` files.
  Future<void> _openDefaultAppSettings() async {
    final opened = await IncomingFiles.openDefaultAppSettings();
    if (opened == null) {
      _snack('Could not open the settings screen.');
    } else if (opened == 'lazer') {
      _snack('In osu!lazer\'s app info: Open by default → Clear defaults.');
    } else {
      _snack('osu!lazer is not installed; showing this app\'s settings.');
    }
  }

  void _snack(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // ---------------------------------------------------------------------------
  // Song select

  LibrarySet? get _selected {
    final sets = _sets;
    if (sets == null || sets.isEmpty) return null;
    for (final s in sets) {
      if (s.path == _selectedPath) return s;
    }
    return sets.first;
  }

  /// The selected difficulty of [set], or its first.
  LibraryDifficulty? _selectedDiffOf(LibrarySet set) {
    for (final d in set.difficulties) {
      if (d.path == _selectedDiffPath) return d;
    }
    return set.difficulties.isEmpty ? null : set.difficulties.first;
  }

  /// Tap on a difficulty: select it, or open it when it already is.
  void _tapDifficulty(LibrarySet set, LibraryDifficulty d) {
    if (_selectedDiffOf(set) == d && _selectedDiffPath != null) {
      _openDifficulty(set, d);
      return;
    }
    setState(() => _selectedDiffPath = d.path);
    // Its own song if the difficulties differ (same song: keeps playing).
    if (d.summary.audioFilename.isNotEmpty) {
      _preview.play(set.path, d.summary.audioFilename, d.summary.previewTime);
    }
  }

  /// Opens [set]'s difficulties (closing any other) and previews its song,
  /// or closes it when it is the open one.
  void _toggleSet(LibrarySet set) {
    final close = _expanded && _selectedPath == set.path;
    setState(() {
      if (_selectedPath != set.path) _selectedDiffPath = null;
      _selectedPath = set.path;
      _expanded = !close;
      // Opening selects the first difficulty (or the one selected before).
      if (!close) _selectedDiffPath = _selectedDiffOf(set)?.path;
    });
    if (close) {
      _preview.stop();
      return;
    }
    _playPreview(set);
    // Bring the open set near the top so its difficulties show.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _listKeys[set.path]?.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(ctx,
            alignment: 0.15, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
        return;
      }
      // Off screen (not built yet): every set above it is closed, so its
      // offset is known.
      final i = _sets?.indexWhere((s) => s.path == set.path) ?? -1;
      if (i < 0 || !_carousel.hasClients) return;
      final pos = _carousel.position;
      final target = _carouselTop + i * (SetCard.height + SetCard.gap) - pos.viewportDimension * 0.15;
      _carousel.animateTo(target.clamp(pos.minScrollExtent, pos.maxScrollExtent),
          duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
    });
  }

  void _playPreview(LibrarySet set) {
    final sel = _selectedDiffOf(set);
    final d = sel != null && sel.summary.audioFilename.isNotEmpty ? sel : set.previewSource;
    if (d == null) {
      _preview.stop();
      return;
    }
    _preview.play(set.path, d.summary.audioFilename, d.summary.previewTime);
  }

  /// Back on song select (editor closed, app resumed): the open set plays again.
  void _resumePreview() {
    if (!mounted || !_expanded) return;
    if (ModalRoute.of(context)?.isCurrent == false) return;
    final set = _selected;
    if (set != null) _playPreview(set);
  }

  // ---------------------------------------------------------------------------
  // UI

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    // No app bar (full-screen landscape app): the bar at the bottom left
    // holds the actions.
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          SongSelectBackground(file: selected == null ? null : _backgrounds.of(selected)),
          SafeArea(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 44, child: _buildLeft(selected)),
                Expanded(flex: 56, child: _buildCarousel()),
              ],
            ),
          ),
          if (_busy && _opening == null)
            const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator(minHeight: 3)),
          LoadingOverlay(opening: _opening),
        ],
      ),
    );
  }

  Widget _buildLeft(LibrarySet? selected) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.topLeft,
              child: selected == null ? null : SingleChildScrollView(child: _buildInfo(selected)),
            ),
          ),
          const SizedBox(height: 8),
          if (_pending.isNotEmpty) ...[_buildPendingBanner(), const SizedBox(height: 8)],
          _buildActions(),
        ],
      ),
    );
  }

  Widget _buildInfo(LibrarySet set) {
    final d = _selectedDiffOf(set);
    final url = d?.summary.websiteUrl(folderName: set.folderName);
    return MapInfoPanel(
      set: set,
      difficulty: d,
      onOpenPage: url == null
          ? null
          : () async {
              if (!await WebLinks.open(url)) _snack('Could not open $url');
            },
    );
  }

  Widget _buildPendingBanner() => Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        decoration: BoxDecoration(
          color: const Color(0xCC2A1630),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0x99FF66AA)),
        ),
        child: Row(children: [
          Expanded(
            child: Text('${_pending.length} .osz / .osk file(s) found in the app folder.',
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
          TextButton(onPressed: _busy ? null : _discardPending, child: const Text('Discard')),
          TextButton(onPressed: _busy ? null : _importPending, child: const Text('Import')),
        ]),
      );

  Widget _buildActions() {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: const Color(0xB3000000),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(children: [
        // Natural size when it fits, scaled down on a narrow screen.
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _importOsz,
                  icon: const Icon(Icons.file_download_outlined, size: 18),
                  label: const Text('Import .osz'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFFF66AA),
                    foregroundColor: Colors.white,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: 6),
                TextButton.icon(
                  onPressed: _busy ? null : _newMap,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New map'),
                  style: TextButton.styleFrom(foregroundColor: Colors.white, visualDensity: VisualDensity.compact),
                ),
              ]),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Refresh',
          color: Colors.white,
          visualDensity: VisualDensity.compact,
          onPressed: _busy ? null : _refreshWithFeedback,
          icon: const Icon(Icons.refresh),
        ),
        PopupMenuButton<String>(
          tooltip: 'More',
          iconColor: Colors.white,
          onSelected: (v) => switch (v) {
            'osu' => _openOsuFile(),
            'defaults' => _openDefaultAppSettings(),
            'skins' => showSkinPicker(context, files: files),
            _ => null,
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'osu', child: Text('Open single .osu file')),
            const PopupMenuItem(value: 'skins', child: Text('Skins…')),
            if (Platform.isAndroid) const PopupMenuItem(value: 'defaults', child: Text('.osz default app settings')),
          ],
        ),
      ]),
    );
  }

  Widget _message(Widget child) => Center(
        child: Container(
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(12)),
          child: child,
        ),
      );

  Widget _buildCarousel() {
    if (_error != null) return _message(Text(_error!, style: const TextStyle(color: Colors.white)));
    final sets = _sets;
    if (sets == null) return const Center(child: CircularProgressIndicator());
    if (sets.isEmpty) {
      return _message(const Text(
        'No beatmaps yet.\nImport an .osz or create a new map.',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white, fontSize: 14),
      ));
    }
    _listKeys.removeWhere((k, _) => !sets.any((s) => s.path == k));
    return ListView.builder(
      controller: _carousel,
      padding: const EdgeInsets.only(top: _carouselTop, bottom: 40),
      itemCount: sets.length,
      itemBuilder: (context, i) {
        final set = sets[i];
        final open = _expanded && set.path == _selectedPath;
        return Column(
          key: _listKeys.putIfAbsent(set.path, GlobalKey.new),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SetCard(
              set: set,
              expanded: open,
              background: _backgrounds.of(set),
              onTap: () => _toggleSet(set),
              menu: _setMenu(set),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: open
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final d in set.difficulties)
                            DifficultyCard(
                              difficulty: d,
                              creator: set.creator,
                              selected: d.path == _selectedDiffPath,
                              onTap: () => _tapDifficulty(set, d),
                              onMenu: (pos) => _difficultyMenu(set, d, pos),
                            ),
                        ],
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        );
      },
    );
  }

  Widget _setMenu(LibrarySet set) => PopupMenuButton<String>(
        tooltip: 'Set options',
        iconColor: Colors.white70,
        onSelected: (v) => switch (v) {
          'export' => _exportSet(set),
          'folder' => _openSetFolder(set),
          _ => _deleteSet(set),
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'export', child: Text('Export .osz')),
          if (MapFolder.supported) const PopupMenuItem(value: 'folder', child: Text('Open folder')),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      );
}
