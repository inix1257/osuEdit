import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../core/core.dart';
import 'beatmap_library.dart';

/// An imported skin in the [SkinLibrary].
class SkinInfo {
  /// Folder name inside the library (also the id the selection stores).
  final String folder;
  final String path;

  /// skin.ini `Name`, else the folder name.
  final String name;
  final String? author;

  const SkinInfo(this.folder, this.path, this.name, this.author);
}

/// The app's skins: `.osk` files unpacked into `Skins/<name>/`, next to the
/// beatmap library's `Songs` folder (outside it: not in the Files-app view
/// of the library, not in exports). The selected skin's folder name is
/// kept in `Skins/.selected`.
class SkinLibrary {
  final Directory root;

  SkinLibrary(this.root);

  /// The skins folder beside [library]'s Songs folder.
  factory SkinLibrary.beside(BeatmapLibrary library) =>
      SkinLibrary(Directory(BeatmapLibrary.joinPath(library.root.parent.path, 'Skins')));

  static const _tempSuffix = '.importing';
  File get _selectionFile => File(BeatmapLibrary.joinPath(root.path, '.selected'));

  Future<List<SkinInfo>> list() {
    final rootPath = root.path;
    return Isolate.run(() {
      final dir = Directory(rootPath);
      if (!dir.existsSync()) return <SkinInfo>[];
      final out = [
        for (final e in dir.listSync())
          if (e is Directory && !e.path.endsWith(_tempSuffix)) _read(e.path),
      ];
      out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return out;
    });
  }

  static String _nameOf(String path) => path.substring(path.lastIndexOf(Platform.pathSeparator) + 1);

  static SkinInfo _read(String path) {
    final ini = _readIni(path);
    final folder = _nameOf(path);
    return SkinInfo(folder, path, ini.name ?? folder, ini.author);
  }

  static SkinIni _readIni(String path) {
    final f = BeatmapLibrary.resolveFile(path, 'skin.ini');
    if (f == null) return SkinIni.none;
    try {
      return SkinIni.parse(SkinPackage.decodeIni(f.readAsBytesSync()));
    } catch (_) {
      return SkinIni.none;
    }
  }

  /// Unpacks an `.osk` into a new skin folder (named after skin.ini's Name,
  /// else [fallbackName]; `(2)` if taken).
  Future<SkinInfo> importOsk(Uint8List bytes, {String? fallbackName}) {
    final rootPath = root.path;
    return Isolate.run(() => _import(rootPath, bytes, fallbackName));
  }

  /// Imports the `.osk` at [path] (an inbox file) and deletes it.
  Future<SkinInfo> importAndRemove(File file) {
    final rootPath = root.path, path = file.path;
    return Isolate.run(() {
      final name = _nameOf(path);
      final dot = name.lastIndexOf('.');
      final skin = _import(rootPath, File(path).readAsBytesSync(), dot > 0 ? name.substring(0, dot) : name);
      File(path).deleteSync();
      return skin;
    });
  }

  static SkinInfo _import(String rootPath, Uint8List bytes, String? fallbackName) {
    final pkg = SkinPackage.decode(bytes);
    final base = BeatmapNaming.sanitize(pkg.ini.name ?? fallbackName ?? 'Skin', fallback: 'Skin');
    final root = Directory(rootPath)..createSync(recursive: true);
    final taken = [for (final e in root.listSync()) _nameOf(e.path)];
    final name = BeatmapNaming.unique(base, taken);
    final temp = Directory(BeatmapLibrary.joinPath(rootPath, '$name$_tempSuffix'));
    if (temp.existsSync()) temp.deleteSync(recursive: true);
    try {
      for (final e in pkg.entries) {
        final f = File(BeatmapLibrary.joinPath(temp.path, e.path.replaceAll('/', Platform.pathSeparator)));
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(e.bytes, flush: true);
      }
      final finalPath = BeatmapLibrary.joinPath(rootPath, name);
      temp.renameSync(finalPath);
      return _read(finalPath);
    } catch (_) {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
      rethrow;
    }
  }

  Future<void> delete(SkinInfo skin) async {
    final dir = Directory(skin.path);
    if (await dir.exists()) await dir.delete(recursive: true);
    if (await readSelection() == skin.folder) await writeSelection(null);
  }

  Future<String?> readSelection() async {
    try {
      final f = _selectionFile;
      if (!await f.exists()) return null;
      final v = (await f.readAsString()).trim();
      return v.isEmpty ? null : v;
    } catch (_) {
      return null;
    }
  }

  Future<void> writeSelection(String? folder) async {
    final f = _selectionFile;
    if (folder == null) {
      if (await f.exists()) await f.delete();
      return;
    }
    await root.create(recursive: true);
    await f.writeAsString(folder, flush: true);
  }
}

/// A skin image: [scale] 2 for an `@2x` file (drawn at half its pixels).
class SkinTexture {
  final ui.Image image;
  final double scale;

  const SkinTexture(this.image, this.scale);

  /// Size in standard-definition skin pixels (= osu!pixels at circle size
  /// scale 1: a 128 px hitcircle is one object diameter).
  double get width => image.width / scale;
  double get height => image.height / scale;
}

/// A skin with its images decoded for the playfield painter.
class LoadedSkin {
  final SkinInfo info;
  final SkinIni ini;
  final Map<String, SkinTexture> _textures;

  /// Folder holding the skin's hitsound files (`normal-hitnormal.wav` …).
  String get path => info.path;

  LoadedSkin._(this.info, this.ini, this._textures);

  /// The texture for element [name] (lower case, no extension), or null.
  SkinTexture? operator [](String name) => _textures[name];

  /// Animation frames of [name] the way lazer looks them up: `name<sep>0`,
  /// `name<sep>1`, … if the first exists, else [name] alone; empty if neither.
  List<SkinTexture> frames(String name, {String separator = '-'}) {
    final first = _textures['$name${separator}0'];
    if (first == null) {
      final single = _textures[name];
      return single == null ? const [] : [single];
    }
    final out = [first];
    for (var i = 1; i < maxFrames; i++) {
      final t = _textures['$name$separator$i'];
      if (t == null) break;
      out.add(t);
    }
    return out;
  }

  /// Digit textures of the hit circle font (`default-0` … `default-9`, or
  /// the skin's `HitCirclePrefix`), or null if any is missing.
  late final List<SkinTexture>? digits = () {
    final out = <SkinTexture>[];
    for (var i = 0; i < 10; i++) {
      final t = _textures['${ini.hitCirclePrefix.toLowerCase()}-$i'];
      if (t == null) return null;
      out.add(t);
    }
    return out;
  }();

  /// Highest animation frame number looked up.
  static const maxFrames = 60;

  /// Elements read from a skin (frames are added for the animated ones).
  static const _elements = [
    'hitcircle', 'hitcircleoverlay', //
    'sliderstartcircle', 'sliderstartcircleoverlay',
    'sliderendcircle', 'sliderendcircleoverlay',
    'approachcircle', 'reversearrow', 'sliderscorepoint',
    'sliderb-nd', 'sliderb-spec',
    'spinner-background', 'spinner-circle', 'spinner-approachcircle',
    'spinner-top', 'spinner-bottom', 'spinner-middle', 'spinner-middle2', 'spinner-glow',
  ];
  static const _animated = {'sliderb': '', 'sliderfollowcircle': '-', 'followpoint': '-'};

  /// Every element name to look for in a skin with [ini].
  static List<String> elementNames(SkinIni ini) => [
        ..._elements,
        for (final e in _animated.entries) ...[e.key, for (var i = 0; i < maxFrames; i++) '${e.key}${e.value}$i'],
        for (var i = 0; i < 10; i++) '${ini.hitCirclePrefix.toLowerCase()}-$i',
      ];

  /// Reads and decodes [info]'s images (file lookups in an isolate).
  static Future<LoadedSkin> load(SkinInfo info) async {
    final path = info.path;
    final (ini, files) = await Isolate.run(() => _readFiles(path));
    final textures = <String, SkinTexture>{};
    for (final e in files.entries) {
      try {
        final codec = await ui.instantiateImageCodec(e.value.$1);
        final frame = await codec.getNextFrame();
        codec.dispose();
        textures[e.key] = SkinTexture(frame.image, e.value.$2);
      } catch (_) {
        // Broken image: the element falls back to the built-in look.
      }
    }
    return LoadedSkin._(info, ini, textures);
  }

  /// skin.ini and the bytes of each element's image (`@2x` preferred, as
  /// lazer does; png, then jpg), keyed by element name.
  static (SkinIni, Map<String, (Uint8List, double)>) _readFiles(String path) {
    final ini = SkinLibrary._readIni(path);
    // Lower-case relative path (with `/`) → file, for case-insensitive lookups.
    final index = <String, File>{};
    final prefixLen = path.length + 1;
    for (final e in Directory(path).listSync(recursive: true)) {
      if (e is! File) continue;
      index.putIfAbsent(e.path.substring(prefixLen).replaceAll(Platform.pathSeparator, '/').toLowerCase(), () => e);
    }
    final out = <String, (Uint8List, double)>{};
    for (final name in elementNames(ini)) {
      for (final (suffix, scale) in const [('@2x', 2.0), ('', 1.0)]) {
        final f = index['$name$suffix.png'] ?? index['$name$suffix.jpg'];
        if (f == null) continue;
        final bytes = f.readAsBytesSync();
        if (bytes.isEmpty) continue;
        out[name] = (bytes, scale);
        break;
      }
    }
    return (ini, out);
  }

  void dispose() {
    for (final t in _textures.values) {
      t.image.dispose();
    }
    _textures.clear();
  }
}

/// The skin the editor draws with (app-wide, kept across sessions). Null
/// [current]: the built-in look.
class SkinManager {
  SkinManager._();
  static final instance = SkinManager._();

  final ValueNotifier<LoadedSkin?> current = ValueNotifier(null);
  SkinLibrary? _library;

  SkinLibrary? get library => _library;

  /// The selected skin's folder name (null: built-in), even while loading.
  String? get selected => _selected;
  String? _selected;

  /// Uses [library] and loads its selected skin.
  Future<void> attach(SkinLibrary library) async {
    if (_library?.root.path == library.root.path) return;
    _library = library;
    await _apply(await library.readSelection());
  }

  /// Selects [skin] (null: built-in) and remembers it.
  Future<void> select(SkinInfo? skin) async {
    await _library?.writeSelection(skin?.folder);
    await _apply(skin?.folder);
  }

  int _generation = 0;

  Future<void> _apply(String? folder) async {
    final gen = ++_generation;
    _selected = folder;
    LoadedSkin? loaded;
    final lib = _library;
    if (folder != null && lib != null) {
      final dir = Directory(BeatmapLibrary.joinPath(lib.root.path, folder));
      if (await dir.exists()) {
        try {
          loaded = await LoadedSkin.load(SkinLibrary._read(dir.path));
        } catch (_) {
          loaded = null;
        }
      } else {
        _selected = null;
      }
    }
    if (gen != _generation) {
      loaded?.dispose();
      return;
    }
    final old = current.value;
    current.value = loaded;
    old?.dispose();
  }

  /// The library was deleted or another one attached (tests).
  @visibleForTesting
  Future<void> reset() async {
    _library = null;
    await _apply(null);
  }
}
