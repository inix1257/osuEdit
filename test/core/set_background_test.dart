import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

void main() {
  test('replaces an existing background line in place, undo is byte-exact', () {
    final src = File('test/fixtures/sample_v14.osu').readAsStringSync();
    final b = OsuParser.parse(src);
    final h = EditHistory(b);
    h.execute(SetBackgroundCommand('new bg.png'));
    expect(b.backgroundFilename, 'new bg.png');
    final out = OsuWriter.write(b);
    expect(out, contains('//Background and Video events\r\n0,0,"new bg.png",0,0\r\n//Break Periods'));
    expect(out.replaceFirst('"new bg.png"', '"bg.jpg"'), src);
    h.undo();
    expect(OsuWriter.write(b), src);
  });

  test('keeps the offsets of the existing line', () {
    final b = OsuParser.parse('osu file format v14\r\n\r\n[Events]\r\n0,0,old.jpg,-20,15\r\n');
    SetBackgroundCommand('bg.jpg').apply(b);
    expect((b.sections.single as RawSection).lines.single, '0,0,"bg.jpg",-20,15');
  });

  test('adds a line under the comment of a new map', () {
    final b = Beatmap.empty();
    final before = OsuWriter.write(b);
    final cmd = SetBackgroundCommand('bg.jpg')..apply(b);
    expect(b.backgroundFilename, 'bg.jpg');
    expect(OsuWriter.write(b), contains('//Background and Video events\r\n0,0,"bg.jpg",0,0\r\n//Break Periods'));
    cmd.revert(b);
    expect(OsuWriter.write(b), before);
  });

  test('creates [Events] before [TimingPoints] if missing', () {
    const src = 'osu file format v14\r\n\r\n[General]\r\nMode: 0\r\n\r\n[TimingPoints]\r\n0,500,4,2,0,100,1,0\r\n';
    final b = OsuParser.parse(src);
    final cmd = SetBackgroundCommand('bg.jpg')..apply(b);
    expect([for (final s in b.sections) s.name], ['General', 'Events', 'TimingPoints']);
    expect(b.backgroundFilename, 'bg.jpg');
    cmd.revert(b);
    expect(OsuWriter.write(b), src);
  });
}
