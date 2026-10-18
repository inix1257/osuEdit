import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/app_settings.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// P2: the set's background image under the playfield, with a dim setting.
void main() {
  ui.Image image() {
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(const ui.Rect.fromLTWH(0, 0, 2, 2), ui.Paint());
    return rec.endRecording().toImageSync(2, 2);
  }

  late List<String> requested;
  late Map<String, Completer<ui.Image?>> pending;

  /// Each request waits until the test completes it.
  Future<ui.Image?> loader(String setPath, String name) {
    requested.add(name);
    return (pending[name] = Completer()).future;
  }

  EditorController make({String? bg, bool withLoader = true, bool inLibrary = true}) {
    final b = Beatmap.empty();
    b.insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
    if (bg != null) SetBackgroundCommand(bg).apply(b);
    b.revision = 0;
    return EditorController(
      beatmap: b,
      document: BeatmapDocument(fileName: 'x.osu', setPath: inLibrary ? '/set' : null),
      backgroundLoader: withLoader ? loader : null,
    );
  }

  setUp(() {
    requested = [];
    pending = {};
  });

  test('loads the background named by the map', () async {
    final c = make(bg: 'bg.jpg');
    expect(requested, ['bg.jpg']);
    expect(c.background, isNull);
    final img = image();
    pending['bg.jpg']!.complete(img);
    await c.backgroundLoaded;
    expect(c.background, same(img));
    c.dispose();
    expect(img.debugDisposed, isTrue);
  });

  test('no loader, no set folder or no background event: nothing is loaded', () {
    for (final c in [make(bg: 'bg.jpg', withLoader: false), make(bg: 'bg.jpg', inLibrary: false), make()]) {
      expect(c.background, isNull);
      c.dispose();
    }
    expect(requested, isEmpty);
  });

  test('changing the background (and undoing it) reloads; the old image is released', () async {
    final c = make(bg: 'a.jpg');
    final a = image();
    pending['a.jpg']!.complete(a);
    await c.backgroundLoaded;

    c.history.execute(SetBackgroundCommand('b.jpg'));
    expect(requested, ['a.jpg', 'b.jpg']);
    final b = image();
    pending['b.jpg']!.complete(b);
    await c.backgroundLoaded;
    expect(c.background, same(b));
    expect(a.debugDisposed, isTrue);

    c.undo();
    expect(requested.last, 'a.jpg');
    final a2 = image();
    pending['a.jpg']!.complete(a2);
    await c.backgroundLoaded;
    expect(c.background, same(a2));
    expect(b.debugDisposed, isTrue);

    // Unrelated edits don't reload.
    c.history.execute(SetValueCommand(SectionNames.metadata, 'Title', 'x'));
    expect(requested.length, 3);
    c.dispose();
  });

  test('a superseded load is dropped', () async {
    final c = make(bg: 'a.jpg');
    c.history.execute(SetBackgroundCommand('b.jpg'));
    final b = image();
    pending['b.jpg']!.complete(b);
    await c.backgroundLoaded;
    final late = image();
    pending['a.jpg']!.complete(late);
    await Future<void>.delayed(Duration.zero);
    expect(c.background, same(b));
    expect(late.debugDisposed, isTrue);
    c.dispose();
  });

  test('dim is clamped and kept in the view settings', () async {
    final temp = await Directory.systemTemp.createTemp('osuedit_view_');
    try {
      final f = File('${temp.path}/s.json');
      final s = await SettingsStore.load(f);
      expect(s.view.backgroundDim, 0.7);
      s.view.backgroundDim = 0.25;
      await s.save();
      expect((await SettingsStore.load(f)).view.backgroundDim, 0.25);
      await f.writeAsString('{"view":{"backgroundDim":3}}');
      expect((await SettingsStore.load(f)).view.backgroundDim, 1);
    } finally {
      await temp.delete(recursive: true);
    }

    final c = make();
    c.backgroundDim = -1;
    expect(c.backgroundDim, 0);
    c.dispose();
  });
}
