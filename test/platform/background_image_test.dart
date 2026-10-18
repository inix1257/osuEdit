import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/platform/background_image.dart';

void main() {
  // The reusable device test set (tool/make_click_test_osz.py) has a bg.jpg.
  const setPath = 'tool/test_set';

  testWidgets('decodes and downscales, keeping the aspect ratio', (tester) async {
    await tester.runAsync(() async {
      final full = await loadBackgroundImage(setPath, 'BG.JPG'); // case-insensitive lookup
      expect(full, isNotNull);
      final small = await loadBackgroundImage(setPath, 'bg.jpg', maxWidth: 64);
      expect(small!.width, 64);
      expect(small.height, closeTo(64 * full!.height / full.width, 1));
      full.dispose();
      small.dispose();
    });
  });

  testWidgets('missing or non-image files give null', (tester) async {
    await tester.runAsync(() async {
      expect(await loadBackgroundImage(setPath, 'nope.png'), isNull);
      final temp = await Directory.systemTemp.createTemp('osuedit_bg_');
      try {
        File('${temp.path}/bad.jpg').writeAsStringSync('not an image');
        expect(await loadBackgroundImage(temp.path, 'bad.jpg'), isNull);
      } finally {
        await temp.delete(recursive: true);
      }
    });
  });
}
