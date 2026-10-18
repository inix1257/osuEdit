import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// 120 BPM, SV 1.4.
EditorController _controller(List<HitObject> objects) {
  final b = Beatmap.empty()
    ..setValue(SectionNames.difficulty, 'SliderMultiplier', '1.4')
    ..insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
  for (final h in objects) {
    b.insertHitObject(h);
  }
  b.revision = 0;
  return EditorController(beatmap: b, document: const BeatmapDocument(fileName: 'x.osu'));
}

HitObject _parse(String line) => OsuParser.parseHitObject(line)!;

void main() {
  test('a circle on a circle replaces it, keeping its hitsounds and new combo; one undo step', () {
    final old = _parse('100,100,1000,5,2,2:3:1:70:'); // NC, whistle, soft / drum, index 1, volume 70
    final c = _controller([_parse('50,50,500,1,0,0:0:0:0:'), old]);
    addTearDown(c.dispose);
    c.tool = EditorTool.circle;
    c.seek(1000);
    c.placeCircle(const Vec2(300, 300));
    final objs = c.beatmap.hitObjects;
    expect(objs, hasLength(2));
    expect(objs.contains(old), isFalse);
    expect(OsuWriter.encodeHitObject(objs[1]), '300,300,1000,5,2,2:3:1:70:');
    expect(c.history.undoLabel, 'Replace object');
    c.undo();
    expect(c.beatmap.hitObjects[1], same(old));
  });

  test('the toolbox sounds give way to the replaced object\'s', () {
    final c = _controller([_parse('100,100,1000,1,0,0:0:0:0:')]);
    addTearDown(c.dispose);
    c.tool = EditorTool.circle;
    c.toggleAddition(HitSoundFlags.clap);
    c.seek(1000);
    c.placeCircle(const Vec2(300, 300));
    expect(c.beatmap.hitObjects.single.hitSound, 0);
  });

  test('a circle on a slider head takes its head edge sound; mid-body is no match', () {
    final slider = _parse('100,100,1000,2,0,L|240:100,1,140,4|8,2:1|0:0,0:0:0:0:'); // head finish, soft:normal
    final c = _controller([slider]);
    addTearDown(c.dispose);
    c.tool = EditorTool.circle;
    c.seek(1250); // inside the body: added beside it
    c.placeCircle(const Vec2(300, 300));
    expect(c.beatmap.hitObjects, hasLength(2));
    c.undo();
    c.seek(1000);
    c.placeCircle(const Vec2(300, 300));
    final h = c.beatmap.hitObjects.single;
    expect(h, isA<HitCircle>());
    expect(h.hitSound, HitSoundFlags.finish);
    expect(h.sample.normalSet, SampleSet.soft);
    expect(h.sample.additionSet, SampleSet.normal);
  });

  test('a slider on a circle: the circle\'s sound becomes its head\'s', () {
    final c = _controller([_parse('100,100,1000,1,8,3:0:0:0:')]); // clap, drum
    addTearDown(c.dispose);
    c.seek(1000);
    c.tool = EditorTool.slider;
    c.sliderToolTap(const Vec2(100, 100));
    c.sliderToolTap(const Vec2(300, 100));
    c.finishSlider();
    final s = c.beatmap.hitObjects.single as SliderObject;
    expect(s.edgeSounds!.first, HitSoundFlags.clap);
    expect(s.edgeSounds!.skip(1).every((x) => x == 0), isTrue);
    expect(s.hitSound, 0);
    expect(s.sample.normalSet, SampleSet.drum);
  });

  test('a slider on a slider keeps all of its sounds', () {
    final old = _parse('100,100,1000,2,2,L|240:100,1,140,4|8,2:0|3:0,0:0:0:0:') as SliderObject;
    final c = _controller([old]);
    addTearDown(c.dispose);
    c.seek(1000);
    c.tool = EditorTool.slider;
    c.sliderToolTap(const Vec2(200, 200));
    c.sliderToolTap(const Vec2(400, 200));
    c.finishSlider();
    final s = c.beatmap.hitObjects.single as SliderObject;
    expect(s.hitSound, 2);
    expect(s.edgeSounds, [4, 8]);
    expect(s.edgeSets, const [EdgeSet(2, 0), EdgeSet(3, 0)]);
  });

  test('a spinner replaces too', () {
    final c = _controller([_parse('100,100,1000,1,4,0:0:0:0:')]);
    addTearDown(c.dispose);
    c.seek(1000);
    c.placeSpinner();
    final s = c.beatmap.hitObjects.single;
    expect(s, isA<Spinner>());
    expect(s.hitSound, HitSoundFlags.finish);
  });

  test('the preview shows the replacement: the old object hidden, numbers as after it', () {
    final a = _parse('50,50,500,5,0,0:0:0:0:'), b = _parse('100,100,1000,1,0,0:0:0:0:'), d = _parse('150,150,1500,1,0,0:0:0:0:');
    final c = _controller([a, b, d]);
    addTearDown(c.dispose);
    c.tool = EditorTool.circle;
    c.seek(1000);
    c.placementCursor = const Vec2(300, 300);
    expect(c.placementCollides, isTrue);
    expect(c.isBeingReplaced(b), isTrue);
    expect(c.placementGhostCombo!.number, 2);
    expect(c.shownComboOf(d).number, 3, reason: 'unchanged: the ghost takes 2\'s place');
  });
}
