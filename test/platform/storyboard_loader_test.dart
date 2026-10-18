import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/platform/storyboard_loader.dart';

void main() {
  Future<List<int>> png(int w, int h) async {
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint());
    final img = await rec.endRecording().toImage(w, h);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data!.buffer.asUint8List();
  }

  Beatmap map(String events) => OsuParser.parse(
      'osu file format v14\n\n[Metadata]\nTitle:T\nArtist:A\nCreator:C\n\n[Events]\n$events\n');

  testWidgets('parses .osu + .osb and decodes the images, keeping their size', (tester) async {
    await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('osuedit_sb_');
      try {
        Directory('${temp.path}/SB').createSync();
        File('${temp.path}/SB/Star.png').writeAsBytesSync(await png(40, 20));
        File('${temp.path}/big.png').writeAsBytesSync(await png(300, 100));
        // The named .osb wins over another one.
        File('${temp.path}/A - T (C).osb').writeAsStringSync(
            '[Events]\r\nSprite,Foreground,Centre,"sb\\star.png",320,240\r\n F,0,0,100,1\r\n'
            'Sprite,Foreground,Centre,"missing.png",0,0\r\n F,0,0,100,1\r\n');
        File('${temp.path}/aaa.osb').writeAsStringSync('[Events]\nSprite,Foreground,Centre,"other.png",0,0\n F,0,0,1,1\n');

        final sb = await loadStoryboard(temp.path, map('Sprite,Background,TopLeft,"big.png",0,0\n F,0,0,100,1'), maxSize: 100);
        expect(sb, isNotNull);
        expect(sb!.storyboard.sprites.map((s) => s.path), ['big.png', 'sb/star.png', 'missing.png']);
        final star = sb.textureOf(sb.storyboard.sprites[1], 0)!;
        expect((star.width, star.height, star.image.width), (40, 20, 40));
        final big = sb.textureOf(sb.storyboard.sprites[0], 0)!;
        expect((big.width, big.height), (300, 100)); // logical size kept
        expect(big.image.width, 100); // decoded smaller
        expect(sb.textureOf(sb.storyboard.sprites[2], 0), isNull);
        final images = sb.textures.values.map((t) => t.image).toList();
        sb.dispose();
        expect(images.every((i) => i.debugDisposed), isTrue);
      } finally {
        await temp.delete(recursive: true);
      }
    });
  });

  testWidgets('decodes every animation frame; textureOf follows the frame', (tester) async {
    await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('osuedit_sb_');
      try {
        Directory('${temp.path}/sb').createSync();
        File('${temp.path}/sb/a0.png').writeAsBytesSync(await png(10, 10));
        File('${temp.path}/sb/a1.png').writeAsBytesSync(await png(20, 10));
        final sb = (await loadStoryboard(temp.path, map('Animation,Foreground,Centre,"sb/a.png",0,0,2,100\n F,0,0,1000,1')))!;
        final s = sb.storyboard.sprites.single;
        expect(sb.textures.keys, unorderedEquals(['sb/a0.png', 'sb/a1.png']));
        expect(sb.textureOf(s, 50)!.width, 10);
        expect(sb.textureOf(s, 150)!.width, 20);
        expect(sb.textureOf(s, 250)!.width, 10);
        sb.dispose();
      } finally {
        await temp.delete(recursive: true);
      }
    });
  });

  testWidgets('no sprites: null', (tester) async {
    await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('osuedit_sb_');
      try {
        expect(await loadStoryboard(temp.path, map('0,0,"bg.jpg",0,0')), isNull);
      } finally {
        await temp.delete(recursive: true);
      }
    });
  });
}
