import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/render/playfield_painter.dart';
import 'package:osu_edit/editor/render/storyboard_renderer.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';
import 'package:osu_edit/platform/storyboard_loader.dart';

/// Storyboard load / draw cost on a real map (opt-in):
///   `OSUEDIT_SB_BENCH=(extracted set folder) flutter test test/platform/storyboard_bench_test.dart`
/// Prints load time, sprite / texture counts, decoded texture memory and the
/// per-frame paint (display-list recording) time sampled over the song.
void main() {
  final dir = Platform.environment['OSUEDIT_SB_BENCH'];

  testWidgets('storyboard benchmark', (tester) async {
    await tester.runAsync(() async {
      final osu = Directory(dir!).listSync().whereType<File>().firstWhere((f) => f.path.endsWith('.osu'));
      final beatmap = OsuParser.parse(OsuTextCodec.decode(osu.readAsBytesSync()).$1);

      final rss0 = ProcessInfo.currentRss;
      final sw = Stopwatch()..start();
      final sb = (await loadStoryboard(dir, beatmap))!;
      final loadMs = sw.elapsedMilliseconds;
      final rss1 = ProcessInfo.currentRss;
      var texBytes = 0;
      for (final t in sb.textures.values) {
        texBytes += t.image.width * t.image.height * 4;
      }
      final sprites = sb.storyboard.sprites;
      final commands = sprites.fold<int>(
          0, (n, s) => n + s.opacity.length + s.x.length + s.y.length + s.scale.length + s.rotation.length);
      // ignore: avoid_print
      print('load ${loadMs}ms, ${sprites.length} sprites, $commands commands, ${sb.textures.length} textures '
          '(${(texBytes / 1e6).toStringAsFixed(1)} MB decoded), RSS +${((rss1 - rss0) / 1e6).toStringAsFixed(0)} MB');

      final c = EditorController(
        beatmap: beatmap,
        document: BeatmapDocument(fileName: 'x.osu', setPath: dir),
        storyboardLoader: (_, _) async => sb,
      );
      await c.storyboardLoaded;
      final end = beatmap.hitObjects.isEmpty ? 60000.0 : beatmap.hitObjects.last.time + 5000;
      final times = <(double, double, int)>[];
      var maxCalls = 0, maxCallsSprites = 0, calls = 0, drawn = 0, singles = 0;
      const size = ui.Size(1600, 900);
      final painter = PlayfieldPainter(c);
      for (var t = 0.0; t < end; t += 250) {
        c.time.value = t;
        var visible = 0;
        sb.storyboard.forEachAlive(t, (_, s) {
          if (s.stateAt(t) != null) visible++;
        });
        final rec = ui.PictureRecorder();
        final w = Stopwatch()..start();
        painter.paint(ui.Canvas(rec), size);
        final ms = w.elapsedMicroseconds / 1000;
        rec.endRecording().dispose();
        times.add((t, ms, visible));
        calls += StoryboardRenderer.debugDrawCalls;
        drawn += StoryboardRenderer.debugSprites;
        singles += StoryboardRenderer.debugSingles;
        if (StoryboardRenderer.debugDrawCalls > maxCalls) {
          maxCalls = StoryboardRenderer.debugDrawCalls;
          maxCallsSprites = StoryboardRenderer.debugSprites;
        }
      }
      final sorted = [for (final e in times) e.$2]..sort();
      final worst = times.reduce((a, b) => a.$2 >= b.$2 ? a : b);
      final busiest = times.reduce((a, b) => a.$3 >= b.$3 ? a : b);
      double pct(double p) => sorted[((sorted.length - 1) * p).round()];
      // ignore: avoid_print
      print('paint over ${times.length} frames: p50 ${pct(.5).toStringAsFixed(2)} p95 ${pct(.95).toStringAsFixed(2)} '
          'p99 ${pct(.99).toStringAsFixed(2)} max ${worst.$2.toStringAsFixed(2)} ms (at ${worst.$1.round()} ms, '
          '${worst.$3} visible); most visible ${busiest.$3} at ${busiest.$1.round()} ms (${busiest.$2.toStringAsFixed(2)} ms)');
      // ignore: avoid_print
      print('draw calls: $calls ($singles single) for $drawn sprites drawn in total; worst frame $maxCalls calls for $maxCallsSprites sprites');
      c.dispose();
      sb.dispose();
    });
  }, skip: dir == null, timeout: const Timeout(Duration(minutes: 10)));
}
