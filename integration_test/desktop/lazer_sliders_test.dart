// Desktop background check: a set with osu!lazer-format sliders asks
// "convert to stable / keep lazer" when first opened; keeping it edits
// sliders the lazer way (curve type per control point from the long-press
// menu, handles coloured by type); converting rewrites the set's sliders in
// stable's format.
//
// Test data: python tool/make_click_test_osz.py --lazer
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/lazer_sliders_test.dart -d windows
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/playfield_transform.dart';
import 'package:osu_edit/editor/widgets/playfield_view.dart';

import 'harness.dart';

const _osz = 'tool/test_set/osuEdit lazer test.osz';

void main() {
  ensureDesktopBinding();

  /// Opens [Lazer] up to the format question.
  Future<void> openToQuestion(WidgetTester tester) async {
    await openSet(tester, 'Lazer Test');
    await tapDifficulty(tester, 'Lazer');
    await waitFor(tester, find.text('osu!lazer slider format'));
  }

  EditorController controllerOf(WidgetTester tester) => tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;

  /// Screen position of osu!pixel [p] on the playfield.
  Offset screen(WidgetTester tester, EditorController c, Vec2 p) {
    final rect = tester.getRect(find.byType(PlayfieldView));
    return rect.topLeft + PlayfieldTransform.fit(rect.size, c.playfieldZoom.value).toScreen(p);
  }

  testWidgets('keep lazer format: curve type per control point', (tester) async {
    final lib = await tempLibrary(osz: [_osz]);
    final setPath = (await tester.runAsync(lib.listSets))!.single.path;
    await pumpApp(tester, lib);
    await openToQuestion(tester);
    expect(find.textContaining('has 5 sliders'), findsOneWidget);
    await shot(tester, 'lazer_question');

    await tester.tap(find.text('Keep lazer format'));
    await waitFor(tester, find.byType(EditorScreen));
    await settle(tester, const Duration(seconds: 1));
    final c = controllerOf(tester);
    expect(c.lazerSliders, isTrue);
    expect(await tester.runAsync(() => lib.keepsLazerSliders(setPath)), isTrue);

    // Select the linear + half-circle slider at 1000 ms.
    c.seek(1000);
    await settle(tester, const Duration(milliseconds: 300));
    await tester.tapAt(screen(tester, c, const Vec2(64, 96)));
    await settle(tester, const Duration(milliseconds: 300));
    final s = c.editedSlider!;
    expect(s.pointTypes, [PathType.linear, PathType.perfectCurve, null, null]);
    await shot(tester, 'lazer_selected');

    // Long-press the arc's first point: the curve type menu.
    await tester.longPressAt(screen(tester, c, const Vec2(192, 96)));
    await settle(tester, const Duration(milliseconds: 400));
    expect(find.text('Inherit'), findsOneWidget);
    expect(find.text('Perfect'), findsOneWidget);
    expect(find.text('Remove point'), findsOneWidget);
    await shot(tester, 'lazer_type_menu');

    await tester.tap(find.text('Bezier'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(c.editedSlider!.pointTypes, [PathType.linear, PathType.bezier, null, null]);
    await shot(tester, 'lazer_type_bezier');

    // Inherit: one linear path again (stable can write that).
    await tester.longPressAt(screen(tester, c, const Vec2(192, 96)));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('Inherit'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(c.editedSlider!.pointTypes, [PathType.linear, null, null, null]);
    await shot(tester, 'lazer_type_inherit');
    c.undo();
    await settle(tester, const Duration(milliseconds: 300));
    expect(c.editedSlider!.pointTypes, [PathType.linear, PathType.bezier, null, null]);

    // Saved in lazer's syntax; the other sliders untouched.
    await tester.runAsync(c.save);
    final saved = File(c.document.path!).readAsStringSync();
    expect(saved, contains('64,96,1000,6,0,L|B|192:96|256:32|320:96,1,')); // shorter path: length re-snapped
    expect(saved, contains('64,352,3667,2,0,B4|128:256|192:352|256:256|320:352|384:256,1,280'));

    // Not asked again.
    await back(tester);
    await tapDifficulty(tester, 'Lazer');
    await waitFor(tester, find.byType(EditorScreen));
    expect(find.text('osu!lazer slider format'), findsNothing);
    expect(controllerOf(tester).lazerSliders, isTrue);
  });

  testWidgets('convert to stable: same shapes, stable syntax', (tester) async {
    final lib = await tempLibrary(osz: [_osz]);
    final setPath = (await tester.runAsync(lib.listSets))!.single.path;
    final file = Directory(setPath).listSync().whereType<File>().firstWhere((f) => f.path.endsWith('.osu'));
    final before = OsuParser.parse(file.readAsStringSync());
    await pumpApp(tester, lib);
    await openToQuestion(tester);
    await tester.tap(find.text('Convert to stable'));
    await waitFor(tester, find.byType(EditorScreen));
    await settle(tester, const Duration(seconds: 1));
    final c = controllerOf(tester);
    expect(c.lazerSliders, isFalse);
    expect(c.isDirty, isFalse); // converted on disk, not as an edit
    expect(SliderFormatOps.lazerSliders(c.beatmap), isEmpty);
    final text = file.readAsStringSync();
    for (final line in text.split('\r\n').where((l) => RegExp(r'^\d+,\d+,\d+,[26],').hasMatch(l))) {
      expect(LazerPath.isLazerCurve(line.split(',')[5]), isFalse, reason: line);
    }
    // Same ends (shapes are checked in the unit tests).
    final after = OsuParser.parse(text);
    for (var i = 0; i < before.hitObjects.length; i++) {
      final a = SliderPath.of(before.hitObjects[i] as SliderObject), b = SliderPath.of(after.hitObjects[i] as SliderObject);
      expect(b.tail.distanceTo(a.tail), lessThan(2), reason: 'slider $i');
    }
    c.seek(3667);
    await settle(tester, const Duration(milliseconds: 400));
    await shot(tester, 'lazer_converted_bspline');
    expect(await tester.runAsync(() => lib.keepsLazerSliders(setPath)), isFalse);
  });
}
