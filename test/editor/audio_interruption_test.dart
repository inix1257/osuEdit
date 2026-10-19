import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/toast.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/platform/audio_session.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

void main() {
  testWidgets('an audio interruption pauses playback and says why', (tester) async {
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final b = Beatmap.empty()..insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
    final c = EditorController(beatmap: b, document: const BeatmapDocument(fileName: 'x.osu'));
    await tester.pumpWidget(MaterialApp(builder: (_, child) => ToastHost(child: child), home: EditorScreen(controller: c)));

    c.togglePlay();
    await tester.pump(const Duration(milliseconds: 100));
    expect(c.isPlaying, isTrue);

    AudioSession.instance.reportOutputFailure();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(c.isPlaying, isFalse);
    expect(find.text('Audio output unavailable; playback paused'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
