import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

/// Real-world beatmap check. Set `OSUEDIT_MAPS_DIR` to a folder of extracted
/// beatmap sets; every `.osu` below it is parsed and round-tripped.
void main() {
  final dir = Platform.environment['OSUEDIT_MAPS_DIR'];
  final files = dir == null
      ? <File>[]
      : Directory(dir)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.osu'))
          .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  if (files.isEmpty) {
    test('real maps (OSUEDIT_MAPS_DIR unset)', () {},
        skip: 'set OSUEDIT_MAPS_DIR to run');
    return;
  }

  for (final f in files) {
    group(f.uri.pathSegments.last, () {
      final bytes = f.readAsBytesSync();
      final (text, enc) = OsuTextCodec.decode(bytes);
      final warnings = <String>[];
      late final Beatmap b;

      setUpAll(() => b = OsuParser.parse(text, warnings: warnings));

      test('byte-exact round trip', () {
        expect(OsuTextCodec.encode(OsuWriter.write(b), enc), bytes);
      });

      test('canonical re-encode of every object keeps its values', () {
        for (final h in b.hitObjects) {
          final again = OsuParser.parseHitObject(OsuWriter.encodeHitObject(h))!;
          expect(again.runtimeType, h.runtimeType, reason: '${h.time}');
          expect(again.time, h.time);
          expect(again.position, h.position);
          if (h is SliderObject) {
            final s = again as SliderObject;
            expect(s.controlPoints, h.controlPoints, reason: '${h.time}');
            expect(s.slides, h.slides);
          }
        }
      });

      test('sliders resolve to finite paths; combos/timing consistent', () {
        final timing = TimingInfo.of(b);
        final sm = b.sliderMultiplier;
        for (final h in b.hitObjects.whereType<SliderObject>()) {
          final p = SliderPath.of(h);
          expect(p.vertices, isNotEmpty, reason: 'slider @${h.time}');
          for (final v in p.vertices) {
            expect(v.x.isFinite && v.y.isFinite, isTrue, reason: '${h.time}');
          }
          expect(timing.sliderEndTime(h, sm), greaterThanOrEqualTo(h.time));
        }
        expect(computeCombos(b.hitObjects), hasLength(b.hitObjects.length));
      });

      test('report', () {
        final types = <String, int>{};
        for (final h in b.hitObjects) {
          types.update(h.runtimeType.toString(), (n) => n + 1, ifAbsent: () => 1);
        }
        // ignore: avoid_print
        print('v${b.formatVersion} mode=${b.mode} '
            'timing=${b.timingPoints.length} objects=$types '
            'warnings=${warnings.length} ${warnings.take(3).toList()}');
      });
    });
  }
}
