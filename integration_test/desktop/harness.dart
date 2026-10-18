// Shared helpers for desktop (Windows) integration tests that run in the
// background: the window is off-screen and never activated (runner reads
// OSUEDIT_BACKGROUND=1), input is injected by WidgetTester (not the OS
// mouse/keyboard), and screenshots are rendered from the widget tree.
//
// Run (bash, project root):
//   OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/<x>_test.dart -d windows
// Screenshots land in build/desktop_shots/<name>.png.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/home/home_screen.dart';
import 'package:osu_edit/home/song_select.dart';
import 'package:osu_edit/main.dart';
import 'package:osu_edit/platform/app_settings.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';
import 'package:osu_edit/platform/beatmap_library.dart';
import 'package:osu_edit/platform/preview_audio.dart';

/// Phone-like logical size (Galaxy S23+ landscape: 2340×1080 px at dpr 2.8125).
const phoneSize = Size(832, 384);
const phoneDpr = 2.8125;

final _boundary = GlobalKey();

void ensureDesktopBinding() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Frames are driven by pump(), like a widget test, but timers/IO are real.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
}

/// Project root (the test exe's working directory may differ).
Directory get projectRoot {
  var dir = File(Platform.resolvedExecutable).parent;
  while (dir.parent.path != dir.path) {
    if (File('${dir.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) return dir;
    dir = dir.parent;
  }
  return Directory.current;
}

/// Path under the project root, written with forward slashes.
String projectPath(String relative) =>
    '${projectRoot.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';

/// A throwaway library (never the real one in AppData) with [osz] imported
/// (paths relative to the project root, e.g. `tool/test_set/osuEdit test set.osz`).
Future<BeatmapLibrary> tempLibrary({List<String> osz = const []}) async {
  final dir = await Directory.systemTemp.createTemp('osuedit_it_');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {} // audio files can stay locked until the app exits
  });
  // Settings too: never the real app's settings.json.
  SettingsStore.fileOverride = File(BeatmapLibrary.joinPath(dir.path, 'settings.json'));
  addTearDown(() => SettingsStore.fileOverride = null);
  final lib = BeatmapLibrary(Directory(BeatmapLibrary.joinPath(dir.path, 'Songs')));
  await lib.root.create(recursive: true);
  for (final p in osz) {
    final f = File(projectPath(p));
    await lib.importOsz(await f.readAsBytes(), fallbackName: f.uri.pathSegments.last);
  }
  return lib;
}

/// Pumps the real app (home screen on [library]) at a phone-like size.
/// Song previews are silent unless [preview] is given (no music out loud);
/// [files] replaces the pickers (the OS dialogs would take the focus).
Future<void> pumpApp(WidgetTester tester, BeatmapLibrary library,
    {Size size = phoneSize,
    double dpr = phoneDpr,
    PreviewPlayer preview = const SilentPreviewPlayer(),
    BeatmapFileService files = const BeatmapFileService()}) async {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = size * dpr;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(RepaintBoundary(key: _boundary, child: OsuEditApp(home: HomeScreen(library: library, previewPlayer: preview, files: files))));
  await settle(tester);
}

/// Pumps the editor on [controller] directly (a map built in the test, no
/// library), at a phone-like size, so [shot] works on it.
Future<void> pumpEditor(WidgetTester tester, EditorController controller,
    {Size size = phoneSize, double dpr = phoneDpr}) async {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = size * dpr;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
      RepaintBoundary(key: _boundary, child: OsuEditApp(home: EditorScreen(controller: controller))));
  await settle(tester);
}

/// Pumps until [finder] matches (real async work: isolates, file IO, audio).
Future<void> waitFor(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(end)) throw TestFailure('Timed out waiting for $finder');
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Pumps for [d] of real time (lets animations and async loads finish).
Future<void> settle(WidgetTester tester, [Duration d = const Duration(milliseconds: 600)]) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Opens difficulty [version] of the library set whose title contains [setTitle].
Future<void> openDifficulty(WidgetTester tester, String setTitle, String version) async {
  await openSet(tester, setTitle);
  await tapDifficulty(tester, version);
  await waitFor(tester, find.byType(EditorScreen));
  await settle(tester, const Duration(seconds: 1));
}

/// The song select card of the set whose title contains [setTitle] (the
/// info panel shows the selected set's title too).
Finder setCard(String setTitle) =>
    find.descendant(of: find.byType(SetCard), matching: find.textContaining(setTitle));

/// Opens (expands) the song select card of the set titled [setTitle].
Future<void> openSet(WidgetTester tester, String setTitle) async {
  await waitFor(tester, setCard(setTitle));
  await tester.tap(setCard(setTitle).first);
  await settle(tester);
}

/// Opens difficulty [version] of the open set from its card: the first tap
/// selects it (unless it is selected), the next one opens it.
Future<void> tapDifficulty(WidgetTester tester, String version) async {
  final card = find.ancestor(of: find.text(version), matching: find.byType(DifficultyCard)).first;
  await waitFor(tester, card);
  if (!tester.widget<DifficultyCard>(card).selected) {
    await tester.tap(card);
    await settle(tester, const Duration(milliseconds: 300));
  }
  await tester.tap(card);
}

/// System back (Android back button / gesture): pops the top route through
/// its PopScope, so unsaved-changes prompts still show.
Future<void> back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await settle(tester);
}

/// Saves the app as `build/desktop_shots/<name>.png` and returns the file.
Future<File> shot(WidgetTester tester, String name, {double pixelRatio = phoneDpr / 2}) async {
  await tester.pump();
  final boundary = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: pixelRatio);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final file = File(projectPath('build/desktop_shots/$name.png'));
  await file.parent.create(recursive: true);
  await file.writeAsBytes(png!.buffer.asUint8List());
  // ignore: avoid_print
  print('shot: ${file.path}');
  return file;
}
