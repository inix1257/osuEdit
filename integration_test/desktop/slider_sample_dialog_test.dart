// Desktop background check: long-pressing a slider's note on the Hitsound
// screen edits its timing point's sample index / volume (osu! ignores a
// slider's own), with a note saying so; a circle still gets its own.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/slider_sample_dialog_test.dart -d windows
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/render/hitsound_painter.dart';
import 'package:osu_edit/editor/widgets/editor_mode_button.dart';
import 'package:osu_edit/editor/widgets/hitsound_view.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  /// The Hitsound screen on a slider (2000) and a circle (4000), and the
  /// point of its Sampleset row under the playhead at [time].
  Future<(EditorController, Offset)> open(WidgetTester tester, double time) async {
    final text = File(projectPath('test/fixtures/sample_v14.osu')).readAsStringSync();
    final c = EditorController(
      beatmap: OsuParser.parse('${text.substring(0, text.indexOf('[HitObjects]'))}[HitObjects]\n'
          '100,100,2000,2,2,L|300:100,1,200,2|0,0:0|0:0,0:0:0:25:\n'
          '100,100,4000,1,0,0:0:0:0:\n'),
      document: const BeatmapDocument(fileName: 'slider_sample.osu'),
    );
    await pumpEditor(tester, c);
    await tester.tap(find.byType(EditorModeButton));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('Hitsound').last);
    await settle(tester);
    c.timelineZoom = 0.3;
    c.seek(time);
    await settle(tester, const Duration(milliseconds: 300));
    final rect = tester.getRect(find.byType(HitsoundTimeline));
    final g = HitsoundGeometry(rect.height);
    // The note blocks (head / circle) sit in the Sampleset row, at the playhead.
    return (c, Offset(rect.center.dx, rect.top + g.rowTop(HitsoundLayer.sampleSet) + g.rowHeight / 2));
  }

  testWidgets("a slider's long-press edits its timing point", (tester) async {
    final (c, at) = await open(tester, 2000);
    await tester.longPressAt(at);
    await settle(tester, const Duration(milliseconds: 500));
    final dialog = tester.widget<HitsoundSampleDialog>(find.byType(HitsoundSampleDialog));
    expect(dialog.object, isNull);
    expect(identical(dialog.point, c.timing.effectivePointAt(2005)), isTrue);
    expect(find.textContaining('Sliders use their timing point'), findsOneWidget);
    expect(find.text('Own volume'), findsNothing);
    await shot(tester, 'slider_sample_dialog');
  });

  testWidgets("a circle's long-press edits its own sample", (tester) async {
    final (_, at) = await open(tester, 4000);
    await tester.longPressAt(at);
    await settle(tester, const Duration(milliseconds: 500));
    expect(tester.widget<HitsoundSampleDialog>(find.byType(HitsoundSampleDialog)).object, isNotNull);
    expect(find.text('Own volume'), findsOneWidget);
    expect(find.textContaining('Sliders use'), findsNothing);
    await shot(tester, 'circle_sample_dialog');
  });
}
