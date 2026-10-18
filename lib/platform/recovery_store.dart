import 'dart:convert';
import 'dart:io';

import 'beatmap_file_service.dart';

/// An autosaved copy of an open map's unsaved state.
class RecoveredMap {
  /// The map file it belongs to.
  final String path;

  /// The whole `.osu` text at [savedAt].
  final String text;
  final DateTime savedAt;

  const RecoveredMap(this.path, this.text, this.savedAt);
}

/// Autosaves of unsaved edits, so they survive the app being killed in the
/// background (Android may do that at any time). One JSON file per map in
/// a `Recovery` folder beside the library's `Songs` (never inside a set, so
/// never exported). Written while there are unsaved changes, removed when
/// the map is saved or the changes are discarded.
class RecoveryStore {
  final Directory root;
  RecoveryStore(this.root);

  /// The store next to a library rooted at [songs].
  factory RecoveryStore.besideLibrary(Directory songs) => RecoveryStore(Directory('${songs.parent.path}${Platform.pathSeparator}Recovery'));

  /// FNV-1a 64 of the path: a short, stable file name.
  static String _key(String path) {
    var h = 0xcbf29ce484222325;
    for (final unit in path.codeUnits) {
      h ^= unit;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }

  File _file(String path) => File('${root.path}${Platform.pathSeparator}${_key(path)}.json');

  /// Saves [text] as the unsaved state of the map at [path] (atomically).
  Future<void> write(String path, String text) async {
    await root.create(recursive: true);
    final data = utf8.encode(jsonEncode({'path': path, 'savedAt': DateTime.now().toIso8601String(), 'text': text}));
    await BeatmapFileService.writeFileAtomic(_file(path), data);
  }

  /// The autosave of [path], or null (none, unreadable, or for another
  /// path with the same key).
  Future<RecoveredMap?> read(String path) async {
    final f = _file(path);
    try {
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map || j['path'] != path || j['text'] is! String) return null;
      return RecoveredMap(path, j['text'] as String, DateTime.tryParse('${j['savedAt']}') ?? DateTime.now());
    } catch (_) {
      return null;
    }
  }

  Future<void> clear(String path) async {
    try {
      await _file(path).delete();
    } on FileSystemException {
      // Not there: nothing to clear.
    }
  }
}
