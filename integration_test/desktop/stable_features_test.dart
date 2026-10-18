// Desktop background check of the stable-editor features: slider edge
// hitsounds picked on the timeline, the stable curve type / red anchor
// point menu, follow points, combo colours in Song setup.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/stable_features_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/playfield_transform.dart';
import 'package:osu_edit/editor/render/timeline_painter.dart';
import 'package:osu_edit/editor/widgets/editor_mode_button.dart';
import 'package:osu_edit/editor/widgets/playfield_view.dart';
import 'package:osu_edit/editor/widgets/timeline_view.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  EditorController controllerOf(WidgetTester tester) => tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;

  Offset onPlayfield(WidgetTester tester, EditorController c, Vec2 p) {
    final rect = tester.getRect(find.byType(PlayfieldView));
    return rect.topLeft + PlayfieldTransform.fit(rect.size, c.playfieldZoom.value).toScreen(p);
  }

  Offset onTimeline(WidgetTester tester, EditorController c, double t) {
    final rect = tester.getRect(find.byType(TimelineView));
    return Offset(rect.left + TimelinePainter.xOf(t, c.time.value, c.timelineZoom, rect.width), rect.center.dy);
  }

  testWidgets('stable editor features', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Shapes');
    final c = controllerOf(tester);

    // --- Follow points between slider 2 (ends at 256,192) and slider 3.
    c.seek(2050);
    await settle(tester, const Duration(milliseconds: 300));
    expect(c.followConnectionsAt(2050), isNotEmpty);
    await shot(tester, 'stable_follow_points');

    // --- Edge hitsounds: the 3-repeat slider at 4333 (edges every 166.7 ms).
    c.seek(4333);
    await settle(tester, const Duration(milliseconds: 300));
    await tester.tapAt(onPlayfield(tester, c, const Vec2(352, 320)));
    await settle(tester, const Duration(milliseconds: 300));
    final s = c.editedSlider!;
    expect(s.slides, 3);
    final edges = c.edgeTimes(s);
    await tester.tapAt(onTimeline(tester, c, edges[2]));
    await settle(tester, const Duration(milliseconds: 300));
    expect(c.selectedEdge, 2);
    expect(find.text('Slider repeat 2'), findsOneWidget);
    await tester.tap(find.text('Whistle'));
    await settle(tester, const Duration(milliseconds: 300));
    expect(c.editedSlider!.edgeSounds, [0, 0, 2, 0]);
    expect(c.selectedEdge, 2);
    await shot(tester, 'stable_edge_whistle');
    // Tapping the picked edge again: back to the whole slider.
    await tester.tapAt(onTimeline(tester, c, edges[2]));
    await settle(tester, const Duration(milliseconds: 300));
    expect(c.selectedEdge, isNull);
    expect(find.text('1 selected'), findsOneWidget);
    c.undo();
    await settle(tester, const Duration(milliseconds: 300));

    // --- Stable point menu on the 4-point bezier at 3667.
    c.seek(3667);
    await settle(tester, const Duration(milliseconds: 300));
    await tester.tapAt(onPlayfield(tester, c, const Vec2(96, 320)));
    await settle(tester, const Duration(milliseconds: 300));
    expect(c.editedSlider!.time, 3667);
    await tester.longPressAt(onPlayfield(tester, c, const Vec2(160, 256)));
    await settle(tester, const Duration(milliseconds: 400));
    expect(find.text('Bezier'), findsOneWidget);
    expect(find.text('Catmull'), findsOneWidget);
    expect(find.text('Linear'), findsOneWidget);
    expect(find.text('Perfect'), findsNothing); // four points
    expect(find.text('Red anchor'), findsOneWidget);
    expect(find.text('Remove point'), findsOneWidget);
    await shot(tester, 'stable_point_menu');
    await tester.tap(find.text('Red anchor'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(c.isRedAnchor(1), isTrue);
    await shot(tester, 'stable_red_anchor');
    await tester.longPressAt(onPlayfield(tester, c, const Vec2(160, 256)));
    await settle(tester, const Duration(milliseconds: 400));
    expect(find.text('Unset red anchor'), findsOneWidget);
    await tester.tap(find.text('Catmull'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(c.editedSlider!.curveType, CurveType.catmull);
    expect(c.isRedAnchor(1), isFalse);
    await shot(tester, 'stable_catmull');
    c.undo();
    c.undo();
    await settle(tester, const Duration(milliseconds: 300));

    // --- Combo colours in Song setup.
    await tester.tap(find.byType(EditorModeButton));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('Song setup').last);
    await settle(tester, const Duration(milliseconds: 600));
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await settle(tester, const Duration(milliseconds: 400));
    expect(find.text('COLOURS'), findsOneWidget);
    await shot(tester, 'stable_colours_default');
    await tester.tap(find.byTooltip('Add combo colour'));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.enterText(find.widgetWithText(TextField, 'Hex'), 'FF00FF');
    await settle(tester, const Duration(milliseconds: 200));
    await shot(tester, 'stable_colour_dialog');
    await tester.tap(find.text('OK'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(c.mapComboColours, hasLength(5));
    expect(c.mapComboColours.last, const RgbColour(255, 0, 255));
    expect(c.songSetupChanged('Colours.Combo'), isTrue);
    await shot(tester, 'stable_colours_added');
    // Edit swatch 1.
    await tester.tap(find.text('1').last);
    await settle(tester, const Duration(milliseconds: 400));
    expect(find.text('Combo 1'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(c.mapComboColours, hasLength(4));
    c.undo();
    c.undo();
    await settle(tester, const Duration(milliseconds: 400));
    expect(c.mapComboColours, isEmpty);
    expect(c.isDirty, isFalse);
  });
}
