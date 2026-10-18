import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../core/core.dart';
import 'beatmap_file_service.dart';

/// One `.osu` file inside a set folder.
class LibraryDifficulty {
  final String path;
  final BeatmapSummary summary;

  /// osu!standard star rating ([StarRating]); null for other modes, files
  /// that can't be rated, and while [starRatingPending].
  final double? starRating;

  /// Not rated yet ([BeatmapLibrary.computeStarRatings] will).
  final bool starRatingPending;

  const LibraryDifficulty(this.path, this.summary, {this.starRating, this.starRatingPending = false});

  String get fileName => path.substring(path.lastIndexOf(Platform.pathSeparator) + 1);
}

/// One set folder (`Songs/<set>`).
class LibrarySet {
  final String path;

  /// Sorted by star rating like osu! (other modes after, by object count);
  /// by object count while some ratings are pending.
  final List<LibraryDifficulty> difficulties;
  const LibrarySet(this.path, this.difficulties);

  String get folderName => path.substring(path.lastIndexOf(Platform.pathSeparator) + 1);

  String get displayTitle {
    if (difficulties.isEmpty) return folderName;
    final s = difficulties.first.summary;
    if (s.artist.isEmpty && s.title.isEmpty) return folderName;
    return '${s.artist} - ${s.title}';
  }

  String get creator => difficulties.isEmpty ? '' : difficulties.first.summary.creator;
}

/// The app-internal beatmap library: `<app documents>/Songs/<set>/…`.
///
/// Edits always happen on these internal copies; getting maps in and out is
/// done with `.osz` import / export (SAF on Android, document picker or the
/// Files app on iOS). Heavy work (zip, directory scans) runs in a background
/// isolate via [Isolate.run].
class BeatmapLibrary {
  /// The `Songs` folder.
  final Directory root;

  /// Folders scanned for `.osz` files the user dropped in from outside the
  /// app (iOS Files app: Documents root and Documents/Inbox).
  final List<Directory> inboxes;

  BeatmapLibrary(this.root, {this.inboxes = const []});

  static Future<BeatmapLibrary> open() async {
    // Desktop: keep the library out of the user's Documents folder.
    final base = Platform.isAndroid || Platform.isIOS
        ? await getApplicationDocumentsDirectory()
        : await getApplicationSupportDirectory();
    final lib = BeatmapLibrary(
      Directory(joinPath(base.path, 'Songs')),
      // iOS: the Files app shows Documents; "Open in" copies to Documents/Inbox.
      // Android: MainActivity copies shared / opened .osz into Inbox.
      inboxes: Platform.isIOS
          ? [base, Directory(joinPath(base.path, 'Inbox'))]
          : Platform.isAndroid
              ? [Directory(joinPath(base.path, 'Inbox'))]
              : const [],
    );
    await lib.root.create(recursive: true);
    return lib;
  }

  static String joinPath(String a, String b) =>
      a.endsWith(Platform.pathSeparator) ? '$a$b' : '$a${Platform.pathSeparator}$b';

  // ---------------------------------------------------------------------------
  // Listing

  Future<List<LibrarySet>> listSets() {
    final rootPath = root.path;
    return Isolate.run(() => _listSets(rootPath));
  }

  static List<LibrarySet> _listSets(String rootPath) {
    final dir = Directory(rootPath);
    if (!dir.existsSync()) return [];
    final ratings = _StarRatingCache.load(rootPath);
    final sets = <LibrarySet>[];
    for (final e in dir.listSync()) {
      if (e is! Directory || e.path.endsWith(_tempSuffix)) continue;
      sets.add(_readSet(e.path, ratings));
    }
    sets.sort((a, b) => a.displayTitle.toLowerCase().compareTo(b.displayTitle.toLowerCase()));
    return sets;
  }

  /// Reads [setPath]; star ratings come from [ratings] (pending if not
  /// cached), none at all without it.
  static LibrarySet _readSet(String setPath, [_StarRatingCache? ratings]) {
    final diffs = <LibraryDifficulty>[];
    for (final f in Directory(setPath).listSync()) {
      if (f is! File || !f.path.toLowerCase().endsWith('.osu')) continue;
      final (text, _) = OsuTextCodec.decode(f.readAsBytesSync());
      final summary = BeatmapSummary.scan(text);
      if (ratings == null || summary.mode != 0) {
        diffs.add(LibraryDifficulty(f.path, summary));
        continue;
      }
      final cached = ratings.lookup(f);
      diffs.add(LibraryDifficulty(f.path, summary, starRating: cached?.$1, starRatingPending: cached == null));
    }
    int byObjects(LibraryDifficulty a, LibraryDifficulty b) =>
        a.summary.hitObjectCount.compareTo(b.summary.hitObjectCount);
    if (diffs.any((d) => d.starRatingPending)) {
      diffs.sort(byObjects);
    } else {
      diffs.sort((a, b) {
        final ra = a.starRating, rb = b.starRating;
        if (ra != null && rb != null) return ra.compareTo(rb);
        if (ra != null || rb != null) return ra != null ? -1 : 1;
        return byObjects(a, b);
      });
    }
    return LibrarySet(setPath, diffs);
  }

  Future<LibrarySet> readSet(String setPath) {
    final rootPath = root.path;
    return Isolate.run(() => _readSet(setPath, _StarRatingCache.load(rootPath)));
  }

  /// Rates every osu!standard difficulty whose star rating isn't cached
  /// (new or changed since), in a background isolate, and caches the
  /// results beside the sets (`Songs/.star_ratings.json`, never exported).
  /// Returns how many files were rated.
  Future<int> computeStarRatings() {
    final rootPath = root.path;
    return Isolate.run(() {
      final ratings = _StarRatingCache.load(rootPath);
      final seen = <String>{};
      var rated = 0;
      for (final e in Directory(rootPath).listSync()) {
        if (e is! Directory || e.path.endsWith(_tempSuffix)) continue;
        for (final f in e.listSync()) {
          if (f is! File || !f.path.toLowerCase().endsWith('.osu')) continue;
          seen.add(ratings.keyOf(f));
          if (ratings.lookup(f) != null) continue;
          double? sr;
          var mode = 0;
          try {
            final beatmap = OsuParser.parse(OsuTextCodec.decode(f.readAsBytesSync()).$1);
            mode = beatmap.mode;
            sr = StarRating.of(beatmap);
          } catch (_) {
            // Unreadable: cached as "no rating" until the file changes.
          }
          if (mode != 0) continue;
          ratings.put(f, sr);
          rated++;
        }
      }
      ratings.retainOnly(seen);
      ratings.save();
      return rated;
    });
  }

  /// `.osz` (and `.osk` skin) files waiting in [inboxes].
  Future<List<File>> pendingImports() async {
    if (inboxes.isEmpty) return const [];
    final dirs = [for (final d in inboxes) d.path];
    final paths = await Isolate.run(() => [
          for (final p in dirs)
            if (Directory(p).existsSync())
              for (final e in Directory(p).listSync())
                if (e is File && (e.path.toLowerCase().endsWith('.osz') || e.path.toLowerCase().endsWith('.osk')))
                  e.path,
        ]);
    return [for (final p in paths) File(p)];
  }

  // ---------------------------------------------------------------------------
  // Import / export

  static const _tempSuffix = '.importing';

  /// Extracts an `.osz` into a new set folder. Files are written exactly as
  /// stored in the archive (no re-encoding). [fallbackName] (usually the
  /// archive's file name) is used if no difficulty has metadata.
  Future<LibrarySet> importOsz(Uint8List bytes, {String? fallbackName}) {
    final rootPath = root.path;
    return Isolate.run(() => _importOsz(rootPath, bytes, fallbackName));
  }

  /// Imports [file] and deletes it afterwards (for [pendingImports]).
  Future<LibrarySet> importAndRemove(File file) {
    final rootPath = root.path, path = file.path;
    return Isolate.run(() {
      final set = _importOsz(rootPath, File(path).readAsBytesSync(), _stem(path));
      File(path).deleteSync();
      return set;
    });
  }

  static String _stem(String path) {
    final name = path.substring(path.lastIndexOf(RegExp(r'[\\/]')) + 1);
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  static LibrarySet _importOsz(String rootPath, Uint8List bytes, String? fallbackName) {
    final entries = OszCodec.decode(bytes);
    final osu = entries.where((e) => e.path.toLowerCase().endsWith('.osu')).toList();
    if (osu.isEmpty) throw const FormatException('The archive contains no .osu file');

    // Name the folder after the first difficulty that has metadata.
    var folder = fallbackName == null ? null : BeatmapNaming.sanitize(fallbackName);
    for (final e in osu) {
      final s = BeatmapSummary.scan(OsuTextCodec.decode(e.bytes).$1);
      if (s.artist.isNotEmpty || s.title.isNotEmpty) {
        folder = BeatmapNaming.setFolderName(artist: s.artist, title: s.title, beatmapSetId: s.beatmapSetId);
        break;
      }
    }
    folder ??= 'Imported set';

    final root = Directory(rootPath)..createSync(recursive: true);
    final taken = [for (final e in root.listSync()) e.path.substring(e.path.lastIndexOf(Platform.pathSeparator) + 1)];
    final name = BeatmapNaming.unique(folder, taken);

    // Extract into a temp folder first so a failure never leaves a
    // half-written set in the library.
    final temp = Directory(joinPath(rootPath, '$name$_tempSuffix'));
    if (temp.existsSync()) temp.deleteSync(recursive: true);
    try {
      for (final e in entries) {
        final f = File(joinPath(temp.path, e.path.replaceAll('/', Platform.pathSeparator)));
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(e.bytes, flush: true);
      }
      final finalPath = joinPath(rootPath, name);
      temp.renameSync(finalPath);
      return _readSet(finalPath);
    } catch (_) {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
      rethrow;
    }
  }

  /// Zips a set folder. Every file is read as raw bytes, so untouched files
  /// come out byte-identical to what was imported.
  Future<Uint8List> exportOsz(String setPath) => Isolate.run(() => _exportOsz(setPath));

  static Uint8List _exportOsz(String setPath) {
    final dir = Directory(setPath);
    final prefix = dir.path.length + 1;
    final entries = <PackageEntry>[];
    for (final e in dir.listSync(recursive: true)) {
      if (e is! File) continue;
      final rel = e.path.substring(prefix).replaceAll(Platform.pathSeparator, '/');
      entries.add(PackageEntry(rel, e.readAsBytesSync()));
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    return OszCodec.encode(entries);
  }

  /// Suggested file name for exporting [set].
  static String oszFileName(LibrarySet set) => '${set.folderName}.osz';

  /// Creates an empty set folder holding one new difficulty.
  Future<LibraryDifficulty> createSet(Beatmap beatmap) async {
    await root.create(recursive: true);
    final taken = [
      await for (final e in root.list()) e.path.substring(e.path.lastIndexOf(Platform.pathSeparator) + 1)
    ];
    final name = BeatmapNaming.unique(
      BeatmapNaming.setFolderName(artist: beatmap.artist, title: beatmap.title),
      taken,
    );
    final dir = await Directory(joinPath(root.path, name)).create();
    final file = File(joinPath(
      dir.path,
      BeatmapNaming.osuFileName(
        artist: beatmap.artist,
        title: beatmap.title,
        creator: beatmap.creator,
        version: beatmap.version,
      ),
    ));
    final text = OsuWriter.write(beatmap);
    await file.writeAsBytes(OsuTextCodec.encode(text, OsuTextEncoding.utf8), flush: true);
    return LibraryDifficulty(file.path, BeatmapSummary.scan(text));
  }

  // ---------------------------------------------------------------------------
  // Difficulties inside a set

  /// Writes [beatmap] as a new difficulty of [setPath], named like
  /// osu!stable (`… [Version].osu`, `(2)` added if taken).
  Future<LibraryDifficulty> addDifficulty(String setPath, Beatmap beatmap,
      {OsuTextEncoding encoding = OsuTextEncoding.utf8}) async {
    final text = OsuWriter.write(beatmap);
    final name = _uniqueFileName(setPath, DifficultyOps.fileNameOf(beatmap));
    final file = File(joinPath(setPath, name));
    await file.writeAsBytes(OsuTextCodec.encode(text, encoding), flush: true);
    return LibraryDifficulty(file.path, BeatmapSummary.scan(text));
  }

  /// Renames the difficulty at [path] to [fileName] (made unique among the
  /// set's other files). Returns the new path (unchanged if already named so).
  Future<String> renameDifficulty(String path, String fileName) async {
    final file = File(path);
    final current = file.path.substring(file.path.lastIndexOf(Platform.pathSeparator) + 1);
    if (current == fileName) return path;
    final name = _uniqueFileName(file.parent.path, fileName, except: current);
    if (name == current) return path;
    return (await file.rename(joinPath(file.parent.path, name))).path;
  }

  /// Renames the set's storyboard [from] to [to] (both `.osb` file names,
  /// matched case-insensitively), so osu!stable, which finds it by the
  /// metadata (`Artist - Title (Creator).osb`), still does after a metadata
  /// change. Does nothing if there is no [from], or if another file is
  /// already called [to] (never overwrites). Returns whether it renamed.
  Future<bool> renameStoryboard(String setPath, String from, String to) async {
    if (from == to) return false;
    final files = [
      for (final e in await Directory(setPath).list().toList())
        if (e is File) e,
    ];
    String nameOf(File f) => f.path.substring(f.path.lastIndexOf(Platform.pathSeparator) + 1);
    final source = files.where((f) => nameOf(f).toLowerCase() == from.toLowerCase()).firstOrNull;
    if (source == null) return false;
    final clash = files.any((f) => f != source && nameOf(f).toLowerCase() == to.toLowerCase());
    if (clash) return false;
    try {
      await source.rename(joinPath(setPath, to));
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// [wanted], or `stem (2).osu`… if another file of the set already has
  /// that name (case-insensitive; [except] is the file being renamed).
  static String _uniqueFileName(String setPath, String wanted, {String? except}) {
    final lower = {
      for (final e in Directory(setPath).listSync())
        e.path.substring(e.path.lastIndexOf(Platform.pathSeparator) + 1).toLowerCase(),
    }..remove(except?.toLowerCase());
    final dot = wanted.lastIndexOf('.');
    final stem = dot > 0 ? wanted.substring(0, dot) : wanted;
    final ext = dot > 0 ? wanted.substring(dot) : '';
    if (!lower.contains(wanted.toLowerCase())) return wanted;
    for (var i = 2;; i++) {
      final c = '$stem ($i)$ext';
      if (!lower.contains(c.toLowerCase())) return c;
    }
  }

  /// Writes the set-wide metadata [values] into every difficulty of
  /// [setPath] except [exceptPath], renaming each changed file to match.
  /// Files keep their encoding; untouched lines stay byte-identical.
  /// Returns how many difficulties changed.
  Future<int> syncSetMetadata(String setPath, Map<String, String> values, {String? exceptPath}) async {
    var count = 0;
    for (final d in (await readSet(setPath)).difficulties) {
      if (d.path == exceptPath) continue;
      final (text, encoding) = OsuTextCodec.decode(await File(d.path).readAsBytes());
      final b = OsuParser.parse(text);
      final osbBefore = DifficultyOps.osbFileNameOf(b);
      if (!DifficultyOps.applySetMetadata(b, values)) continue;
      await renameStoryboard(setPath, osbBefore, DifficultyOps.osbFileNameOf(b));
      await BeatmapFileService.writeFileAtomic(File(d.path), OsuTextCodec.encode(OsuWriter.write(b), encoding));
      await renameDifficulty(d.path, DifficultyOps.fileNameOf(b));
      count++;
    }
    return count;
  }

  /// Copies [source]'s hitsounds into the difficulties at [targets]
  /// ([HitsoundCopyOps.copy]), writing each changed file in its own
  /// encoding. Returns the changed files' previous bytes by path, for
  /// [restoreFiles] (undo).
  Future<Map<String, Uint8List>> copyHitsounds(
    Beatmap source,
    List<String> targets, {
    double leniency = HitsoundCopyOps.defaultLeniency,
    bool samplePoints = true,
    bool clearUnmatched = false,
  }) async {
    final previous = <String, Uint8List>{};
    for (final path in targets) {
      final file = File(path);
      final bytes = await file.readAsBytes();
      final (text, encoding) = OsuTextCodec.decode(bytes);
      final target = OsuParser.parse(text);
      final command = HitsoundCopyOps.copy(
        source: source,
        target: target,
        leniency: leniency,
        samplePoints: samplePoints,
        clearUnmatched: clearUnmatched,
      );
      if (command == null) continue;
      command.apply(target);
      await BeatmapFileService.writeFileAtomic(file, OsuTextCodec.encode(OsuWriter.write(target), encoding));
      previous[path] = bytes;
    }
    return previous;
  }

  /// Writes [files] (path → bytes) back, e.g. to undo [copyHitsounds].
  Future<void> restoreFiles(Map<String, Uint8List> files) async {
    for (final e in files.entries) {
      await BeatmapFileService.writeFileAtomic(File(e.key), e.value);
    }
  }

  /// Deletes one difficulty (`.osu`) of a library set. Only `.osu` files
  /// directly inside a set folder of the library.
  Future<void> deleteDifficulty(String path) async {
    final file = File(path);
    final inSet = file.parent.parent.absolute.path == root.absolute.path;
    if (!inSet || !path.toLowerCase().endsWith('.osu')) {
      throw StateError('Not a library difficulty: $path');
    }
    await file.delete();
  }

  Future<void> deleteSet(LibrarySet set) async {
    final dir = Directory(set.path);
    // Never touch anything outside the library.
    if (dir.parent.absolute.path != root.absolute.path) {
      throw StateError('Not a library set: ${set.path}');
    }
    await dir.delete(recursive: true);
    await _setSliderFormat(set.path, null);
  }

  // ---------------------------------------------------------------------------
  // osu!lazer slider format (several curve types in one slider, B-splines)

  /// Per-set choice for lazer-format sliders, by folder name: `lazer`
  /// (kept) or `stable` (converted). Kept beside the sets, not inside them,
  /// so it never ends up in an exported `.osz`.
  File get _sliderFormatsFile => File(joinPath(root.path, '.slider_formats.json'));

  Future<Map<String, String>> _sliderFormats() async {
    try {
      final data = jsonDecode(await _sliderFormatsFile.readAsString());
      if (data is Map) return {for (final e in data.entries) '${e.key}': '${e.value}'};
    } on FileSystemException {
      // No choice made yet.
    } on FormatException {
      // Unreadable: ask again.
    }
    return {};
  }

  static String _folderOf(String setPath) => setPath.substring(setPath.lastIndexOf(Platform.pathSeparator) + 1);

  /// Whether the user kept [setPath]'s sliders in lazer's format (true),
  /// converted them (false), or hasn't been asked (null).
  Future<bool?> keepsLazerSliders(String setPath) async =>
      switch ((await _sliderFormats())[_folderOf(setPath)]) {
        'lazer' => true,
        'stable' => false,
        _ => null,
      };

  /// Records the choice for [setPath] (see [keepsLazerSliders]).
  Future<void> setKeepsLazerSliders(String setPath, bool keep) => _setSliderFormat(setPath, keep ? 'lazer' : 'stable');

  Future<void> _setSliderFormat(String setPath, String? format) async {
    final all = await _sliderFormats();
    final folder = _folderOf(setPath);
    if (format == null ? !all.containsKey(folder) : all[folder] == format) return;
    if (format == null) {
      all.remove(folder);
    } else {
      all[folder] = format;
    }
    await BeatmapFileService.writeFileAtomic(_sliderFormatsFile, utf8.encode(jsonEncode(all)));
  }

  /// How many sliders in [setPath]'s difficulties use lazer's format.
  Future<int> countLazerSliders(String setPath) => Isolate.run(() {
        var count = 0;
        for (final d in _readSet(setPath).difficulties) {
          final (text, _) = OsuTextCodec.decode(File(d.path).readAsBytesSync());
          if (!text.contains('|')) continue;
          count += SliderFormatOps.lazerSliders(OsuParser.parse(text)).length;
        }
        return count;
      });

  /// Converts every lazer-format slider in [setPath] to stable's format
  /// (same shapes as bezier curves), rewriting only those lines of each
  /// `.osu` (same encoding). Returns how many sliders were converted.
  Future<int> convertSetToStable(String setPath) => Isolate.run(() async {
        var count = 0;
        for (final d in _readSet(setPath).difficulties) {
          final file = File(d.path);
          final (text, encoding) = OsuTextCodec.decode(file.readAsBytesSync());
          final b = OsuParser.parse(text);
          final command = SliderFormatOps.convertToStable(b);
          if (command == null) continue;
          count += SliderFormatOps.lazerSliders(b).length;
          command.apply(b);
          await BeatmapFileService.writeFileAtomic(file, OsuTextCodec.encode(OsuWriter.write(b), encoding));
        }
        return count;
      });

  // ---------------------------------------------------------------------------
  // Files inside a set

  /// Copies [bytes] into the root of [setPath] as [fileName] (sanitized) and
  /// returns the name to reference from the `.osu` file. An identical file
  /// already there is reused; a different one with the same name is never
  /// overwritten (other difficulties may use it) — the copy gets `name (2).ext`.
  Future<String> addFileToSet(String setPath, String fileName, Uint8List bytes) =>
      Isolate.run(() => _addFileToSet(setPath, fileName, bytes));

  static String _addFileToSet(String setPath, String fileName, Uint8List bytes) {
    final clean = BeatmapNaming.sanitize(fileName.substring(fileName.lastIndexOf(RegExp(r'[\\/]')) + 1),
        fallback: 'file');
    final dot = clean.lastIndexOf('.');
    final stem = dot > 0 ? clean.substring(0, dot) : clean;
    final ext = dot > 0 ? clean.substring(dot) : '';

    final existing = <String, File>{
      for (final e in Directory(setPath).listSync())
        if (e is File) e.path.substring(e.path.lastIndexOf(Platform.pathSeparator) + 1).toLowerCase(): e,
    };
    for (var i = 1;; i++) {
      final name = i == 1 ? clean : '$stem ($i)$ext';
      final same = existing[name.toLowerCase()];
      if (same == null) {
        final target = File(joinPath(setPath, name));
        final tmp = File('${target.path}.tmp');
        tmp.writeAsBytesSync(bytes, flush: true);
        tmp.renameSync(target.path);
        return name;
      }
      if (_sameBytes(same, bytes)) {
        return same.path.substring(same.path.lastIndexOf(Platform.pathSeparator) + 1);
      }
    }
  }

  static bool _sameBytes(File f, Uint8List bytes) {
    if (f.lengthSync() != bytes.length) return false;
    final a = f.readAsBytesSync();
    for (var i = 0; i < a.length; i++) {
      if (a[i] != bytes[i]) return false;
    }
    return true;
  }

  /// Finds [relativePath] (as written in a .osu file, e.g. `AudioFilename`)
  /// inside [setPath]. osu! treats names case-insensitively but Android / iOS
  /// file systems are case-sensitive, so fall back to a per-segment
  /// case-insensitive match.
  static File? resolveFile(String setPath, String relativePath) {
    final rel = OszCodec.normalizeEntryPath(relativePath.trim().replaceAll('"', ''));
    if (rel == null) return null;
    final exact = File(joinPath(setPath, rel.replaceAll('/', Platform.pathSeparator)));
    if (exact.existsSync()) return exact;
    var cur = setPath;
    final segs = rel.split('/');
    for (var i = 0; i < segs.length; i++) {
      final want = segs[i].toLowerCase();
      final last = i == segs.length - 1;
      String? found;
      final d = Directory(cur);
      if (!d.existsSync()) return null;
      for (final e in d.listSync()) {
        final n = e.path.substring(e.path.lastIndexOf(Platform.pathSeparator) + 1);
        if (n.toLowerCase() == want && (last ? e is File : e is Directory)) {
          found = e.path;
          break;
        }
      }
      if (found == null) return null;
      cur = found;
    }
    return File(cur);
  }
}

/// `Songs/.star_ratings.json`: `{"version": StarRating.calculatorVersion,
/// "files": {"set/file.osu": [size, modified ms, rating or null]}}`.
/// An entry counts only while the file's size and modification time match,
/// so edited files are rated again; another calculator version drops all.
class _StarRatingCache {
  final String rootPath;
  final Map<String, List<Object?>> _files;
  bool _dirty = false;

  _StarRatingCache._(this.rootPath, this._files);

  File get _file => File(BeatmapLibrary.joinPath(rootPath, '.star_ratings.json'));

  static _StarRatingCache load(String rootPath) {
    final cache = _StarRatingCache._(rootPath, {});
    try {
      final data = jsonDecode(cache._file.readAsStringSync());
      if (data is Map && data['version'] == StarRating.calculatorVersion && data['files'] is Map) {
        for (final e in (data['files'] as Map).entries) {
          if (e.value is List && (e.value as List).length == 3) cache._files['${e.key}'] = List.of(e.value as List);
        }
      }
    } on FileSystemException {
      // Nothing rated yet.
    } on FormatException {
      // Unreadable: rate again.
    }
    return cache;
  }

  String keyOf(File f) => f.path.substring(rootPath.length).replaceAll(Platform.pathSeparator, '/').replaceFirst(RegExp('^/+'), '');

  /// `(rating,)` when cached for the file as it is now (rating null = not
  /// ratable), else null.
  (double?,)? lookup(File f) {
    final e = _files[keyOf(f)];
    if (e == null) return null;
    final stat = f.statSync();
    if (e[0] != stat.size || e[1] != stat.modified.millisecondsSinceEpoch) return null;
    final r = e[2];
    return (r is num ? r.toDouble() : null,);
  }

  void put(File f, double? rating) {
    final stat = f.statSync();
    _files[keyOf(f)] = [stat.size, stat.modified.millisecondsSinceEpoch, rating];
    _dirty = true;
  }

  /// Drops entries of files that no longer exist.
  void retainOnly(Set<String> keys) {
    final before = _files.length;
    _files.removeWhere((k, _) => !keys.contains(k));
    if (_files.length != before) _dirty = true;
  }

  void save() {
    if (!_dirty) return;
    final tmp = File('${_file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode({'version': StarRating.calculatorVersion, 'files': _files}), flush: true);
    tmp.renameSync(_file.path);
    _dirty = false;
  }
}
