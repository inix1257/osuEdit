import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import '../core/core.dart';
import 'beatmap_library.dart';

/// A decoded storyboard image. [width]/[height] are the file's size in
/// storyboard pixels; [image] may be smaller (downscaled to save memory).
class StoryboardTexture {
  final ui.Image image;
  final double width, height;

  StoryboardTexture(this.image, this.width, this.height);
}

/// A parsed storyboard with its images (display only).
class LoadedStoryboard {
  final Storyboard storyboard;

  /// By lower-case path; sprites whose image is missing aren't drawn.
  final Map<String, StoryboardTexture> textures;

  /// `WidescreenStoryboard: 1` (16:9 area instead of 4:3).
  final bool widescreen;

  /// Per sprite (same index as [Storyboard.sprites]): the texture of each
  /// frame, looked up once so drawing doesn't build path strings.
  late final List<List<StoryboardTexture?>> _frames = [
    for (final s in storyboard.sprites) [for (final p in s.framePaths) textures[p.toLowerCase()]],
  ];

  LoadedStoryboard(this.storyboard, this.textures, {this.widescreen = false});

  /// The image [s] shows at [time] (its current frame for an animation).
  StoryboardTexture? textureOf(StoryboardSprite s, double time) => textures[s.imageAt(time).toLowerCase()];

  /// Fast [textureOf] for sprite number [index] of [Storyboard.sprites].
  StoryboardTexture? textureAt(int index, StoryboardSprite s, double time) {
    final f = _frames[index];
    return f.length == 1 ? f[0] : f[s.frameAt(time)];
  }

  void dispose() {
    for (final t in textures.values) {
      t.image.dispose();
    }
    textures.clear();
  }
}

/// Parses the storyboard of [beatmap] (its own `[Events]` plus the set's
/// `.osb`) and decodes the images it uses. Null if there are no sprites.
///
/// Images are capped at [maxSize] px per side, and all of them are scaled
/// down together if their decoded size would pass [budgetBytes] (RGBA).
Future<LoadedStoryboard?> loadStoryboard(String setPath, Beatmap beatmap,
    {int maxSize = 2048, int budgetBytes = 160 * 1024 * 1024}) async {
  final osuSource = Storyboard.beatmapSource(beatmap);
  final osbFile = _findOsb(setPath, beatmap);
  final storyboard = await Isolate.run(() {
    final sources = [osuSource];
    if (osbFile != null) {
      try {
        final (text, _) = OsuTextCodec.decode(osbFile.readAsBytesSync());
        sources.add(Storyboard.splitOsb(text));
      } on FileSystemException {
        // Unreadable .osb: use the .osu part only.
      }
    }
    return Storyboard.parse(sources);
  });
  if (storyboard.isEmpty) return null;

  // Pass 1: image sizes (headers only), to fit the memory budget.
  final paths = storyboard.imagePaths.toList();
  final files = <String, File>{};
  final sizes = <String, (int, int)>{};
  var total = 0.0;
  for (final p in paths) {
    final file = BeatmapLibrary.resolveFile(setPath, p);
    if (file == null) continue;
    final size = await _imageSize(file);
    if (size == null) continue;
    final (w, h) = _capped(size.$1, size.$2, maxSize.toDouble());
    files[p] = file;
    sizes[p] = size;
    total += w * h * 4;
  }
  final fit = total > budgetBytes ? math.sqrt(budgetBytes / total) : 1.0;

  // Pass 2: decode, a few at a time (fast, without holding every file).
  final textures = <String, StoryboardTexture>{};
  final todo = files.keys.toList();
  const parallel = 4;
  for (var i = 0; i < todo.length; i += parallel) {
    final batch = todo.skip(i).take(parallel).toList();
    final loaded = await Future.wait(batch.map((p) => _decode(files[p]!, sizes[p]!, maxSize, fit)));
    for (final (j, p) in batch.indexed) {
      final t = loaded[j];
      if (t != null) textures[p.toLowerCase()] = t;
    }
  }
  return LoadedStoryboard(storyboard, textures, widescreen: Storyboard.isWidescreen(beatmap));
}

/// [w]x[h] scaled to fit [max] per side (aspect kept).
(double, double) _capped(int w, int h, double max) {
  final big = w > h ? w : h;
  final s = big > max ? max / big : 1.0;
  return (w * s, h * s);
}

/// The set's `.osb`: osu! names it `Artist - Title (Creator).osb`; else the
/// first one found.
File? _findOsb(String setPath, Beatmap beatmap) {
  final dir = Directory(setPath);
  if (!dir.existsSync()) return null;
  final osbs = dir.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.osb')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (osbs.isEmpty) return null;
  final want = DifficultyOps.osbFileNameOf(beatmap).toLowerCase();
  for (final f in osbs) {
    if (f.path.substring(f.path.lastIndexOf(Platform.pathSeparator) + 1).toLowerCase() == want) return f;
  }
  return osbs.first;
}

Future<(int, int)?> _imageSize(File file) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(await file.readAsBytes());
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return (descriptor.width, descriptor.height);
  } catch (_) {
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

Future<StoryboardTexture?> _decode(File file, (int, int) size, int maxSize, double fit) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(await file.readAsBytes());
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final (w, h) = size;
    final (cw, ch) = _capped(w, h, maxSize.toDouble());
    final tw = math.max(1, (cw * fit).round()), th = math.max(1, (ch * fit).round());
    final scaled = tw != w || th != h;
    codec = await descriptor.instantiateCodec(targetWidth: scaled ? tw : null, targetHeight: scaled ? th : null);
    final img = (await codec.getNextFrame()).image;
    return StoryboardTexture(img, w.toDouble(), h.toDouble());
  } catch (_) {
    return null;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}
