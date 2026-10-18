import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';
import 'package:osu_edit/platform/beatmap_library.dart';
import 'package:osu_edit/platform/recovery_store.dart';

void main() {
  late Directory temp;
  late BeatmapLibrary lib;
  late RecoveryStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('osuedit_recovery_');
    lib = BeatmapLibrary(Directory(BeatmapLibrary.joinPath(temp.path, 'Songs')));
    store = RecoveryStore.besideLibrary(lib.root);
  });
  tearDown(() => temp.delete(recursive: true));

  test('write / read / clear, keyed by path, outside the library', () async {
    await store.write('/a/b.osu', 'text A');
    await store.write('/a/c.osu', 'text C');
    expect((await store.read('/a/b.osu'))!.text, 'text A');
    expect((await store.read('/a/c.osu'))!.text, 'text C');
    expect(await store.read('/a/x.osu'), isNull);
    expect(store.root.path, isNot(startsWith(lib.root.path)));
    await store.clear('/a/b.osu');
    expect(await store.read('/a/b.osu'), isNull);
    await store.clear('/a/b.osu'); // twice is fine
  });

  test('the controller autosaves unsaved edits and clears them on save / when undone', () async {
    final b = Beatmap.empty()..setValue(SectionNames.metadata, 'Title', 'T');
    b.insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
    final d = await lib.createSet(b);
    final opened = await const BeatmapFileService().openLibraryFile(d.path, File(d.path).parent.path);
    final c = EditorController(
      beatmap: OsuParser.parse(opened.text),
      document: opened.document,
      library: lib,
      recovery: store,
    );
    addTearDown(c.dispose);
    final path = c.document.path!;

    await c.autosave();
    expect(await store.read(path), isNull, reason: 'nothing unsaved');

    c.placeCircle(const Vec2(100, 100));
    await c.autosave();
    final rec = await store.read(path);
    expect(rec!.text, c.serialize());

    c.undo();
    await c.autosave();
    expect(await store.read(path), isNull, reason: 'undone back to the file');

    c.placeCircle(const Vec2(100, 100));
    await c.autosave();
    expect(await c.save(), isTrue);
    expect(await store.read(path), isNull, reason: 'saved');
  });

  test('a recovered map counts as unsaved', () {
    final c = EditorController(beatmap: Beatmap.empty(), document: const BeatmapDocument(fileName: 'x.osu'));
    addTearDown(c.dispose);
    expect(c.isDirty, isFalse);
    c.markRecovered();
    expect(c.isDirty, isTrue);
  });
}
