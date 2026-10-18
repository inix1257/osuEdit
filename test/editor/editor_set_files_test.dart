import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/audio_clock.dart';
import 'package:osu_edit/editor/editor_audio.dart';
import 'package:osu_edit/editor/editor_clock.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/app_settings.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';
import 'package:osu_edit/platform/beatmap_library.dart';

import '../support/fake_audio.dart';

void main() {
  late Directory temp;
  late BeatmapLibrary lib;
  late EditorController c;
  late List<String> loaded;
  late List<RecordingHitsounds> outputs;
  late List<FakeTrack> tracks;

  /// Loads a FakeTrack whose length is the audio file's byte count × 1000
  /// (so tests can tell files apart), or null if the file is missing.
  Future<EditorAudio?> loader(String setPath, Beatmap b) async {
    loaded.add(b.audioFilename);
    final f = BeatmapLibrary.resolveFile(setPath, b.audioFilename);
    if (f == null) return null;
    final track = FakeTrack(() => 0, length: f.lengthSync() * 1000.0);
    final out = RecordingHitsounds();
    tracks.add(track);
    outputs.add(out);
    return EditorAudio(AudioClock(track, now: () => 0), out, await SettingsStore.load(File('${temp.path}/s.json')));
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('osuedit_files_');
    lib = BeatmapLibrary(Directory(BeatmapLibrary.joinPath(temp.path, 'Songs')));
    loaded = [];
    outputs = [];
    tracks = [];
    final b = Beatmap.empty();
    b.setValue(SectionNames.metadata, 'Title', 'New');
    b.insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
    final d = await lib.createSet(b);
    final opened = await const BeatmapFileService().openLibraryFile(d.path, File(d.path).parent.path);
    c = EditorController(
      beatmap: OsuParser.parse(opened.text),
      document: opened.document,
      library: lib,
      audioLoader: loader,
    );
  });

  tearDown(() async {
    await c.settings?.save(); // let pending settings writes finish
    c.dispose();
    await temp.delete(recursive: true);
  });

  PickedFile file(String name, int size) => PickedFile(name, Uint8List(size));

  test('a new map has no audio; choosing a file loads it (undoable)', () async {
    expect(c.hasAudio, isFalse);
    expect(c.canChangeSetFiles, isTrue);
    c.seek(3000);
    c.rate = 0.5;

    await c.importAudioFile(file('My Song.mp3', 20));
    expect(c.beatmap.audioFilename, 'My Song.mp3');
    expect(File('${c.document.setPath}/My Song.mp3').existsSync(), isTrue);
    expect(c.hasAudio, isTrue);
    expect(c.clock.duration, 20000);
    expect(c.time.value, 3000); // position and rate carried over
    expect(c.rate, 0.5);
    expect(c.audioError, isNull);
    expect(c.isDirty, isTrue);
    expect(c.serialize(), contains('AudioFilename: My Song.mp3\r\n'));

    // Undo restores the old (missing) name → silent clock, old audio freed.
    c.undo();
    await c.audioLoaded;
    expect(loaded, ['My Song.mp3', 'audio.mp3']);
    expect(c.clock, isA<StopwatchClock>());
    expect(c.audioError, contains('not found'));
    expect(outputs.single.disposed, isTrue);
    expect(c.isDirty, isFalse);

    c.redo();
    await c.audioLoaded;
    expect(c.hasAudio, isTrue);
    expect(c.audioError, isNull);
  });

  test('re-picking a file with the same name and content does not add an edit', () async {
    await c.importAudioFile(file('a.mp3', 5));
    c.history.markSaved();
    await c.importAudioFile(file('a.mp3', 5));
    expect(c.isDirty, isFalse);
    expect(loaded, ['a.mp3', 'a.mp3']);
  });

  test('a superseded load is discarded', () async {
    await lib.addFileToSet(c.document.setPath!, 'one.mp3', Uint8List(1));
    await lib.addFileToSet(c.document.setPath!, 'two.mp3', Uint8List(2));
    c.history.execute(SetValueCommand(SectionNames.general, 'AudioFilename', 'one.mp3'));
    c.history.execute(SetValueCommand(SectionNames.general, 'AudioFilename', 'two.mp3'));
    await c.audioLoaded;
    RecordingHitsounds outputFor(double length) => outputs[tracks.indexWhere((t) => t.length == length)];
    // The superseded load may finish before or after the current one, and is
    // disposed just after its loader returns: wait for that, not for timing.
    for (var i = 0; i < 400 && !(outputs.length == 2 && outputFor(1000).disposed); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(c.clock.duration, 2000);
    expect(outputFor(1000).disposed, isTrue);
    expect(outputFor(2000).disposed, isFalse);
  });

  test('seek is clamped to the song', () async {
    await c.importAudioFile(file('a.mp3', 10));
    // Displayed (map) time of the audio end: the song plays
    // [EditorController.mapAudioOffsetMs] behind map time.
    final d = c.mapAudioOffsetMs;
    c.seek(99999);
    expect(c.time.value, 10000 - d);
    c.seek(-99999);
    expect(c.time.value, -c.preempt);
    c.updateAudioSettings(offsetMs: 40);
    c.seek(99999);
    expect(c.time.value, 10000 - 40 - d);
    c.stepBeat(forward: true);
    expect(c.time.value, 10000 - 40 - d);
  });

  test('background image is copied and set (undoable)', () async {
    expect(c.beatmap.backgroundFilename, isNull);
    await c.importBackgroundFile(file('cover.jpg', 3));
    expect(c.beatmap.backgroundFilename, 'cover.jpg');
    expect(File('${c.document.setPath}/cover.jpg').existsSync(), isTrue);
    c.undo();
    expect(c.beatmap.backgroundFilename, isNull);
    expect(c.isDirty, isFalse);
    expect(loaded, isEmpty); // background changes never reload audio
  });
  group('difficulties', () {
    List<String> osuFiles() => [
          for (final e in Directory(c.document.setPath!).listSync())
            if (e.path.endsWith('.osu')) e.path.substring(e.path.lastIndexOf(Platform.pathSeparator) + 1),
        ]..sort();

    test('saving renames the file only after its metadata changed', () async {
      final original = c.document.fileName;
      c.placeCircle(const Vec2(100, 100));
      await c.save();
      expect(c.document.fileName, original);

      c.setValues('Song setup', [
        (SectionNames.metadata, 'Artist', 'Someone'),
        (SectionNames.metadata, 'Version', 'Hard'),
      ]);
      await c.save();
      expect(c.document.fileName, 'Someone - New () [Hard].osu');
      expect(c.document.path, endsWith('Someone - New () [Hard].osu'));
      expect(osuFiles(), ['Someone - New () [Hard].osu']);
      expect(c.isDirty, isFalse);
      expect(File(c.document.path!).readAsStringSync(), c.serialize());
    });

    test('new and duplicated difficulties get unique names', () async {
      c.placeCircle(const Vec2(100, 100));
      final empty = await c.createDifficulty('Extra');
      final copy = await c.createDifficulty('Extra', copyObjects: true);
      expect(empty, endsWith(' [Extra].osu'));
      expect(copy, endsWith(' [Extra] (2).osu'));
      final e = OsuParser.parse(File(empty!).readAsStringSync());
      final d = OsuParser.parse(File(copy!).readAsStringSync());
      expect(e.hitObjects, isEmpty);
      expect(d.hitObjects.length, 1);
      expect(e.timingPoints.single.bpm, 120);
      expect(e.version, 'Extra');
      expect(osuFiles().length, 3);
    });

    test('set metadata is copied to the other difficulties on disk', () async {
      final other = await c.createDifficulty('Other');
      final before = File(other!).readAsStringSync();
      c.setValues('Song setup', [
        (SectionNames.metadata, 'Title', 'Renamed'),
        (SectionNames.metadata, 'Version', 'Mine'),
      ]);
      expect(await c.syncMetadataToSet(), 1);
      expect(File(other).existsSync(), isFalse); // renamed with the new title
      final renamed = File('${c.document.setPath}${Platform.pathSeparator}- Renamed () [Other].osu'); // sanitized: no leading space
      expect(renamed.readAsStringSync(), before.replaceFirst('Title:New', 'Title:Renamed'));
      expect(await c.syncMetadataToSet(), 0); // already in sync
    });

    test('the set storyboard follows the metadata (osu!stable finds it by name)', () async {
      File p(String n) => File('${c.document.setPath}${Platform.pathSeparator}$n');
      // Beatmap.empty: no artist / creator.
      p(' - New ().osb').writeAsStringSync('[Events]');
      p('other.osb').writeAsStringSync('x');
      c.setValues('Song setup', [(SectionNames.metadata, 'Artist', 'Someone')]);
      await c.save();
      expect(p('Someone - New ().osb').readAsStringSync(), '[Events]');
      expect(p(' - New ().osb').existsSync(), isFalse);
      expect(p('other.osb').existsSync(), isTrue);
      // Undo + save: back again.
      c.undo();
      await c.save();
      expect(p(' - New ().osb').existsSync(), isTrue);
      expect(p('Someone - New ().osb').existsSync(), isFalse);
      // Copying metadata to the other difficulties renames it too.
      await c.createDifficulty('Other');
      c.setValues('Song setup', [(SectionNames.metadata, 'Title', 'Renamed')]);
      await c.syncMetadataToSet();
      expect(p(' - Renamed ().osb').existsSync(), isTrue);
      await c.save(); // nothing left to rename
      expect(p(' - Renamed ().osb').readAsStringSync(), '[Events]');
    });
  });
}
