import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

void main() {
  final sampleBytes = File('test/fixtures/sample_v14.osu').readAsBytesSync();

  group('OsuTextCodec', () {
    test('utf8 file round-trips through parse/write byte-for-byte', () {
      final (text, enc) = OsuTextCodec.decode(sampleBytes);
      expect(enc, OsuTextEncoding.utf8);
      final out = OsuTextCodec.encode(OsuWriter.write(OsuParser.parse(text)), enc);
      expect(out, sampleBytes);
    });

    test('BOM is preserved', () {
      final bytes = [0xEF, 0xBB, 0xBF, ...sampleBytes];
      final (text, enc) = OsuTextCodec.decode(bytes);
      final b = OsuParser.parse(text);
      expect(b.hasBom, isTrue);
      expect(OsuTextCodec.encode(OsuWriter.write(b), enc), bytes);
    });

    test('invalid UTF-8 falls back to latin1 and keeps every byte', () {
      // "Title:" followed by Shift-JIS-ish bytes that are not valid UTF-8.
      final text = utf8.decode(sampleBytes).replaceFirst(RegExp(r'Title:[^\r\n]*'), 'Title:XX');
      final bytes = utf8.encode(text).toList();
      final at = String.fromCharCodes(bytes).indexOf('Title:XX') + 6;
      bytes[at] = 0x82;
      bytes[at + 1] = 0xA0;
      final (decoded, enc) = OsuTextCodec.decode(bytes);
      expect(enc, OsuTextEncoding.latin1);
      final out = OsuTextCodec.encode(OsuWriter.write(OsuParser.parse(decoded)), enc);
      expect(out, bytes);
    });
  });

  group('OszCodec', () {
    test('encode/decode keeps paths and bytes', () {
      final entries = [
        PackageEntry('map.osu', Uint8List.fromList(sampleBytes)),
        PackageEntry('audio.mp3', Uint8List.fromList(List.generate(5000, (i) => i * 7 % 256))),
        PackageEntry('sb/bg.png', Uint8List.fromList([1, 2, 3])),
        PackageEntry('empty.wav', Uint8List(0)),
      ];
      final decoded = OszCodec.decode(OszCodec.encode(entries));
      expect([for (final e in decoded) e.path], [for (final e in entries) e.path]);
      for (var i = 0; i < entries.length; i++) {
        expect(decoded[i].bytes, entries[i].bytes);
      }
    });

    test('normalizes separators and rejects unsafe paths', () {
      expect(OszCodec.normalizeEntryPath(r'sb\img.png'), 'sb/img.png');
      expect(OszCodec.normalizeEntryPath('./a//b.osu'), 'a/b.osu');
      expect(OszCodec.normalizeEntryPath('../evil.osu'), isNull);
      expect(OszCodec.normalizeEntryPath('a/../../evil'), isNull);
      expect(OszCodec.normalizeEntryPath('/etc/passwd'), isNull);
      expect(OszCodec.normalizeEntryPath(r'C:\Windows\x'), isNull);
      expect(OszCodec.normalizeEntryPath('__MACOSX/._a.osu'), isNull);
      expect(OszCodec.normalizeEntryPath('dir/.DS_Store'), isNull);
    });

    test('skips zip-slip entries, directories and case duplicates', () {
      final a = Archive()
        ..add(ArchiveFile.bytes('ok.osu', [1]))
        ..add(ArchiveFile.bytes('../escape.osu', [2]))
        ..add(ArchiveFile.directory('folder/'))
        ..add(ArchiveFile.bytes('OK.osu', [3]));
      final decoded = OszCodec.decode(ZipEncoder().encodeBytes(a));
      expect(decoded.map((e) => e.path), ['ok.osu']);
      expect(decoded.single.bytes, [1]);
    });

    test('garbage input is a FormatException', () {
      expect(() => OszCodec.decode([1, 2, 3, 4]), throwsFormatException);
    });
  });

  group('BeatmapNaming', () {
    test('sanitize strips illegal characters and reserved names', () {
      expect(BeatmapNaming.sanitize('a<b>:c"d/e\\f|g?h*i'), 'abcdefghi');
      expect(BeatmapNaming.sanitize('  trailing dots... '), 'trailing dots');
      expect(BeatmapNaming.sanitize(''), 'untitled');
      expect(BeatmapNaming.sanitize('CON'), '_CON');
      expect(BeatmapNaming.sanitize('x' * 200).length, 80);
    });

    test('stable-style file and folder names', () {
      expect(
        BeatmapNaming.osuFileName(artist: 'A', title: 'T', creator: 'C', version: 'Hard'),
        'A - T (C) [Hard].osu',
      );
      expect(BeatmapNaming.setFolderName(artist: 'A', title: 'T', beatmapSetId: 123), '123 A - T');
      expect(BeatmapNaming.setFolderName(artist: 'A', title: 'T', beatmapSetId: -1), 'A - T');
      expect(BeatmapNaming.setFolderName(artist: '', title: ''), 'Untitled set');
    });

    test('unique appends a counter case-insensitively', () {
      expect(BeatmapNaming.unique('a', ['b']), 'a');
      expect(BeatmapNaming.unique('a', ['A', 'a (2)']), 'a (3)');
    });
  });

  test('BeatmapSummary.scan reads header fields and counts objects', () {
    final text = utf8.decode(sampleBytes);
    final full = OsuParser.parse(text);
    final s = BeatmapSummary.scan(text);
    expect(s.title, full.title);
    expect(s.artist, full.artist);
    expect(s.creator, full.creator);
    expect(s.version, full.version);
    expect(s.mode, full.mode);
    expect(s.audioFilename, full.audioFilename);
    expect(s.hitObjectCount, full.hitObjects.length);
    expect(s.circleCount, full.hitObjects.whereType<HitCircle>().length);
    expect(s.sliderCount, full.hitObjects.whereType<SliderObject>().length);
    expect(s.spinnerCount, full.hitObjects.whereType<Spinner>().length);
    expect(s.circleCount + s.sliderCount + s.spinnerCount, s.hitObjectCount);
    expect(s.previewTime, int.tryParse(full.getValue(SectionNames.general, 'PreviewTime')?.trim() ?? '') ?? -1);
    expect(s.backgroundFile, full.backgroundFilename ?? '');
    expect(s.lastObjectTime, full.hitObjects.last.time.round());
    final bpms = [for (final p in full.timingPoints) if (p.uninherited) p.bpm];
    expect(s.minBpm, closeTo(bpms.reduce((a, b) => a < b ? a : b), 1e-9));
    expect(s.maxBpm, closeTo(bpms.reduce((a, b) => a > b ? a : b), 1e-9));
    expect(s.circleSize, full.circleSize);
    expect(s.approachRate, full.approachRate);
  });

  test('BeatmapSummary.scan: old maps without ApproachRate use OD', () {
    final s = BeatmapSummary.scan('[Difficulty]\r\nOverallDifficulty:7\r\n[TimingPoints]\r\n0,500,4,1,0,100,0,0\r\n');
    expect(s.approachRate, 7);
    // Inherited (uninherited = 0) points are not BPMs.
    expect(s.maxBpm, 0);
    expect(s.previewTime, -1);
  });

  test('BeatmapSummary.websiteUrl: set / difficulty page, none when unsubmitted', () {
    BeatmapSummary scan(String meta) => BeatmapSummary.scan('[General]\nMode:3\n[Metadata]\n$meta');
    expect(scan('BeatmapID:12\nBeatmapSetID:34').websiteUrl(), 'https://osu.ppy.sh/beatmapsets/34#mania/12');
    expect(scan('BeatmapID:0\nBeatmapSetID:34').websiteUrl(), 'https://osu.ppy.sh/beatmapsets/34');
    expect(scan('BeatmapID:0\nBeatmapSetID:-1').websiteUrl(), isNull);
    expect(scan('Title:x').websiteUrl(), isNull);
    expect(scan('BeatmapSetID:-1').websiteUrl(folderName: '7671 Artist - Title'), 'https://osu.ppy.sh/beatmapsets/7671');
    expect(scan('BeatmapSetID:-1').websiteUrl(folderName: 'Artist - Title'), isNull);
    expect(scan('BeatmapSetID:5').websiteUrl(folderName: '7671 Artist'), 'https://osu.ppy.sh/beatmapsets/5');
  });
}
