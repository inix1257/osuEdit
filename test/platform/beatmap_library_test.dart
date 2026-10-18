import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';
import 'package:osu_edit/platform/beatmap_library.dart';

void main() {
  final sampleBytes = Uint8List.fromList(File('test/fixtures/sample_v14.osu').readAsBytesSync());
  final sample = OsuParser.parse(utf8.decode(sampleBytes));

  /// A second difficulty with a BOM and LF line endings.
  final hardBytes = Uint8List.fromList([
    0xEF, 0xBB, 0xBF,
    ...utf8.encode(utf8
        .decode(sampleBytes)
        .replaceAll('\r\n', '\n')
        .replaceFirst(RegExp(r'Version:[^\n]*'), 'Version:Hard')),
  ]);

  final setEntries = [
    PackageEntry('normal.osu', sampleBytes),
    PackageEntry('hard.osu', hardBytes),
    PackageEntry('Audio.MP3', Uint8List.fromList(List.generate(4096, (i) => (i * 31) % 256))),
    PackageEntry('bg.jpg', Uint8List.fromList([0xFF, 0xD8, 0xFF, 1, 2, 3])),
    PackageEntry('sb/Layer/star.png', Uint8List.fromList([9, 8, 7])),
  ];

  late Directory temp;
  late BeatmapLibrary lib;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('osuedit_lib_');
    lib = BeatmapLibrary(Directory(BeatmapLibrary.joinPath(temp.path, 'Songs')),
        inboxes: [temp]);
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  Map<String, Uint8List> unzip(Uint8List osz) => {for (final e in OszCodec.decode(osz)) e.path: e.bytes};

  test('import → list → export keeps every file byte-identical', () async {
    final set = await lib.importOsz(OszCodec.encode(setEntries), fallbackName: 'ignored');
    final expectedFolder = BeatmapNaming.setFolderName(
        artist: sample.artist, title: sample.title, beatmapSetId: int.tryParse(sample.getValue('Metadata', 'BeatmapSetID') ?? ''));
    expect(set.folderName, expectedFolder);
    expect(set.difficulties.map((d) => d.summary.version).toSet(), {sample.version, 'Hard'});

    final sets = await lib.listSets();
    expect(sets.single.path, set.path);

    final out = unzip(await lib.exportOsz(set.path));
    expect(out.keys.toSet(), {for (final e in setEntries) e.path});
    for (final e in setEntries) {
      expect(out[e.path], e.bytes, reason: e.path);
    }
  });

  test('open → edit → save only changes the edited difficulty', () async {
    final set = await lib.importOsz(OszCodec.encode(setEntries));
    final hard = set.difficulties.firstWhere((d) => d.summary.version == 'Hard');
    const files = BeatmapFileService();

    // Untouched open + save reproduces the BOM / LF file exactly.
    var loaded = await files.openLibraryFile(hard.path, set.path);
    expect(loaded.document.isInLibrary, isTrue);
    var c = EditorController(beatmap: OsuParser.parse(loaded.text), document: loaded.document, library: lib);
    expect(c.canExportOsz, isTrue);
    expect(await c.save(), isTrue);
    expect(File(hard.path).readAsBytesSync(), hardBytes);
    c.dispose();

    // A real edit.
    loaded = await files.openLibraryFile(hard.path, set.path);
    c = EditorController(beatmap: OsuParser.parse(loaded.text), document: loaded.document, library: lib);
    c.select(c.beatmap.hitObjects.first);
    c.deleteSelection();
    expect(c.isDirty, isTrue);
    expect(await c.save(), isTrue);
    expect(c.isDirty, isFalse);
    final saved = File(hard.path).readAsBytesSync();
    expect(saved.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
    expect(OsuParser.parse(utf8.decode(saved.sublist(3))).hitObjects.length, sample.hitObjects.length - 1);
    expect(File('${hard.path}.tmp').existsSync(), isFalse);
    c.dispose();

    final out = unzip(await lib.exportOsz(set.path));
    expect(out['hard.osu'], saved);
    for (final e in setEntries.where((e) => e.path != 'hard.osu')) {
      expect(out[e.path], e.bytes, reason: e.path);
    }
  });

  test('importing the same set twice gets a distinct folder', () async {
    final osz = OszCodec.encode(setEntries);
    final a = await lib.importOsz(osz);
    final b = await lib.importOsz(osz);
    expect(b.folderName, '${a.folderName} (2)');
    expect((await lib.listSets()).length, 2);
  });

  test('archive without .osu is rejected and leaves nothing behind', () async {
    final osz = OszCodec.encode([PackageEntry('audio.mp3', Uint8List(10))]);
    await expectLater(lib.importOsz(osz), throwsA(isA<FormatException>()));
    expect(await lib.listSets(), isEmpty);
    expect(lib.root.existsSync() ? lib.root.listSync() : const [], isEmpty);
  });

  test('zip-slip entries are not written outside the set', () async {
    final a = Archive()
      ..add(ArchiveFile.bytes('map.osu', sampleBytes))
      ..add(ArchiveFile.bytes('../../escaped.txt', [1]));
    final set = await lib.importOsz(ZipEncoder().encodeBytes(a));
    expect(File(BeatmapLibrary.joinPath(temp.path, 'escaped.txt')).existsSync(), isFalse);
    expect(Directory(set.path).listSync().length, 1);
  });

  test('resolveFile matches case-insensitively, including subfolders', () async {
    final set = await lib.importOsz(OszCodec.encode(setEntries));
    expect(BeatmapLibrary.resolveFile(set.path, 'Audio.MP3')?.existsSync(), isTrue);
    expect(BeatmapLibrary.resolveFile(set.path, 'audio.mp3')?.readAsBytesSync(), setEntries[2].bytes);
    expect(BeatmapLibrary.resolveFile(set.path, r'SB\layer\STAR.png')?.readAsBytesSync(), [9, 8, 7]);
    expect(BeatmapLibrary.resolveFile(set.path, '"bg.jpg"'), isNotNull);
    expect(BeatmapLibrary.resolveFile(set.path, 'missing.ogg'), isNull);
    expect(BeatmapLibrary.resolveFile(set.path, '../normal.osu'), isNull);
  });

  test('createSet writes a new difficulty that opens and exports', () async {
    final b = Beatmap.empty()
      ..setValue(SectionNames.metadata, 'Title', 'Song')
      ..setValue(SectionNames.metadata, 'Artist', 'Me')
      ..setValue(SectionNames.metadata, 'Creator', 'Mapper')
      ..setValue(SectionNames.metadata, 'Version', 'Easy');
    final d = await lib.createSet(b);
    expect(d.fileName, 'Me - Song (Mapper) [Easy].osu');
    final sets = await lib.listSets();
    expect(sets.single.folderName, 'Me - Song');
    expect(sets.single.difficulties.single.summary.version, 'Easy');
    final out = unzip(await lib.exportOsz(sets.single.path));
    expect(utf8.decode(out[d.fileName]!), OsuWriter.write(b));
  });

  test('deleteSet removes the folder; refuses paths outside the library', () async {
    final set = await lib.importOsz(OszCodec.encode(setEntries));
    await expectLater(lib.deleteSet(LibrarySet(temp.path, const [])), throwsStateError);
    await lib.deleteSet(set);
    expect(await lib.listSets(), isEmpty);
  });

  test('pending .osz in an inbox are found and imported', () async {
    final f = File(BeatmapLibrary.joinPath(temp.path, 'dropped.osz'));
    await f.writeAsBytes(OszCodec.encode(setEntries));
    final pending = await lib.pendingImports();
    expect(pending.map((e) => e.path), [f.path]);
    await lib.importAndRemove(pending.single);
    expect(f.existsSync(), isFalse);
    expect((await lib.listSets()).single.difficulties.length, 2);
  });
  test('addFileToSet copies, reuses identical files, never overwrites others', () async {
    final set = await lib.importOsz(OszCodec.encode(setEntries));
    final song = Uint8List.fromList([1, 2, 3, 4]);
    expect(await lib.addFileToSet(set.path, 'song.mp3', song), 'song.mp3');
    expect(File(BeatmapLibrary.joinPath(set.path, 'song.mp3')).readAsBytesSync(), song);
    // Same bytes (any case) → reused; different bytes → new name.
    expect(await lib.addFileToSet(set.path, 'SONG.mp3', song), 'song.mp3');
    expect(await lib.addFileToSet(set.path, 'song.mp3', Uint8List.fromList([9])), 'song (2).mp3');
    // The imported audio is untouched.
    expect(await lib.addFileToSet(set.path, 'audio.mp3', Uint8List.fromList([7])), 'audio (2).mp3');
    expect(File(BeatmapLibrary.joinPath(set.path, 'Audio.MP3')).readAsBytesSync(), setEntries[2].bytes);
    // Only the base name is used; nothing escapes the set folder.
    expect(await lib.addFileToSet(set.path, '../../evil.png', song), 'evil.png');
    expect(Directory(set.path).listSync().whereType<File>().where((f) => f.path.endsWith('.tmp')), isEmpty);
  });

  test('renameStoryboard renames case-insensitively and never overwrites', () async {
    final set = await lib.importOsz(OszCodec.encode(setEntries));
    File p(String n) => File(BeatmapLibrary.joinPath(set.path, n));
    p('A - B (C).osb').writeAsStringSync('[Events]');
    expect(await lib.renameStoryboard(set.path, 'a - b (c).osb', 'X - B (C).osb'), isTrue);
    expect(p('X - B (C).osb').readAsStringSync(), '[Events]');
    expect(p('A - B (C).osb').existsSync(), isFalse);
    expect(await lib.renameStoryboard(set.path, 'missing.osb', 'Y.osb'), isFalse);
    p('Y.osb').writeAsStringSync('other');
    expect(await lib.renameStoryboard(set.path, 'X - B (C).osb', 'y.osb'), isFalse);
    expect(p('Y.osb').readAsStringSync(), 'other');
    expect(p('X - B (C).osb').existsSync(), isTrue);
  });

  group('osu!lazer slider format', () {
    const lazerSlider = '100,100,500,2,0,L|P|200:100|250:150|300:100,1,250';
    Uint8List withLazerSlider(Uint8List bytes) {
      final text = utf8.decode(bytes);
      const eol = '\r\n';
      final at = text.indexOf('[HitObjects]$eol') + '[HitObjects]$eol'.length;
      return Uint8List.fromList(utf8.encode('${text.substring(0, at)}$lazerSlider$eol${text.substring(at)}'));
    }

    test('count, convert (only those lines change) and the recorded choice', () async {
      final lazerBytes = withLazerSlider(sampleBytes);
      final set = await lib.importOsz(OszCodec.encode([PackageEntry('normal.osu', lazerBytes), ...setEntries.skip(1)]));
      expect(await lib.countLazerSliders(set.path), 1);
      expect(await lib.keepsLazerSliders(set.path), isNull);

      expect(await lib.convertSetToStable(set.path), 1);
      expect(await lib.countLazerSliders(set.path), 0);
      final normal = File(BeatmapLibrary.joinPath(set.path, 'normal.osu')).readAsStringSync();
      final before = utf8.decode(lazerBytes).split('\r\n'), after = normal.split('\r\n');
      expect(after.length, before.length);
      final changed = [for (var i = 0; i < before.length; i++) if (before[i] != after[i]) after[i]];
      expect(changed.single, startsWith('100,100,500,2,0,B|'));
      // The other difficulty is untouched.
      expect(File(BeatmapLibrary.joinPath(set.path, 'hard.osu')).readAsBytesSync(), hardBytes);

      await lib.setKeepsLazerSliders(set.path, true);
      expect(await lib.keepsLazerSliders(set.path), isTrue);
      await lib.setKeepsLazerSliders(set.path, false);
      expect(await lib.keepsLazerSliders(set.path), isFalse);
      // The record lives beside the sets, so it is never exported.
      expect(unzip(await lib.exportOsz(set.path)).keys, isNot(contains(endsWith('.json'))));
      expect((await lib.listSets()).length, 1);
      await lib.deleteSet((await lib.listSets()).single);
      expect(await lib.keepsLazerSliders(set.path), isNull);
    });
  });

  test('star ratings: pending, computed in the background, cached until the file changes', () async {
    final hard = File('test/fixtures/sync_test_v14.osu').readAsBytesSync();
    final set = await lib.importOsz(OszCodec.encode([
      PackageEntry('normal.osu', sampleBytes),
      PackageEntry('hard.osu', Uint8List.fromList(hard)),
    ]));
    var diffs = (await lib.listSets()).single.difficulties;
    expect(diffs.every((d) => d.starRatingPending && d.starRating == null), isTrue);

    expect(await lib.computeStarRatings(), 2);
    diffs = (await lib.listSets()).single.difficulties;
    final expected = [
      StarRating.of(sample)!,
      StarRating.of(OsuParser.parse(utf8.decode(hard)))!,
    ]..sort();
    expect(diffs.map((d) => d.starRating), expected, reason: 'sorted by star rating');
    expect(diffs.any((d) => d.starRatingPending), isFalse);
    expect((await lib.readSet(set.path)).difficulties.map((d) => d.starRating), expected);

    expect(await lib.computeStarRatings(), 0, reason: 'cached');

    // An edited file is rated again; the cache stays out of exports.
    final normal = File(BeatmapLibrary.joinPath(set.path, 'normal.osu'));
    await normal.writeAsString('${await normal.readAsString()}\n');
    diffs = (await lib.listSets()).single.difficulties;
    expect(diffs.where((d) => d.starRatingPending).map((d) => d.fileName), ['normal.osu']);
    expect(await lib.computeStarRatings(), 1);
    expect(unzip(await lib.exportOsz(set.path)).keys.toSet(), {'normal.osu', 'hard.osu'});
  });

  test('copyHitsounds writes only changed difficulties in their encoding; restoreFiles undoes it', () async {
    final set = await lib.importOsz(OszCodec.encode(setEntries));
    final normal = File(BeatmapLibrary.joinPath(set.path, 'normal.osu'));
    final hard = File(BeatmapLibrary.joinPath(set.path, 'hard.osu'));
    final hardBefore = await hard.readAsBytes();
    // The source: Normal with every hitsound gone (so Hard has to change).
    final source = OsuParser.parse(utf8.decode(await normal.readAsBytes()));
    final objs = source.hitObjects.toList();
    ReplaceHitObjectsCommand(objs, [for (final h in objs) ResetOps.withoutSamples(h) ?? h]).apply(source);

    final previous = await lib.copyHitsounds(source, [hard.path, normal.path], samplePoints: false);
    expect(previous.keys, [hard.path, normal.path], reason: 'both differ from the stripped source');
    final hardAfter = await hard.readAsBytes();
    expect(hardAfter.sublist(0, 3), [0xEF, 0xBB, 0xBF], reason: 'BOM kept');
    final copied = OsuParser.parse(utf8.decode(hardAfter.sublist(3)));
    expect(copied.hitObjects.every((h) => h.hitSound == 0), isTrue);
    expect(copied.version, 'Hard');

    await lib.restoreFiles(previous);
    expect(await hard.readAsBytes(), hardBefore);
    expect(await lib.copyHitsounds(OsuParser.parse(utf8.decode(sampleBytes)), [normal.path]), isEmpty,
        reason: 'the same map: nothing to write');
  });
}
