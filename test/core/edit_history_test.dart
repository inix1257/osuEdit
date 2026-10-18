import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

void main() {
  late String src;
  late Beatmap b;
  late EditHistory h;

  setUp(() {
    src = File('test/fixtures/sample_v14.osu').readAsStringSync();
    b = OsuParser.parse(src);
    h = EditHistory(b);
  });

  test('add / undo / redo', () {
    const c = HitCircle(position: Vec2(1, 2), time: 1200);
    h.execute(AddHitObjectsCommand([c]));
    expect(b.hitObjects[1], same(c)); // sorted insert
    expect(h.isDirty, isTrue);
    h.undo();
    expect(b.hitObjects.contains(c), isFalse);
    expect(OsuWriter.write(b), src);
    expect(h.isDirty, isFalse);
    h.redo();
    expect(b.hitObjects[1], same(c));
  });

  test('replace keeps sort order when objects pass each other', () {
    final first = b.hitObjects[0];
    final moved = first.shiftedInTime(500); // 1000 → 1500
    h.execute(ReplaceHitObjectsCommand([first], [moved]));
    expect(b.hitObjects.map((e) => e.time).toList(),
        orderedEquals([...b.hitObjects.map((e) => e.time)]..sort()));
    expect(b.hitObjects[1], same(moved));
    h.undo();
    expect(b.hitObjects[0], same(first));
    expect(OsuWriter.write(b), src);
  });

  test('transaction undoes as one step', () {
    var cur = b.hitObjects[0];
    h.beginTransaction('Move');
    for (var i = 0; i < 10; i++) {
      final next = cur.translated(const Vec2(1, 0));
      h.execute(ReplaceHitObjectsCommand([cur], [next]));
      cur = next;
    }
    h.commitTransaction();
    expect(b.hitObjects[0].position.x, 110);
    expect(h.undoLabel, 'Move');
    h.undo();
    expect(OsuWriter.write(b), src);
    expect(h.canUndo, isFalse);
  });

  test('cancelled transaction rolls back', () {
    h.beginTransaction('Delete');
    h.execute(RemoveHitObjectsCommand([b.hitObjects[0], b.hitObjects[1]]));
    h.cancelTransaction();
    expect(OsuWriter.write(b), src);
    expect(h.canUndo, isFalse);
  });

  test('set value restores the original raw line', () {
    h.execute(SetValueCommand(SectionNames.difficulty, 'CircleSize', '5'));
    expect(b.circleSize, 5);
    h.undo();
    expect(OsuWriter.write(b), src);
    h.execute(SetValueCommand(SectionNames.metadata, 'NewKey', 'x'));
    h.undo();
    expect(OsuWriter.write(b), src);
  });

  test('timing point commands', () {
    final tp = b.timingPoints[1];
    h.execute(RemoveTimingPointCommand(tp));
    expect(b.timingPoints, hasLength(3));
    h.undo();
    expect(b.timingPoints[1], same(tp));
    h.execute(ReplaceTimingPointCommand(tp, tp.copyWith(volume: 10)));
    expect(b.timingPoints[1].volume, 10);
    h.undo();
    expect(OsuWriter.write(b), src);
  });

  test('dirty state survives undo past save point', () {
    h.execute(AddHitObjectsCommand([const HitCircle(position: Vec2.zero, time: 0)]));
    h.markSaved();
    expect(h.isDirty, isFalse);
    h.undo();
    expect(h.isDirty, isTrue);
    h.execute(AddHitObjectsCommand([const HitCircle(position: Vec2.zero, time: 1)]));
    expect(h.isDirty, isTrue); // saved state is no longer reachable
    h.undo();
    expect(h.isDirty, isTrue);
  });

  test('revision bumps on every change', () {
    final r0 = b.revision;
    h.execute(AddHitObjectsCommand([const HitCircle(position: Vec2.zero, time: 0)]));
    expect(b.revision, greaterThan(r0));
    final r1 = b.revision;
    h.undo();
    expect(b.revision, greaterThan(r1));
  });
}
