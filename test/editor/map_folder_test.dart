import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';
import 'package:osu_edit/platform/map_folder.dart';

void main() {
  tearDown(() => MapFolder.debugOpen = null);

  Future<EditorController> pump(WidgetTester tester, BeatmapDocument doc) async {
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = EditorController(
      beatmap: OsuParser.parse(File('test/fixtures/sample_v14.osu').readAsStringSync()),
      document: doc,
    );
    await tester.pumpWidget(MaterialApp(home: EditorScreen(controller: c)));
    return c;
  }

  Future<void> openMapMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Map'));
    await tester.pumpAndSettle();
  }

  testWidgets('"Open map folder" opens the set folder of a library map', (tester) async {
    final opened = <String>[];
    MapFolder.debugOpen = (path) async {
      opened.add(path);
      return MapFolderResult.opened;
    };
    await pump(tester, const BeatmapDocument(fileName: 'x.osu', path: '/lib/Set/x.osu', setPath: '/lib/Set'));
    await openMapMenu(tester);
    await tester.tap(find.text('Open map folder'));
    await tester.pumpAndSettle();
    expect(opened, ['/lib/Set']);
  });

  testWidgets('says so when it falls back to the library root, or fails', (tester) async {
    MapFolder.debugOpen = (_) async => MapFolderResult.openedLibraryRoot;
    await pump(tester, const BeatmapDocument(fileName: 'x.osu', path: '/lib/My Set/x.osu', setPath: '/lib/My Set'));
    await openMapMenu(tester);
    await tester.tap(find.text('Open map folder'));
    await tester.pumpAndSettle();
    expect(find.textContaining('the map is in "My Set"'), findsOneWidget);
  });

  testWidgets('no item for a map that has no folder (new / sample map)', (tester) async {
    MapFolder.debugOpen = (_) async => MapFolderResult.opened;
    await pump(tester, const BeatmapDocument(fileName: 'x.osu'));
    await openMapMenu(tester);
    expect(find.text('Open map folder'), findsNothing);
  });
}
