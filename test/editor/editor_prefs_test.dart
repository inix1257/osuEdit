import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/app_settings.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// sample_v14: object 1 a circle at (200,100); object 2 a bezier slider at
/// (300,150) with points (350,200), (300,250), length 140.
EditorController _sample({SettingsStore? settings}) => EditorController(
      beatmap: OsuParser.parse(File('test/fixtures/sample_v14.osu').readAsStringSync()),
      document: const BeatmapDocument(fileName: 'sample.osu'),
      settings: settings,
    );

void main() {
  late Directory temp;
  setUp(() async => temp = await Directory.systemTemp.createTemp('osuedit_prefs_'));
  tearDown(() => temp.delete(recursive: true));

  test('editing toggles are app settings: saved, and the next map starts with them', () async {
    final f = File('${temp.path}/settings.json');
    final store = await SettingsStore.load(f);
    final a = _sample(settings: store);
    addTearDown(a.dispose);
    expect([a.gridSnap, a.distanceSnap, a.lockNotes, a.scaleKeepsSliderShape], everyElement(isFalse));
    expect(a.pivot, TransformPivot.playfield);
    a
      ..gridSnap = true
      ..distanceSnap = true
      ..lockNotes = true
      ..pivot = TransformPivot.selection
      ..scaleKeepsSliderShape = true
      ..backgroundDim = 0.3
      ..showStoryboard = false;
    await store.save();

    // Another map, after a restart (a fresh read of the file).
    final b = _sample(settings: await SettingsStore.load(f));
    addTearDown(b.dispose);
    expect([b.gridSnap, b.distanceSnap, b.lockNotes, b.scaleKeepsSliderShape], everyElement(isTrue));
    expect(b.pivot, TransformPivot.selection);
    expect(b.backgroundDim, 0.3);
    expect(b.showStoryboard, isFalse);
  });

  test('default slider type: forced on new sliders, red anchors stay bezier, saved', () async {
    final f = File('${temp.path}/settings.json');
    final store = await SettingsStore.load(f);
    final c = _sample(settings: store);
    addTearDown(c.dispose);
    expect(c.defaultSliderType, DefaultSliderType.auto);

    CurveType drawn({bool red = false}) {
      for (final p in const [Vec2(100, 100), Vec2(200, 160), Vec2(300, 100)]) {
        c.sliderToolTap(p);
      }
      if (red) c.sliderToolTap(const Vec2(200, 160)); // toggles the middle point red
      c.sliderToolTap(const Vec2(400, 200));
      final type = c.draftSlider!.curveType;
      c.cancelSlider();
      return type;
    }

    // Automatic: four points → bezier.
    expect(drawn(), CurveType.bezier);
    for (final (t, expected) in [
      (DefaultSliderType.linear, CurveType.linear),
      (DefaultSliderType.catmull, CurveType.catmull),
      (DefaultSliderType.bezier, CurveType.bezier),
    ]) {
      c.defaultSliderType = t;
      expect(drawn(), expected, reason: '$t');
    }
    c.defaultSliderType = DefaultSliderType.linear;
    expect(drawn(red: true), CurveType.bezier);

    await store.save();
    final next = _sample(settings: await SettingsStore.load(f));
    addTearDown(next.dispose);
    expect(next.defaultSliderType, DefaultSliderType.linear);
  });

  test('keeping slider nodes also holds for the selection box / two-finger scaling', () {
    final c = _sample();
    addTearDown(c.dispose);
    final objs = [...c.beatmap.hitObjects];
    final s = objs[2] as SliderObject;
    c.select(objs[1]);
    c.select(s, additive: true);
    c.scaleKeepsSliderShape = true;
    const pivot = Vec2(256, 192);
    expect(c.beginTransform(), isTrue);
    // Scale 1.5 and a quarter turn clockwise.
    expect(c.updateFreeTransform(pivot: pivot, radians: math.pi / 2, scale: 1.5), isTrue);
    final t = c.selection.whereType<SliderObject>().single;
    Vec2 moved(Vec2 p) {
      final d = p - pivot;
      return Vec2(pivot.x - d.y * 1.5, pivot.y + d.x * 1.5).roundToInt();
    }

    expect(t.position, moved(s.position));
    // Nodes turned with it but not scaled: (+50,+50) → (−50,+50), (0,+100) → (−100,0).
    expect(t.controlPoints, [t.position + const Vec2(-50, 50), t.position + const Vec2(-100, 0)]);
    expect(t.length, s.length);
    expect(c.selection.firstWhere((h) => h is! SliderObject).position, moved(objs[1].position));

    // Off: the slider scales too.
    c.scaleKeepsSliderShape = false;
    c.updateFreeTransform(pivot: pivot, radians: math.pi / 2, scale: 1.4);
    final u = c.selection.whereType<SliderObject>().single;
    expect(u.controlPoints.first - u.position, const Vec2(-70, 70));
    expect(u.length, isNot(s.length));
    c.endTransform(apply: false);
  });
}
