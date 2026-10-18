import 'dart:typed_data';

import 'package:archive/archive.dart';

/// One file inside a beatmap set: [path] is relative to the set folder and
/// always uses `/` separators.
class PackageEntry {
  final String path;
  final Uint8List bytes;
  const PackageEntry(this.path, this.bytes);
}

/// `.osz` (zip) encode / decode. Pure Dart; run it off the UI isolate for
/// real-sized archives.
abstract final class OszCodec {
  /// Extracts all regular files. Entries with unsafe paths (absolute,
  /// `..`, drive letters), directories, symlinks and macOS metadata are
  /// skipped. If two entries differ only by case, the first wins (osu! is
  /// case-insensitive about file names, mobile file systems are not).
  static List<PackageEntry> decode(List<int> bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw FormatException('Not a valid .osz (zip) file: $e');
    }
    // The decoder returns an empty archive for non-zip input.
    if (archive.isEmpty) throw const FormatException('Not a valid .osz (zip) file, or it is empty');
    final out = <PackageEntry>[];
    final seen = <String>{};
    for (final f in archive.files) {
      if (!f.isFile || f.isSymbolicLink) continue;
      final path = normalizeEntryPath(f.name);
      if (path == null) continue;
      if (!seen.add(path.toLowerCase())) continue;
      out.add(PackageEntry(path, f.readBytes() ?? Uint8List(0)));
    }
    return out;
  }

  /// Already-compressed media is stored, everything else deflated.
  static Uint8List encode(Iterable<PackageEntry> entries) {
    final archive = Archive();
    for (final e in entries) {
      archive.add(_isCompressed(e.path)
          ? ArchiveFile.noCompress(e.path, e.bytes.length, e.bytes)
          : ArchiveFile.bytes(e.path, e.bytes));
    }
    return ZipEncoder().encodeBytes(archive);
  }

  static const _storedExtensions = {
    'mp3', 'ogg', 'm4a', 'aac', 'opus', //
    'jpg', 'jpeg', 'png', 'webp', 'gif',
    'mp4', 'avi', 'flv', 'webm', 'mkv',
    'zip', 'osz', 'osk',
  };

  static bool _isCompressed(String path) {
    final dot = path.lastIndexOf('.');
    return dot >= 0 && _storedExtensions.contains(path.substring(dot + 1).toLowerCase());
  }

  /// Returns a safe relative `/`-separated path, or null if the entry must
  /// not be extracted.
  static String? normalizeEntryPath(String name) {
    final p = name.replaceAll('\\', '/');
    if (p.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(p)) return null;
    final parts = <String>[];
    for (final seg in p.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') return null;
      if (seg.codeUnits.any((c) => c < 0x20)) return null;
      parts.add(seg);
    }
    if (parts.isEmpty) return null;
    if (parts.first == '__MACOSX' || parts.last == '.DS_Store') return null;
    return parts.join('/');
  }
}
