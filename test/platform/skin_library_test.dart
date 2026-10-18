import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';
import 'package:osu_edit/platform/beatmap_library.dart';
import 'package:osu_edit/platform/skin_library.dart';

/// `tool/make_click_test_osz.py --skin`: zipped inside a folder, digits
/// under a `numbers\num` prefix, two slider ball frames, two follow point
/// frames, skin.ini colours.
final _testSkin = File('tool/test_set/osuEdit test skin.osk');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late BeatmapLibrary songs;
  late SkinLibrary skins;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('osuedit_skins_');
    songs = BeatmapLibrary(Directory(BeatmapLibrary.joinPath(temp.path, 'Songs')), inboxes: [temp]);
    skins = SkinLibrary.beside(songs);
  });

  tearDown(() async {
    await SkinManager.instance.reset();
    await temp.delete(recursive: true);
  });

  test('import, list, select, delete', () async {
    expect(skins.root.path, BeatmapLibrary.joinPath(temp.path, 'Skins'));
    final bytes = await _testSkin.readAsBytes();
    final a = await skins.importOsk(bytes, fallbackName: 'file name');
    expect(a.name, 'osuEdit Test Skin');
    expect(a.folder, 'osuEdit Test Skin');
    expect(File(BeatmapLibrary.joinPath(a.path, 'skin.ini')).existsSync(), isTrue, reason: 'unwrapped');
    final b = await skins.importOsk(bytes);
    expect(b.folder, 'osuEdit Test Skin (2)');
    expect([for (final s in await skins.list()) s.folder], ['osuEdit Test Skin', 'osuEdit Test Skin (2)']);

    await skins.writeSelection(b.folder);
    expect(await skins.readSelection(), b.folder);
    await skins.delete(b);
    expect(await skins.readSelection(), isNull, reason: 'deleting the selected skin clears the selection');
    expect([for (final s in await skins.list()) s.folder], ['osuEdit Test Skin']);
  });

  test('a beatmap set is not a skin', () async {
    final osz = OszCodec.encode([PackageEntry('a.osu', File('test/fixtures/sample_v14.osu').readAsBytesSync())]);
    expect(() => skins.importOsk(osz), throwsFormatException);
    expect(await skins.list(), isEmpty);
  });

  test('inbox .osk files are pending imports', () async {
    await _testSkin.copy(BeatmapLibrary.joinPath(temp.path, 'shared.osk'));
    final pending = await songs.pendingImports();
    expect([for (final f in pending) f.uri.pathSegments.last], ['shared.osk']);
    final skin = await skins.importAndRemove(pending.single);
    expect(skin.name, 'osuEdit Test Skin');
    expect(await songs.pendingImports(), isEmpty);
  });

  test('loads textures (@2x, frames, prefixed digits) and applies through SkinManager', () async {
    final info = await skins.importOsk(await _testSkin.readAsBytes());
    final manager = SkinManager.instance;
    await manager.attach(skins);
    expect(manager.current.value, isNull, reason: 'nothing selected yet');
    await manager.select(info);
    final skin = manager.current.value!;
    expect(manager.selected, info.folder);
    expect(await skins.readSelection(), info.folder, reason: 'remembered');

    final circle = skin['hitcircle']!;
    expect(circle.scale, 2, reason: '@2x');
    expect(circle.width, 128);
    expect(skin['approachcircle']!.scale, 1);
    expect(skin.frames('sliderb', separator: '').length, 2);
    expect(skin.frames('followpoint').length, 2);
    expect(skin.frames('sliderfollowcircle').length, 1, reason: 'a single image');
    expect(skin.frames('cursor'), isEmpty);
    expect(skin.digits, hasLength(10), reason: 'numbers/num-0..9');
    expect(skin.ini.hitCircleOverlap, 6);

    // Combo / slider colours fall back to the skin's when the map has none.
    final c = EditorController(
      // The sample map without its own combo colours.
      beatmap: OsuParser.parse(
          File('test/fixtures/sample_v14.osu').readAsStringSync().replaceAll(RegExp(r'Combo\d[^\n]*\n'), '')),
      document: const BeatmapDocument(fileName: 'x.osu'),
    );
    addTearDown(c.dispose);
    expect(ComboColours.of(c.beatmap), isEmpty);
    expect(c.comboColourAt(0), const Color(0xFFAA3CFF));
    expect(c.sliderBorderColour, const Color(0xFFFF3C3C));
    var notified = 0;
    c.addListener(() => notified++);
    await manager.select(null);
    expect(manager.current.value, isNull);
    expect(notified, greaterThan(0), reason: 'the editor repaints with the new skin');
    expect(c.sliderBorderColour, isNull);
    expect(c.comboColourAt(0), EditorController.defaultComboColours[0]);
  });
}
