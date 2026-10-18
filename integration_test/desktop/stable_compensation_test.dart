// Desktop background check: the audio settings sheet has no stable timing
// slider; the fixed 20 ms map timing and the device latency switch sit under
// "Advanced", and the switch still works from there.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/stable_compensation_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/editor/audio_clock.dart';
import 'package:osu_edit/editor/editor_screen.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('fixed stable timing and advanced audio settings', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    expect(c.hasAudio, isTrue);
    expect(c.mapAudioOffsetMs, 20);
    final clock = c.clock as AudioClock;
    expect(clock.offset, c.effectiveOffsetMs + 20);

    await tester.tap(find.byTooltip('Menu'));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('Settings'));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('Audio settings…'));
    await settle(tester, const Duration(milliseconds: 600));
    expect(find.textContaining('Stable timing'), findsNothing);
    expect(find.text('Auto-correct device latency'), findsNothing, reason: 'collapsed under Advanced');
    // Offset, music volume, hitsound volume.
    expect(find.byType(Slider), findsNWidgets(3));
    await shot(tester, 'audio_sheet_collapsed');

    await tester.tap(find.text('Advanced'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(find.text('Auto-correct device latency'), findsOneWidget);
    expect(find.textContaining('Map timing: 20 ms (fixed)'), findsOneWidget);
    await tester.ensureVisible(find.textContaining('Map timing'));
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'audio_sheet_advanced');

    final wasOn = c.audioSettings.autoLatency;
    await tester.tap(find.text('Auto-correct device latency'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(c.audioSettings.autoLatency, !wasOn);
    expect(find.text('Auto-correct device latency'), findsOneWidget, reason: 'stays expanded after a rebuild');
    expect(c.mapAudioOffsetMs, 20);
  });
}
