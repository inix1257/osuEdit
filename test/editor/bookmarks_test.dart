import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// P2: bookmark editing. sample_v14 has `Bookmarks: 1000,6333` and 180 BPM
/// from 1000 (1/4 snap = 83.33 ms).
void main() {
  final src = File('test/fixtures/sample_v14.osu').readAsStringSync();
  EditorController sample() => EditorController(
        beatmap: OsuParser.parse(src),
        document: const BeatmapDocument(fileName: 'sample.osu'),
      );

  test('toggle adds at the snapped time, then removes; each is one undo step', () {
    final c = sample();
    c.seek(2010); // snaps to 2000
    expect(c.bookmarkHere, isNull);
    c.toggleBookmark();
    expect(c.beatmap.bookmarks, [1000, 2000, 6333]);
    expect(c.serialize(), contains('Bookmarks: 1000,2000,6333'));

    c.seek(2030); // within half a snap step of 2000
    expect(c.bookmarkHere, 2000);
    c.toggleBookmark();
    expect(c.beatmap.bookmarks, [1000, 6333]);

    c.undo();
    expect(c.beatmap.bookmarks, [1000, 2000, 6333]);
    c.undo();
    expect(c.serialize(), src); // byte-for-byte back
  });

  test('previous / next bookmark', () {
    final c = sample();
    c.seek(3000);
    c.seekBookmark(forward: true);
    expect(c.time.value, 6333);
    c.seekBookmark(forward: true); // none after: stays
    expect(c.time.value, 6333);
    c.seekBookmark(forward: false);
    expect(c.time.value, 1000);
  });

  test('removing every bookmark drops the line; undo restores it in place', () {
    final c = sample();
    c.removeAllBookmarks();
    expect(c.beatmap.bookmarks, isEmpty);
    expect(c.serialize(), isNot(contains('Bookmarks')));
    c.removeAllBookmarks(); // nothing left: no extra undo step
    c.undo();
    expect(c.serialize(), src);
    expect(c.canUndo, isFalse);

    // Removing the last one by toggling also drops the line.
    c.seek(1000);
    c.toggleBookmark();
    c.seek(6333);
    c.toggleBookmark();
    expect(c.serialize(), isNot(contains('Bookmarks')));
  });

  test('RemoveValueCommand is a no-op for a missing key', () {
    final b = OsuParser.parse(src);
    final cmd = RemoveValueCommand(SectionNames.editor, 'Nope');
    final rev = b.revision;
    cmd.apply(b);
    cmd.revert(b);
    expect(b.revision, rev);
    expect(OsuWriter.write(b), src);
  });
}
