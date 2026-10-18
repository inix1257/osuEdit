import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

/// Checks the generated slider test difficulty (tool/make_click_test_osz.py,
/// [Shapes]): every curve type is there, lengths are whole beat snaps and
/// never longer than the drawn path, and the editable point model
/// round-trips every slider.
void main() {
  final src = File('test/fixtures/slider_shapes_v14.osu').readAsStringSync();
  final b = OsuParser.parse(src);
  final timing = TimingInfo.of(b);
  final sm = b.sliderMultiplier;
  final sliders = b.hitObjects.whereType<SliderObject>().toList();

  test('round-trips byte-for-byte and has a background', () {
    expect(OsuWriter.write(b), src);
    expect(b.backgroundFilename, 'bg.jpg');
  });

  test('covers every curve type, red anchors, repeats and SV changes', () {
    expect({for (final s in sliders) s.curveType}, CurveType.values.toSet());
    expect(sliders.any((s) => SliderShape.decode(s.allPoints).any((p) => p.red)), isTrue);
    expect(sliders.any((s) => s.slides > 1), isTrue);
    expect({for (final s in sliders) timing.sliderVelocityAt(s.time)}, containsAll([0.5, 1.0, 2.0]));
    expect(b.hitObjects.whereType<Spinner>(), hasLength(1));
  });

  test('lengths are whole 1/4 snaps and fit the drawn path', () {
    for (final s in sliders) {
      final step = timing.sliderLengthStep(s.time, sm, 4);
      expect((s.length / step - (s.length / step).round()).abs(), lessThan(1e-6), reason: 'at ${s.time}');
      expect(SliderShape.fullLength(s.curveType, s.allPoints), greaterThanOrEqualTo(s.length - 0.5),
          reason: 'path shorter than length at ${s.time}');
      expect(timing.snapSliderLength(s.length, s.time, sm, 4), closeTo(s.length, 1e-6));
    }
  });

  test('editable points round-trip every slider', () {
    for (final s in sliders) {
      expect(SliderShape.encode(SliderShape.decode(s.allPoints)), s.allPoints);
    }
  });

  test('leaves the second half empty for drawing new objects', () {
    final end = timing.endTimeOf(b.hitObjects.last, sm);
    expect(end, lessThan(12000));
  });
}
