import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

/// 120 BPM from 0, AR 9 (preempt 600). Circles at 1000, 5000 and 5500, and
/// a break line for each test to play with.
String map(String breakLines) => 'osu file format v14\r\n'
    '\r\n'
    '[Difficulty]\r\n'
    'ApproachRate:9\r\n'
    '\r\n'
    '[Events]\r\n'
    '//Background and Video events\r\n'
    '0,0,"bg.jpg",0,0\r\n'
    '//Break Periods\r\n'
    '$breakLines'
    '//Storyboard Layer 0 (Background)\r\n'
    '\r\n'
    '[TimingPoints]\r\n'
    '0,500,4,2,0,100,1,0\r\n'
    '\r\n'
    '\r\n'
    '[HitObjects]\r\n'
    '100,100,1000,1,0,0:0:0:0:\r\n'
    '100,100,5000,1,0,0:0:0:0:\r\n'
    '100,100,5500,1,0,0:0:0:0:\r\n';

double endOf(HitObject h) => h.time;

void main() {
  test('parses breaks with their line index, sorted by start', () {
    final b = OsuParser.parse(map('2,3000,4000\r\nBreak,1200,2000\r\n'));
    expect([for (final p in b.breakPeriods) (p.start, p.end, p.lineIndex)], [(1200.0, 2000.0, 4), (3000.0, 4000.0, 3)]);
    expect(b.breaks, [(1200.0, 2000.0), (3000.0, 4000.0)]);
  });

  test("gaps get a break when lazer's would fit; it is as long as allowed", () {
    final b = OsuParser.parse(map(''));
    // 1000 + 200 .. 5000 - 450; 5000..5500 is too short.
    expect(BreakRules.insertable(b.hitObjects, endOf, b.breakPeriods, (_) => 600), [(1200.0, 4550.0)]);
    // The gap must be at least 200 + 650 + 450 = 1300 ms...
    expect(BreakRules.minGap, 1300);
    expect(BreakRules.suggested(1000, 2299, 450), isNull);
    expect(BreakRules.suggested(1000, 2300, 450), (1200.0, 1850.0));
    // ...and leave 650 ms before the next object's approach (preempt 600):
    // 1000 + 200 + 650 + 600 = 2450. The break still ends 450 before it.
    expect(BreakRules.suggested(1000, 2449, 600), isNull);
    expect(BreakRules.suggested(1000, 2450, 600), (1200.0, 2000.0));
    expect(BreakRules.suggested(1000.4, 2400.6, 450), (1201.0, 1950.0)); // rounded inwards

    final withBreak = OsuParser.parse(map('2,2000,3000\r\n'));
    expect(BreakRules.insertable(withBreak.hitObjects, endOf, withBreak.breakPeriods, (_) => 600), isEmpty);
  });

  test('lead-in is the preempt for osu!/catch, else two beats (at least 450)', () {
    expect(BreakRules.leadIn(mode: 0, preempt: 1200, beatLength: 500), 1200);
    expect(BreakRules.leadIn(mode: 2, preempt: 450, beatLength: 500), 450);
    expect(BreakRules.leadIn(mode: 3, preempt: 1200, beatLength: 500), 1000);
    expect(BreakRules.leadIn(mode: 1, preempt: 1200, beatLength: 200), 450);
  });

  test('regenerate drops automatic breaks, keeps valid manual ones, fills gaps', () {
    final b = OsuParser.parse(map('2,2000,3000\r\n' // automatic: replaced
        '2,4600,5200\r\n' // manual but overlaps the object at 5000: dropped
        '2,6000,7000\r\n')); // manual but after the last object: dropped
    final (kept, added) = BreakRules.regenerate(b.hitObjects, endOf, b.breakPeriods, (p) => p.start != 2000, (_) => 600);
    expect(kept, isEmpty);
    expect(added, [(1200.0, 4550.0)]);

    final m = OsuParser.parse(map('2,2000,3000\r\n'));
    final (kept2, added2) = BreakRules.regenerate(m.hitObjects, endOf, m.breakPeriods, (_) => true, (_) => 600);
    expect([for (final p in kept2) (p.start, p.end)], [(2000.0, 3000.0)]);
    expect(added2, isEmpty); // the gap's default would touch the kept break
  });

  test('replace swaps break lines in one step', () {
    final src = map('2,2000,3000\r\n');
    final b = OsuParser.parse(src);
    final h = EditHistory(b);
    h.execute(ReplaceBreaksCommand({b.breakPeriods.single.lineIndex}, [(1200, 4550), (100, 900)]));
    expect(OsuWriter.write(b), map('2,100,900\r\n2,1200,4550\r\n'));
    h.undo();
    expect(OsuWriter.write(b), src);
  });

  test("flags what lazer's Verify / editor would", () {
    final b = OsuParser.parse(map('2,1200,4400\r\n'
        '2,1100,2000\r\n' // 100 ms after the object at 1000
        '2,3000,4600\r\n' // 400 ms before the object at 5000
        '2,1199,4551\r\n' // within the 1 ms leniency
        '2,2000,2500\r\n' // too short
        '2,4600,5200\r\n' // object inside
        '2,6000,7000\r\n' // after the last object
        '2,0,700\r\n')); // before the first object (and too close to it)
    final got = {for (final p in b.breakPeriods) (p.start, p.end): BreakRules.issues(p, b.hitObjects, endOf)};
    expect(got, {
      (0.0, 700.0): {BreakIssue.outsideObjects, BreakIssue.endsLate},
      (1100.0, 2000.0): {BreakIssue.startsEarly},
      (1199.0, 4551.0): isEmpty,
      (1200.0, 4400.0): isEmpty,
      (2000.0, 2500.0): {BreakIssue.tooShort},
      (3000.0, 4600.0): {BreakIssue.endsLate},
      (4600.0, 5200.0): {BreakIssue.overlapsObject, BreakIssue.tooShort, BreakIssue.endsLate},
      (6000.0, 7000.0): {BreakIssue.outsideObjects},
    });
  });

  test('a break forces a new combo on the next object (display only)', () {
    final b = OsuParser.parse(map(''));
    expect([for (final c in computeCombos(b.hitObjects)) c.number], [1, 2, 3]);
    final combos = computeCombos(b.hitObjects, breakEnds: [4400]);
    expect([for (final c in combos) (c.number, c.colourIndex)], [(1, 1), (1, 2), (2, 2)]);
  });

  test('drag limits keep gaps to the objects and the minimum length', () {
    final b = OsuParser.parse(map('2,2000,3000\r\n'));
    final ((sLo, sHi), (eLo, eHi)) = BreakRules.limits(b.breakPeriods.single, b.hitObjects, endOf, b.breakPeriods);
    expect((sLo, sHi), (1200.0, 2350.0));
    expect((eLo, eHi), (2650.0, 4550.0));
  });

  test('add goes under the comment, in start order; undo is byte-exact', () {
    final src = map('');
    final b = OsuParser.parse(src);
    final h = EditHistory(b);
    h.execute(AddBreakCommand(3000, 4000));
    h.execute(AddBreakCommand(1200, 2000));
    expect(OsuWriter.write(b), map('2,1200,2000\r\n2,3000,4000\r\n'));
    h.undo();
    h.undo();
    expect(OsuWriter.write(b), src);
  });

  test('add creates [Events] when missing', () {
    const src = 'osu file format v14\r\n\r\n[General]\r\nMode: 0\r\n\r\n[TimingPoints]\r\n0,500,4,2,0,100,1,0\r\n';
    final b = OsuParser.parse(src);
    final cmd = AddBreakCommand(1000, 2000)..apply(b);
    expect([for (final s in b.sections) s.name], ['General', 'Events', 'TimingPoints']);
    expect(b.breaks, [(1000.0, 2000.0)]);
    cmd.revert(b);
    expect(OsuWriter.write(b), src);
  });

  test('set keeps the line kind and extra fields; remove and undo restore it', () {
    final src = map('Break,2000,3000,x\r\n');
    final b = OsuParser.parse(src);
    final h = EditHistory(b);
    final p = b.breakPeriods.single;
    h.execute(SetBreakCommand(p.lineIndex, 1500, 3500));
    expect(OsuWriter.write(b), map('Break,1500,3500,x\r\n'));
    h.execute(RemoveBreakCommand(p.lineIndex));
    expect(b.breaks, isEmpty);
    expect(OsuWriter.write(b), map(''));
    h.undo();
    h.undo();
    expect(OsuWriter.write(b), src);
  });

  test("background lightening follows lazer's break dim (0.3, 800 ms OutQuint)", () {
    final b = OsuParser.parse(map('2,2000,5000\r\n2,6000,6500\r\n'));
    final ps = b.breakPeriods;
    double at(double t) => BreakRules.lighteningAt(ps, t);
    expect(at(1999), 0);
    expect(at(2000), 0);
    expect(at(2400), closeTo(1 - 0.5 * 0.5 * 0.5 * 0.5 * 0.5, 1e-9)); // OutQuint(0.5)
    expect(at(2800), 1);
    expect(at(4675), 1); // until 325 ms before the end
    expect(at(5075), closeTo(1 - (1 - 0.5 * 0.5 * 0.5 * 0.5 * 0.5), 1e-9));
    expect(at(5475), 0);
    expect(at(6200), 0); // too short to have an effect
    // A short break: fades back from where it got to.
    final s = OsuParser.parse(map('2,2000,2725\r\n')).breakPeriods; // lightens until 2400
    expect(BreakRules.lighteningAt(s, 2400), closeTo(1 - 1 / 32, 1e-9));
    expect(BreakRules.lighteningAt(s, 2800), closeTo((1 - 1 / 32) * (1 / 32), 1e-9));
  });

  test('the intro and outro lighten like breaks (lazer: before GameplayStartTime, after completion)', () {
    const q = 1 - 1 / 32; // OutQuint(0.5)
    double at(double t) => BreakRules.lighteningAt(const [], t, introEnd: 0, outroStart: 10000);
    expect(at(-5000), 1);
    expect(at(0), 1);
    expect(at(400), closeTo(1 - q, 1e-9));
    expect(at(800), 0);
    expect(at(9999), 0);
    expect(at(10400), closeTo(q, 1e-9));
    expect(at(20000), 1);

    final b = OsuParser.parse(map('')); // first object at 1000, AR 9 (preempt 600)
    expect(BreakRules.introEnd(b.hitObjects.first, mode: 0, preempt: 600), -1000); // 2000 ms lead
    expect(BreakRules.introEnd(b.hitObjects.first, mode: 0, preempt: 2400), -1400); // longer preempt
    expect(BreakRules.introEnd(b.hitObjects.first, mode: 3, preempt: 2400), -1000);
  });
}
