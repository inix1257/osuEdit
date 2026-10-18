import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

/// An ID3v2.[version] tag with [frames] (id → frame body) before fake audio.
Uint8List id3(int version, Map<String, List<int>> frames) {
  final body = <int>[];
  for (final e in frames.entries) {
    final size = e.value.length;
    body.addAll(e.key.codeUnits);
    if (version == 2) {
      body.addAll([size >> 16 & 0xFF, size >> 8 & 0xFF, size & 0xFF]);
    } else if (version == 3) {
      body.addAll([size >> 24 & 0xFF, size >> 16 & 0xFF, size >> 8 & 0xFF, size & 0xFF, 0, 0]);
    } else {
      body.addAll([size >> 21 & 0x7F, size >> 14 & 0x7F, size >> 7 & 0x7F, size & 0x7F, 0, 0]);
    }
    body.addAll(e.value);
  }
  body.addAll(List.filled(16, 0)); // padding
  final n = body.length;
  return Uint8List.fromList([
    0x49, 0x44, 0x33, version, 0, 0, //
    n >> 21 & 0x7F, n >> 14 & 0x7F, n >> 7 & 0x7F, n & 0x7F,
    ...body,
    0xFF, 0xFB, 0x90, 0x00,
  ]);
}

void main() {
  test('ID3v2.3 UTF-16 with BOM and v2.4 UTF-8', () {
    final utf16 = [1, 0xFF, 0xFE, for (final c in '夜に駆ける'.codeUnits) ...[c & 0xFF, c >> 8], 0, 0];
    final t3 = AudioTags.read(id3(3, {'TIT2': utf16, 'TPE1': [0, ...latin1.encode('YOASOBI')]}));
    expect(t3.title, '夜に駆ける');
    expect(t3.artist, 'YOASOBI');

    final t4 = AudioTags.read(id3(4, {'TPE1': [3, ...utf8.encode('Hana')], 'TIT2': [3, ...utf8.encode('Kuukirikigaku')]}));
    expect(t4.title, 'Kuukirikigaku');
    expect(t4.artist, 'Hana');
  });

  test('ID3v2.2 three-letter frames', () {
    final t = AudioTags.read(id3(2, {'TT2': [0, ...latin1.encode('Song')], 'TP1': [0, ...latin1.encode('Band')]}));
    expect((t.title, t.artist), ('Song', 'Band'));
  });

  test('ID3v1 at the end; nothing when untagged', () {
    final b = Uint8List(300);
    b.setAll(172, latin1.encode('TAG'));
    b.setAll(175, latin1.encode('Old Title'));
    b.setAll(205, latin1.encode('Old Artist'));
    final t = AudioTags.read(b);
    expect((t.title, t.artist), ('Old Title', 'Old Artist'));
    final none = AudioTags.read(Uint8List(50));
    expect((none.title, none.artist), ('', ''));
  });
}
