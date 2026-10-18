import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/render/playfield_painter.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';
import 'package:osu_edit/platform/storyboard_loader.dart';

void main() {
  ui.Image image() {
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(const ui.Rect.fromLTWH(0, 0, 2, 2), ui.Paint());
    return rec.endRecording().toImageSync(2, 2);
  }

  LoadedStoryboard storyboard() {
    final sb = Storyboard.parse([
      (['Sprite,Background,Centre,"bg.jpg",320,240', ' F,0,0,1000,1', ' R,0,0,1000,0,1', ' V,0,0,1000,1,1,-1,2'], {}),
    ]);
    return LoadedStoryboard(sb, {'bg.jpg': StoryboardTexture(image(), 854, 480)});
  }

  late Completer<LoadedStoryboard?> pending;
  late int calls;

  EditorController make() {
    final b = Beatmap.empty();
    b.insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
    SetBackgroundCommand('bg.jpg').apply(b);
    b.revision = 0;
    return EditorController(
      beatmap: b,
      document: const BeatmapDocument(fileName: 'x.osu', setPath: '/set'),
      storyboardLoader: (setPath, beatmap) {
        calls++;
        return (pending = Completer()).future;
      },
    );
  }

  setUp(() => calls = 0);

  test('loads once; toggle hides it; dispose frees the images', () async {
    final c = make();
    expect(calls, 1);
    expect(c.hasStoryboard, isFalse);
    final sb = storyboard();
    pending.complete(sb);
    await c.storyboardLoaded;
    expect(c.storyboard, same(sb));
    expect(c.storyboardReplacesBackground, isTrue);

    c.showStoryboard = false;
    expect(c.storyboard, isNull);
    expect(c.hasStoryboard, isTrue);
    expect(c.storyboardReplacesBackground, isFalse);
    c.showStoryboard = true;

    final img = sb.textures.values.single.image;
    c.dispose();
    expect(img.debugDisposed, isTrue);
  });

  test('a load finishing after dispose is freed', () async {
    final c = make();
    c.dispose();
    final sb = storyboard();
    final img = sb.textures.values.single.image;
    pending.complete(sb);
    await c.storyboardLoaded;
    expect(img.debugDisposed, isTrue);
  });

  test('the painter draws the storyboard during and outside its lifetime', () async {
    final c = make();
    pending.complete(storyboard());
    await c.storyboardLoaded;
    for (final t in [-100.0, 500.0, 2000.0]) {
      c.time.value = t;
      final rec = ui.PictureRecorder();
      PlayfieldPainter(c).paint(ui.Canvas(rec), const ui.Size(800, 450));
      rec.endRecording().dispose();
    }
    c.dispose();
  });

  test('batched and single draws: renders the expected pixels', () async {
    // Red 2x2 image; sprites on a black background, dim 0.
    final rec0 = ui.PictureRecorder();
    ui.Canvas(rec0).drawRect(const ui.Rect.fromLTWH(0, 0, 2, 2), ui.Paint()..color = const ui.Color(0xFFFF0000));
    final red = rec0.endRecording().toImageSync(2, 2);
    final sb = Storyboard.parse([
      ([
        // Batched (same image): plain, then tinted green (red x green = black).
        'Sprite,Background,TopLeft,"r.png",100,100', ' F,0,0,1000,1', ' S,0,0,1000,10',
        'Sprite,Background,TopLeft,"r.png",200,100', ' F,0,0,1000,1', ' S,0,0,1000,10', ' C,0,0,1000,0,255,0',
        // Single path: flipped and non-uniform.
        'Sprite,Background,TopLeft,"r.png",300,100', ' F,0,0,1000,1', ' V,0,0,1000,10,20', ' P,0,0,0,H',
        // Additive over the first one, half transparent.
        'Sprite,Background,TopLeft,"r.png",100,100', ' F,0,0,1000,0.5', ' S,0,0,1000,10', ' P,0,0,0,A',
      ], {}),
    ]);
    final loaded = LoadedStoryboard(sb, {'r.png': StoryboardTexture(red, 2, 2)});
    final b = Beatmap.empty();
    b.insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
    final c = EditorController(
      beatmap: b,
      document: const BeatmapDocument(fileName: 'x.osu', setPath: '/set'),
      storyboardLoader: (_, _) async => loaded,
    );
    await c.storyboardLoaded;
    c.backgroundDim = 0;
    c.time.value = 500;
    const size = ui.Size(608, 424); // PlayfieldTransform.fit -> scale 1
    final rec = ui.PictureRecorder();
    PlayfieldPainter(c).paint(ui.Canvas(rec), size);
    final img = rec.endRecording().toImageSync(608, 424);
    final bytes = (await img.toByteData())!;
    // Storyboard (x, y) -> screen: (-64, -56) to osu!px, then margins (48, 20).
    List<int> px(double sbx, double sby) {
      final x = (sbx - 64 + 48).round(), y = (sby - 56 + 20).round();
      final o = (y * 608 + x) * 4;
      return [bytes.getUint8(o), bytes.getUint8(o + 1), bytes.getUint8(o + 2)];
    }

    final plain = px(110, 110), tinted = px(210, 110), flipped = px(310, 110), empty = px(410, 110);
    expect(plain[0], greaterThan(150), reason: 'red (+ additive red), under the playfield tint');
    expect(tinted[0], lessThan(40), reason: 'red x green tint = black');
    expect(flipped[0], greaterThan(150), reason: 'flipped / non-uniform sprite drawn');
    expect(empty[0], lessThan(40), reason: 'nothing there');
    img.dispose();
    c.dispose();
  });
}
