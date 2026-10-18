// Song select: the Update button appears when the osu! website's .osu differs
// from the local one, and replaces the local file.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/map_update_test.dart -d windows
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/platform/map_update_checker.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('Update button when the website version differs', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    // Give every difficulty a BeatmapID, as if it were submitted.
    final files = <File>[];
    for (final d in lib.root.listSync(recursive: true)) {
      if (d is File && d.path.endsWith('.osu')) {
        final text = d.readAsStringSync().replaceFirst('BeatmapID:0', 'BeatmapID:4242');
        d.writeAsStringSync(text);
        files.add(d);
      }
    }
    expect(files, isNotEmpty);
    final remote = Uint8List.fromList(utf8.encode('${files.first.readAsStringSync()}\n// changed online\n'));
    var fetches = 0;
    MapUpdateChecker.debugFetch = (id) async {
      fetches++;
      return remote;
    };
    addTearDown(() => MapUpdateChecker.debugFetch = null);

    await pumpApp(tester, lib);
    await openSet(tester, 'Sync Test');
    await waitFor(tester, find.text('Update'));
    await shot(tester, 'map_update_button');

    await tester.tap(find.text('Update'));
    await settle(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Update'));
    await settle(tester, const Duration(seconds: 2));
    expect(find.text('Update'), findsNothing);
    expect(fetches, greaterThan(0));
    await shot(tester, 'map_update_done');
  });
}
