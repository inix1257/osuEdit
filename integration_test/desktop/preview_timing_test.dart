// How long a song preview takes to start, per phase (prints), for a small
// and a large MP3. Real SoLoud at volume 0 (silent).
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/preview_timing_test.dart -d windows
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/platform/preview_audio.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('preview start time', (tester) async {
    final dir = projectPath('tool/test_set');
    final p = SoloudPreviewPlayer(volume: 0);
    final log = <String>[];
    SoloudPreviewPlayer.debugTimings = (phase, ms) => log.add('$phase ${ms.toStringAsFixed(1)}');
    addTearDown(() => SoloudPreviewPlayer.debugTimings = null);
    Future<double> start(String file, int at) async {
      log.clear();
      final sw = Stopwatch()..start();
      await tester.runAsync(() => p.play(dir, file, at));
      final ms = sw.elapsedMicroseconds / 1000;
      // ignore: avoid_print
      print('$file @$at: ${ms.toStringAsFixed(1)} ms  [${log.join(', ')}]  pos=${p.position}');
      return ms;
    }

    await start('audio.mp3', 9000); // warm up the engine
    await start('long_audio.mp3', 1000);
    expect(p.position, closeTo(1.0, 0.1));
    await start('audio.mp3', 9000);
    expect(p.position, closeTo(9.0, 0.1));
    await start('long_audio.mp3', 300000);
    expect(p.position, closeTo(300.0, 0.1));
    await start('audio.mp3', 20000);
    await tester.runAsync(p.stop);
  });
}
