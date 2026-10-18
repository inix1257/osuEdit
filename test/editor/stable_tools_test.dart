import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';
import 'package:osu_edit/platform/beatmap_library.dart';

EditorController _controller(List<HitObject> objects) {
  final b = Beatmap.empty();
  b.insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
  for (final h in objects) {
    b.insertHitObject(h);
  }
  b.revision = 0;
  return EditorController(beatmap: b, document: const BeatmapDocument(fileName: 'new.osu'));
}

void main() {
  group('polygon circles', () {
    test('preview updates in place; apply is one undo step', () {
      final c = _controller(const []);
      addTearDown(c.dispose);
      c.seek(1000);
      expect(c.beginPolygon(), isTrue);
      expect(c.updatePolygon(vertices: 3), isTrue);
      expect(c.beatmap.hitObjects, hasLength(3));
      c.updatePolygon(vertices: 5, repeats: 2);
      expect(c.beatmap.hitObjects, hasLength(10));
      expect(c.selection, hasLength(10));
      c.endPolygon(apply: true);
      expect(c.history.undoLabel, 'Polygon circles');
      c.undo();
      expect(c.beatmap.hitObjects, isEmpty);
    });

    test('cancel leaves the map untouched', () {
      final c = _controller(const []);
      addTearDown(c.dispose);
      final before = OsuWriter.write(c.beatmap);
      c.beginPolygon();
      c.updatePolygon(vertices: 4);
      c.endPolygon(apply: false);
      expect(OsuWriter.write(c.beatmap), before);
      expect(c.isDirty, isFalse);
      expect(c.selection, isEmpty);
    });
  });

  group('resets', () {
    HitCircle hc(double t, {int sound = 0, int skip = 0}) => HitCircle(
          position: const Vec2(100, 100),
          time: t,
          hitSound: sound,
          newCombo: skip > 0,
          comboSkip: skip,
          sample: sound == 0 ? HitSample.empty : const HitSample(normalSet: 2),
        );

    test('whole map when nothing is selected, selection otherwise', () {
      final a = hc(1000, sound: 2), b = hc(2000, sound: 8), d = hc(3000);
      final c = _controller([a, b, d]);
      addTearDown(c.dispose);
      c.select(a);
      expect(c.resetSamples(), 1);
      expect(c.beatmap.hitObjects[1].hitSound, 8);
      expect(c.selection.single.hitSound, 0, reason: 'the selection follows the reset copies');
      c.clearSelection();
      expect(c.resetSamples(), 1);
      expect(c.beatmap.hitObjects.every((h) => h.hitSound == 0 && h.sample.isDefault), isTrue);
      expect(c.resetSamples(), 0);
      c.undo();
      expect(c.beatmap.hitObjects[1].hitSound, 8);
    });

    test('combo colours: skips go, new combos stay', () {
      final c = _controller([hc(1000, skip: 2), hc(2000)]);
      addTearDown(c.dispose);
      expect(c.resetComboColours(), 1);
      expect(c.beatmap.hitObjects.first.newCombo, isTrue);
      expect(c.beatmap.hitObjects.first.comboSkip, 0);
      expect(c.history.undoLabel, 'Reset combo colours');
    });
  });

  group('revert to saved', () {
    test('undoes back to the save point; redo brings the changes back', () {
      final c = _controller(const []);
      addTearDown(c.dispose);
      c.placeCircle(const Vec2(10, 10));
      c.history.markSaved();
      final saved = OsuWriter.write(c.beatmap);
      c.seek(2000);
      c.placeCircle(const Vec2(20, 20));
      c.setValues('x', [(SectionNames.metadata, 'Title', 'Changed')]);
      expect(c.canRevertInHistory, isTrue);
      expect(c.revertToSaved(), isTrue);
      expect(OsuWriter.write(c.beatmap), saved);
      expect(c.isDirty, isFalse);
      c.redo();
      expect(c.beatmap.hitObjects, hasLength(2));
    });

    test('a save point lost from the history must reopen the file', () {
      final c = _controller(const []);
      addTearDown(c.dispose);
      c.placeCircle(const Vec2(10, 10));
      c.history.markSaved();
      c.undo();
      c.placeCircle(const Vec2(30, 30)); // drops the redo branch holding the save point
      expect(c.canRevertInHistory, isFalse);
      expect(c.revertToSaved(), isFalse);
    });
  });

  group('[General] settings', () {
    test('changes show in Song setup and undo there', () {
      final c = _controller(const []);
      addTearDown(c.dispose);
      c.setValues('Song setup', [(SectionNames.general, 'StackLeniency', '0.3')]);
      expect(c.songSetupChanged('General.StackLeniency'), isTrue);
      expect(c.beatmap.stackLeniency, 0.3);
      c.undo();
      expect(c.lastHistoryStep.value!.focus.label, 'Change stack leniency');
      expect(c.songSetupChanged('General.StackLeniency'), isFalse);
    });
  });

  group('delete difficulty', () {
    late Directory temp;
    late BeatmapLibrary lib;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('osuedit_del_');
      lib = BeatmapLibrary(Directory(BeatmapLibrary.joinPath(temp.path, 'Songs')));
    });
    tearDown(() => temp.delete(recursive: true));

    Future<EditorController> open(String path) async {
      final opened = await const BeatmapFileService().openLibraryFile(path, File(path).parent.path);
      return EditorController(beatmap: OsuParser.parse(opened.text), document: opened.document, library: lib);
    }

    test('deletes this difficulty, never the last one', () async {
      final b = Beatmap.empty()
        ..setValue(SectionNames.metadata, 'Title', 'Set')
        ..setValue(SectionNames.metadata, 'Version', 'Easy');
      final first = await lib.createSet(b);
      final setPath = File(first.path).parent.path;
      var c = await open(first.path);
      expect(await c.setDifficultyCount(), 1);
      expect(await c.deleteThisDifficulty(), isFalse);
      final second = await c.createDifficulty('Hard');
      c.dispose();

      c = await open(second!);
      expect(await c.setDifficultyCount(), 2);
      expect(await c.deleteThisDifficulty(), isTrue);
      c.dispose();
      expect(File(second).existsSync(), isFalse);
      expect(File(first.path).existsSync(), isTrue);
      expect((await lib.readSet(setPath)).difficulties, hasLength(1));
    });

    test('refuses paths outside the library', () async {
      final outside = File('${temp.path}/x.osu')..writeAsStringSync('');
      expect(() => lib.deleteDifficulty(outside.path), throwsStateError);
      expect(outside.existsSync(), isTrue);
    });
  });
}
