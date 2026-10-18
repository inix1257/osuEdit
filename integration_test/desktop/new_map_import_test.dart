// New map (audio first, metadata from its tags) and single .osu import from
// song select, with fake pickers (the OS file dialogs would take the focus).
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/new_map_import_test.dart -d windows
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/home/song_select.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';
import 'package:osu_edit/platform/beatmap_library.dart';

import 'harness.dart';

class FakeFiles extends BeatmapFileService {
  PickedFile? audio;
  PickedOsu? osu;
  FakeFiles({this.audio, this.osu});
  @override
  Future<PickedFile?> pickAudioFile() async => audio;
  @override
  Future<PickedOsu?> pickOsu() async => osu;
}

void main() {
  ensureDesktopBinding();

  testWidgets('New map picks the audio first', (tester) async {
    final lib = await tempLibrary();
    final mp3 = File(projectPath('tool/test_set/audio.mp3')).readAsBytesSync();
    await pumpApp(tester, lib, files: FakeFiles(audio: PickedFile('My Song.mp3', mp3)));
    await tester.tap(find.text('New map'));
    await waitFor(tester, find.byType(EditorScreen));
    await settle(tester, const Duration(seconds: 1));
    await shot(tester, 'new_map_editor');
    final set = (await tester.runAsync(lib.listSets))!.single;
    final s = set.difficulties.single.summary;
    // The test audio has no tags: the title is the file name.
    expect((s.title, s.audioFilename), ('My Song', 'My Song.mp3'));
    await back(tester);
    await waitFor(tester, find.byType(DifficultyCard));
    await shot(tester, 'new_map_library');
  });

  testWidgets('a single .osu is imported with its audio and background', (tester) async {
    // Enough sets that the new one lands below the screen.
    final lib = await tempLibrary(osz: [
      for (var i = 0; i < 6; i++) 'tool/test_set/osuEdit test set.osz',
      'tool/test_set/osuEdit lazer test.osz',
    ]);
    final bytes = File(projectPath('test/fixtures/sync_test_v14.osu')).readAsBytesSync();
    final (text, enc) = OsuTextCodec.decode(bytes);
    final files = FakeFiles(
        osu: PickedOsu(LoadedBeatmapFile(BeatmapDocument(fileName: 'sync.osu', encoding: enc), text), bytes,
            projectPath('tool/test_set')));
    await pumpApp(tester, lib, files: files);
    await tester.tap(find.byTooltip('More'));
    await settle(tester);
    await shot(tester, 'osu_import_menu');
    expect(find.text('Open sample map'), findsNothing);
    await tester.tap(find.text('Open single .osu file'));
    await waitFor(tester, find.text('Import beatmap?'));
    await shot(tester, 'osu_import_dialog');
    await tester.tap(find.text('Import'));
    await waitFor(tester, find.byType(DifficultyCard));
    await settle(tester, const Duration(seconds: 2));
    await shot(tester, 'osu_import_done');
    final sets = (await tester.runAsync(lib.listSets))!;
    final set = sets.firstWhere((s) => s.difficulties.any((d) => d.fileName == 'sync.osu'));
    // Scrolled to it: its card (the open one) is on screen.
    final open = find.byWidgetPredicate((w) => w is SetCard && w.expanded);
    expect(open, findsOneWidget);
    expect(tester.widget<SetCard>(open).set.path, set.path);
    expect(open.hitTestable(), findsOneWidget);
    final names = Directory(set.path).listSync().map((e) => e.uri.pathSegments.last).toSet();
    expect(names, containsAll(['sync.osu', 'audio.mp3', 'bg.jpg']));
    expect(find.descendant(of: find.byType(MapInfoPanel), matching: find.textContaining('Circle ', findRichText: true)),
        findsOneWidget);
    expect(BeatmapLibrary.resolveFile(set.path, 'audio.mp3'), isNotNull);
  });
}
