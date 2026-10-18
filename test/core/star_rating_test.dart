import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

Beatmap _fixture(String name) => OsuParser.parse(OsuTextCodec.decode(File('test/fixtures/$name').readAsBytesSync()).$1);

void main() {
  // The port matched the osu! website to 4 decimals on all 280 ranked maps
  // checked whose file was identical to the website's (2026-10-13). These
  // pin its output so later changes to shared code (parser, slider paths)
  // can't drift it silently.
  test('fixtures keep their star ratings', () {
    expect(StarRating.of(_fixture('sample_v14.osu')), closeTo(1.3985, 1e-4));
    expect(StarRating.of(_fixture('slider_shapes_v14.osu')), closeTo(1.7209, 1e-4));
    expect(StarRating.of(_fixture('sync_test_v14.osu')), closeTo(6.3685, 1e-4));
  });

  test('only osu!standard maps are rated', () {
    final b = _fixture('sample_v14.osu')..setValue(SectionNames.general, 'Mode', '3');
    expect(StarRating.of(b), isNull);
  });

  test('maps with fewer than two objects are 0 stars', () {
    final b = Beatmap.empty();
    expect(StarRating.of(b), 0);
    b.hitObjects.add(const HitCircle(position: Vec2(256, 192), time: 1000));
    expect(StarRating.of(b), 0);
  });

  test('a faster stream rates higher', () {
    Beatmap stream(double gap) {
      final b = Beatmap.empty();
      for (var i = 0; i < 64; i++) {
        b.hitObjects.add(HitCircle(position: Vec2(200 + (i % 4) * 30, 192), time: 1000 + i * gap));
      }
      return b;
    }

    final slow = StarRating.of(stream(150))!, fast = StarRating.of(stream(75))!;
    expect(slow, greaterThan(0));
    expect(fast, greaterThan(slow));
  });

  test('the per-object curve is in stars: a uniform map sits near its star rating', () {
    final b = Beatmap.empty();
    for (var i = 0; i < 400; i++) {
      b.hitObjects.add(HitCircle(position: Vec2(150 + (i % 2) * 200, 192), time: 1000 + i * 150.0));
    }
    final a = StarRating.analyse(b)!;
    expect(a.strains, hasLength(399));
    final steady = a.strains.sublist(200);
    for (final s in steady) {
      expect(s, closeTo(a.stars, a.stars * 0.15), reason: 'stars ${a.stars}');
    }
  });
}
