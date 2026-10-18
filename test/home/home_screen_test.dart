import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/home/home_screen.dart';
import 'package:osu_edit/home/song_select.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';
import 'package:osu_edit/platform/beatmap_library.dart';
import 'package:osu_edit/platform/incoming_files.dart';
import 'package:osu_edit/platform/preview_audio.dart';

/// Records what song select asked to preview.
class RecordingPreview implements PreviewPlayer {
  final calls = <String>[];
  @override
  Future<void> play(String setPath, String audioFile, int previewTime) async =>
      calls.add('play ${setPath.substring(setPath.lastIndexOf(Platform.pathSeparator) + 1)} $audioFile $previewTime');
  @override
  Future<void> stop() async => calls.add('stop');
}

/// Pickers that hand out prepared files.
class FakeFiles extends BeatmapFileService {
  PickedFile? audio;
  PickedOsu? osu;
  FakeFiles({this.audio, this.osu});
  @override
  Future<PickedFile?> pickAudioFile() async => audio;
  @override
  Future<PickedOsu?> pickOsu() async => osu;
}

/// A tiny "MP3": an ID3v2.3 tag with [title] / [artist], then a frame header.
Uint8List taggedMp3(String title, String artist) {
  List<int> frame(String id, String text) {
    final body = [0, ...text.codeUnits];
    return [...id.codeUnits, 0, 0, 0, body.length, 0, 0, ...body];
  }

  final frames = [...frame('TIT2', title), ...frame('TPE1', artist)];
  return Uint8List.fromList([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, frames.length, ...frames, 0xFF, 0xFB, 0x90, 0]);
}

void main() {
  late Directory temp;
  late BeatmapLibrary lib;
  late RecordingPreview preview;

  setUp(() async {
    preview = RecordingPreview();
    temp = await Directory.systemTemp.createTemp('osuedit_home_');
    lib = BeatmapLibrary(Directory(BeatmapLibrary.joinPath(temp.path, 'Songs')));
  });

  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } on FileSystemException {
      // A card's background image read can keep a file open under fake async.
    }
  });

  /// The carousel card of the set titled [title] (the info panel shows it too).
  Finder setCard(String title) => find.descendant(of: find.byType(SetCard), matching: find.text(title));

  /// Lets real file I/O / isolates finish, then rebuilds.
  Future<void> settleIo(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
  }

  testWidgets('empty library shows the hint', (tester) async {
    await tester.pumpWidget(MaterialApp(home: HomeScreen(library: lib, previewPlayer: preview)));
    await settleIo(tester);
    expect(find.textContaining('No beatmaps yet'), findsOneWidget);
    expect(find.text('Import .osz'), findsOneWidget);
  });

  testWidgets('lists imported sets and opens a difficulty in the editor', (tester) async {
    final bytes = Uint8List.fromList(File('test/fixtures/sample_v14.osu').readAsBytesSync());
    final set = (await tester.runAsync(() => lib.importOsz(OszCodec.encode([PackageEntry('a.osu', bytes)]))))!;
    final summary = set.difficulties.single.summary;

    await tester.pumpWidget(MaterialApp(home: HomeScreen(library: lib, previewPlayer: preview)));
    await settleIo(tester);
    expect(setCard(set.title), findsOneWidget);

    await tester.tap(setCard(set.title));
    await tester.pumpAndSettle();
    // The tap starts real file I/O, so it must run outside fake async.
    await tester.runAsync(() async {
      await tester.tap(find.descendant(of: find.byType(DifficultyCard), matching: find.text(summary.version)));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // route transition
    expect(find.byType(EditorScreen), findsOneWidget);
    // Export lives in the editor menu (library maps only).
    await tester.tap(find.byTooltip('Menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Map'));
    await tester.pumpAndSettle();
    expect(find.text('Export .osz…'), findsOneWidget);
  });

  testWidgets('opening a set previews its song; closing it, another set or the editor stops it', (tester) async {
    final a = Uint8List.fromList(File('test/fixtures/sample_v14.osu').readAsBytesSync());
    final b = Uint8List.fromList(File('test/fixtures/sync_test_v14.osu').readAsBytesSync());
    final setA = (await tester.runAsync(() => lib.importOsz(OszCodec.encode([PackageEntry('a.osu', a)]))))!;
    final setB = (await tester.runAsync(() => lib.importOsz(OszCodec.encode([PackageEntry('b.osu', b)]))))!;
    await tester.pumpWidget(MaterialApp(home: HomeScreen(library: lib, previewPlayer: preview)));
    await settleIo(tester);
    // Nothing plays until a set is opened; its difficulties are hidden.
    expect(preview.calls, isEmpty);
    expect(find.byType(DifficultyCard), findsNothing);

    await tester.tap(setCard(setA.title));
    await tester.pumpAndSettle();
    expect(preview.calls, ['play ${setA.folderName} audio.mp3 12000']);
    expect(find.byType(DifficultyCard), findsOneWidget);

    // Another set: only one is open at a time.
    await tester.tap(setCard(setB.title));
    await tester.pumpAndSettle();
    expect(preview.calls.last, 'play ${setB.folderName} audio.mp3 9000');
    expect(find.byType(DifficultyCard), findsOneWidget);
    expect(find.descendant(of: find.byType(DifficultyCard), matching: find.text(setB.difficulties.single.summary.version)), findsOneWidget);

    // Tapping the open set closes it and stops the preview.
    await tester.tap(setCard(setB.title));
    await tester.pumpAndSettle();
    expect(preview.calls.last, 'stop');
    expect(find.byType(DifficultyCard), findsNothing);

    // Opening a difficulty stops the preview before the editor loads.
    await tester.tap(setCard(setA.title));
    await tester.pumpAndSettle();
    preview.calls.clear();
    await tester.runAsync(() async {
      await tester.tap(find.descendant(of: find.byType(DifficultyCard), matching: find.text(setA.difficulties.single.summary.version)));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(EditorScreen), findsOneWidget);
    expect(preview.calls, ['stop']);
  });

  testWidgets('a tap selects a difficulty and shows its stats; a second tap opens it', (tester) async {
    final shapes = Uint8List.fromList(File('test/fixtures/slider_shapes_v14.osu').readAsBytesSync());
    final sync = Uint8List.fromList(File('test/fixtures/sync_test_v14.osu').readAsBytesSync());
    final set = (await tester.runAsync(
        () => lib.importOsz(OszCodec.encode([PackageEntry('a.osu', shapes), PackageEntry('b.osu', sync)]))))!;
    await tester.pumpWidget(MaterialApp(home: HomeScreen(library: lib, previewPlayer: preview)));
    await settleIo(tester);
    await tester.tap(setCard(set.title));
    await tester.pumpAndSettle();
    final first = set.difficulties.first, second = set.difficulties.last;
    Finder card(LibraryDifficulty d) =>
        find.ancestor(of: find.text(d.summary.version), matching: find.byType(DifficultyCard)).first;
    Finder panel(String text) =>
        find.descendant(of: find.byType(MapInfoPanel), matching: find.text(text, findRichText: true));
    // Opening the set selects its first difficulty: its stats are shown.
    expect(tester.widget<DifficultyCard>(card(first)).selected, isTrue);
    expect(panel(first.summary.version), findsOneWidget);
    expect(panel('Circle ${first.summary.circleCount}'), findsOneWidget);

    await tester.tap(card(second));
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsNothing);
    expect(tester.widget<DifficultyCard>(card(second)).selected, isTrue);
    expect(panel(second.summary.version), findsOneWidget);
    expect(panel(first.summary.version), findsNothing);
    expect(panel('Slider ${second.summary.sliderCount}'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(card(second));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(EditorScreen), findsOneWidget);
  });

  testWidgets('New map starts by picking the audio; title and artist come from its tags', (tester) async {
    final files = FakeFiles(audio: PickedFile('song.mp3', taggedMp3('Night Run', 'Some Artist')));
    await tester.pumpWidget(MaterialApp(
        home: HomeScreen(library: lib, files: files, previewPlayer: preview, audioLoader: (_, _) async => null)));
    await settleIo(tester);
    await tester.runAsync(() async {
      await tester.tap(find.text('New map'));
      for (var i = 0; i < 30 && find.byType(EditorScreen).evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    });
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(EditorScreen), findsOneWidget);
    final set = (await tester.runAsync(lib.listSets))!.single;
    final s = set.difficulties.single.summary;
    expect((s.title, s.artist, s.audioFilename), ('Night Run', 'Some Artist', 'song.mp3'));
    expect(File(BeatmapLibrary.joinPath(set.path, 'song.mp3')).existsSync(), isTrue);
  });

  testWidgets('New map: cancelling the audio picker creates nothing', (tester) async {
    await tester.pumpWidget(MaterialApp(home: HomeScreen(library: lib, files: FakeFiles(), previewPlayer: preview)));
    await settleIo(tester);
    await tester.runAsync(() async {
      await tester.tap(find.text('New map'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(find.byType(EditorScreen), findsNothing);
    expect((await tester.runAsync(lib.listSets))!, isEmpty);
  });

  testWidgets('a single .osu is imported as a set with the audio and background beside it', (tester) async {
    final folder = Directory(BeatmapLibrary.joinPath(temp.path, 'outside'))..createSync();
    final bytes = File('test/fixtures/sample_v14.osu').readAsBytesSync();
    File(BeatmapLibrary.joinPath(folder.path, 'audio.mp3')).writeAsBytesSync([1, 2, 3]);
    File(BeatmapLibrary.joinPath(folder.path, 'bg.jpg')).writeAsBytesSync([4, 5]);
    File(BeatmapLibrary.joinPath(folder.path, 'unrelated.txt')).writeAsStringSync('x');
    final (text, enc) = OsuTextCodec.decode(bytes);
    final files = FakeFiles(
        osu: PickedOsu(LoadedBeatmapFile(BeatmapDocument(fileName: 'map.osu', encoding: enc), text), bytes, folder.path));
    await tester.pumpWidget(MaterialApp(home: HomeScreen(library: lib, files: files, previewPlayer: preview)));
    await settleIo(tester);
    // The options menu has no sample map any more.
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Open sample map'), findsNothing);
    await tester.tap(find.text('Open single .osu file'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.text('Import beatmap?'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Import'));
      for (var i = 0; i < 30 && (await lib.listSets()).isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    // Import, refresh and the slider format check run real I/O.
    for (var i = 0; i < 30 && find.byType(DifficultyCard).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    final set = (await tester.runAsync(lib.listSets))!.single;
    final names = Directory(set.path).listSync().map((e) => e.uri.pathSegments.last).toSet();
    expect(names, {'map.osu', 'audio.mp3', 'bg.jpg'});
    expect(File(BeatmapLibrary.joinPath(set.path, 'map.osu')).readAsBytesSync(), bytes);
    // Imported and opened in the carousel.
    expect(find.byType(DifficultyCard), findsOneWidget);
  });

  testWidgets('difficulty cards show the star rating', (tester) async {
    final bytes = Uint8List.fromList(File('test/fixtures/sync_test_v14.osu').readAsBytesSync());
    final set = (await tester.runAsync(() => lib.importOsz(OszCodec.encode([PackageEntry('a.osu', bytes)]))))!;
    await tester.runAsync(lib.computeStarRatings);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(library: lib, previewPlayer: preview)));
    await settleIo(tester);
    await tester.tap(setCard(set.title));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(DifficultyCard), matching: find.text('★ 6.37')), findsOneWidget);
  });

  test("star rating colours follow lazer's spectrum", () {
    expect(starRatingColor(0), const Color(0xFFAAAAAA));
    expect(starRatingColor(2.0), const Color(0xFF4FFFD5));
    expect(starRatingColor(4.9), const Color(0xFFFF4E6F));
    expect(starRatingColor(12), const Color(0xFF000000));
    // Between stops: mixed.
    final mid = starRatingColor(2.25);
    expect(mid, isNot(starRatingColor(2.0)));
    expect(mid, isNot(starRatingColor(2.5)));
  });

  /// Like [settleIo] for work that shows a progress indicator the whole time
  /// (pumpAndSettle would never settle): real-time waits until it's gone.
  Future<void> settleBusy(WidgetTester tester) async {
    // Idle three checks in a row: work can start right after other work.
    var idle = 0;
    for (var i = 0; i < 50 && idle < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      idle = find.byType(ProgressIndicator).evaluate().isEmpty ? idle + 1 : 0;
    }
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('files handed over by other apps are imported when the native side reports them', (tester) async {
    final inbox = Directory(BeatmapLibrary.joinPath(temp.path, 'Inbox'));
    lib = BeatmapLibrary(Directory(BeatmapLibrary.joinPath(temp.path, 'Songs')), inboxes: [inbox]);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(library: lib, previewPlayer: preview)));
    await settleBusy(tester);

    // What MainActivity / OszReceiver do: copy into the inbox, then notify.
    final bytes = Uint8List.fromList(File('test/fixtures/sample_v14.osu').readAsBytesSync());
    inbox.createSync(recursive: true);
    File(BeatmapLibrary.joinPath(inbox.path, 'shared.osz'))
        .writeAsBytesSync(OszCodec.encode([PackageEntry('a.osu', bytes)]));
    File(BeatmapLibrary.joinPath(inbox.path, 'broken.osz')).writeAsStringSync('not a zip');
    await tester.runAsync(() async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        IncomingFiles.channel.name,
        const StandardMethodCodec().encodeMethodCall(const MethodCall('changed')),
        (_) {},
      );
    });
    await settleBusy(tester);

    expect((await tester.runAsync(lib.listSets))!.length, 1);
    expect(find.textContaining('Imported 1 set'), findsOneWidget);
    expect(find.textContaining('broken.osz'), findsOneWidget);
    // The bad file stays listed until discarded.
    expect(find.textContaining('1 .osz / .osk file(s)'), findsOneWidget);
    // The tap starts real file I/O, so it must run outside fake async.
    await tester.runAsync(() => tester.tap(find.text('Discard')));
    await settleBusy(tester);
    expect(find.textContaining('.osk file(s)'), findsNothing);
    expect(inbox.listSync(), isEmpty);
  });
  testWidgets('files the app was launched with are imported once Dart is ready', (tester) async {
    final inbox = Directory(BeatmapLibrary.joinPath(temp.path, 'Inbox'))..createSync(recursive: true);
    lib = BeatmapLibrary(Directory(BeatmapLibrary.joinPath(temp.path, 'Songs')), inboxes: [inbox]);
    final bytes = Uint8List.fromList(File('test/fixtures/sample_v14.osu').readAsBytesSync());
    File(BeatmapLibrary.joinPath(inbox.path, 'launched.osz')).writeAsBytesSync(OszCodec.encode([PackageEntry('a.osu', bytes)]));
    // The native side copied it before Dart listened: it answers "ready" with true.
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(IncomingFiles.channel, (call) async => call.method == 'ready' ? true : null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(IncomingFiles.channel, null));

    // Mounted in real async time: the import started from the "ready" reply
    // runs an isolate whose result never reaches fake-async code.
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: HomeScreen(library: lib, previewPlayer: preview)));
      for (var i = 0; i < 30 && inbox.listSync().isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect((await tester.runAsync(lib.listSets))!.length, 1);
    expect(inbox.listSync(), isEmpty);
  });
}
