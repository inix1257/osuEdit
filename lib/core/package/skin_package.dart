import 'dart:convert';

import '../skin/skin_ini.dart';
import 'osz_codec.dart';

/// An `.osk` (zipped osu! skin) read for import.
class SkinPackage {
  /// Files relative to the skin folder (`/` separators).
  final List<PackageEntry> entries;
  final SkinIni ini;

  const SkinPackage(this.entries, this.ini);

  static const _images = ['png', 'jpg', 'jpeg'];
  static const _sounds = ['wav', 'mp3', 'ogg'];

  /// Unzips [bytes]. Skins zipped with their folder (`MySkin/skin.ini`) are
  /// unwrapped. Throws a [FormatException] if it isn't a zip or holds no
  /// skin (no skin.ini, no images and no sounds), or is a beatmap set.
  static SkinPackage decode(List<int> bytes) {
    List<PackageEntry> entries;
    try {
      entries = OszCodec.decode(bytes);
    } on FormatException {
      throw const FormatException('Not a valid .osk (zip) file');
    }
    entries = _unwrap(entries);
    if (entries.any((e) => e.path.toLowerCase().endsWith('.osu'))) {
      throw const FormatException('This is a beatmap set (.osz), not a skin');
    }
    bool has(List<String> exts) => entries.any((e) => exts.contains(_ext(e.path)));
    final iniEntry = entries.where((e) => e.path.toLowerCase() == 'skin.ini').firstOrNull;
    if (iniEntry == null && !has(_images) && !has(_sounds)) {
      throw const FormatException('The archive contains no skin files');
    }
    return SkinPackage(entries, iniEntry == null ? SkinIni.none : SkinIni.parse(decodeIni(iniEntry.bytes)));
  }

  /// Whether [entries] (an archive's files) look like a skin rather than a
  /// beatmap set: no `.osu`, but a skin.ini (possibly in one folder).
  static bool looksLikeSkin(List<PackageEntry> entries) {
    final files = _unwrap(entries);
    return !files.any((e) => e.path.toLowerCase().endsWith('.osu')) &&
        files.any((e) => e.path.toLowerCase() == 'skin.ini');
  }

  /// skin.ini text: UTF-8 (BOM dropped), else Latin-1.
  static String decodeIni(List<int> bytes) {
    var b = bytes;
    if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) b = b.sublist(3);
    try {
      return utf8.decode(b);
    } on FormatException {
      return latin1.decode(b);
    }
  }

  /// Strips a folder every file is in (repeatedly), unless skin.ini is at
  /// the top already.
  static List<PackageEntry> _unwrap(List<PackageEntry> entries) {
    var out = entries;
    while (out.isNotEmpty && !out.any((e) => !e.path.contains('/'))) {
      final first = out.first.path.substring(0, out.first.path.indexOf('/') + 1);
      if (!out.every((e) => e.path.startsWith(first))) break;
      out = [for (final e in out) PackageEntry(e.path.substring(first.length), e.bytes)];
    }
    return out;
  }

  static String _ext(String path) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  }
}
