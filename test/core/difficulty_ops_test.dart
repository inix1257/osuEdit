import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

void main() {
  late String src;
  late Beatmap b;

  setUp(() {
    src = File('test/fixtures/sample_v14.osu').readAsStringSync();
    b = OsuParser.parse(src.replaceFirst('//Break Periods\r\n', '//Break Periods\r\n2,4000,5000\r\n'));
  });

  test('derive: empty difficulty keeps timing, settings and background', () {
    final d = DifficultyOps.derive(b, version: 'Hard');
    expect(d.version, 'Hard');
    expect(d.hitObjects, isEmpty);
    expect(d.timingPoints.length, b.timingPoints.length);
    expect(d.timingPoints.first.sourceLine, b.timingPoints.first.sourceLine);
    expect(d.getValue(SectionNames.metadata, 'BeatmapID'), '0');
    expect(d.getValue(SectionNames.editor, 'Bookmarks'), isNull);
    expect(d.backgroundFilename, 'bg.jpg');
    expect(d.title, b.title);
    expect(d.circleSize, b.circleSize);
    final text = OsuWriter.write(d);
    expect(text, isNot(contains('2,4000,5000')));
    expect(text, contains('TitleUnicode:샘플 맵\r\n'));
    // The source map is untouched.
    expect(b.hitObjects, isNotEmpty);
    expect(b.version, 'Normal');
  });

  test('derive: duplicate keeps objects, breaks and bookmarks', () {
    final d = DifficultyOps.derive(b, version: 'Normal (copy)', keepObjects: true);
    expect(d.hitObjects.length, b.hitObjects.length);
    expect(d.hitObjects.first, isNot(same(b.hitObjects.first))); // independent copy
    expect(d.bookmarks, b.bookmarks);
    expect(OsuWriter.write(d), contains('2,4000,5000'));
    expect(DifficultyOps.fileNameOf(d), 'osuEdit - Sample Map (osuEdit) [Normal (copy)].osu');
  });

  test('applySetMetadata only rewrites changed keys', () {
    final other = OsuParser.parse(src);
    final values = DifficultyOps.setMetadataOf(b)..['Title'] = 'Renamed';
    expect(values.containsKey('Version'), isFalse);
    expect(DifficultyOps.applySetMetadata(other, values), isTrue);
    expect(other.title, 'Renamed');
    expect(OsuWriter.write(other), src.replaceFirst('Title:Sample Map', 'Title:Renamed'));
    expect(DifficultyOps.applySetMetadata(other, values), isFalse);
  });
}
