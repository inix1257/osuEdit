import 'dart:convert';
import 'dart:typed_data';

/// How an .osu file's bytes were turned into text, so saving can turn the
/// text back into the *same* bytes.
enum OsuTextEncoding { utf8, latin1 }

/// Byte <-> text conversion for .osu files.
///
/// Almost every map is UTF-8 (optionally with BOM). Very old maps can contain
/// legacy code-page bytes that are not valid UTF-8; decoding those with
/// `allowMalformed` would replace them with U+FFFD and corrupt the file on
/// save. Instead we fall back to latin1, which maps every byte to one char,
/// so `encode(decode(b)) == b` for any input.
///
/// A UTF-8 BOM is kept as a leading U+FEFF (which `OsuParser` records as
/// `hasBom`); Dart's `utf8.decode` would silently drop it.
abstract final class OsuTextCodec {
  static (String, OsuTextEncoding) decode(List<int> bytes) {
    final bom = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
    try {
      final text = utf8.decode(bom ? bytes.sublist(3) : bytes);
      return (bom ? '﻿$text' : text, OsuTextEncoding.utf8);
    } on FormatException {
      return (latin1.decode(bytes), OsuTextEncoding.latin1);
    }
  }

  static Uint8List encode(String text, OsuTextEncoding encoding) =>
      switch (encoding) {
        OsuTextEncoding.utf8 => Uint8List.fromList(utf8.encode(text)),
        // Chars added in the editor that latin1 can't hold become '?'.
        OsuTextEncoding.latin1 =>
          Uint8List.fromList([for (final c in text.codeUnits) c > 0xFF ? 0x3F : c]),
      };
}
