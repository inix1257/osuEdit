// Auto update check: a newer GitHub release on start shows the update dialog
// (Later / Skip this version / Update); the menu item checks by hand.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/update_dialog_test.dart -d windows
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/platform/app_updater.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('update dialog on start, skip, manual check', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    final dir = await Directory.systemTemp.createTemp('upd');
    AppUpdater.debugStateFile = File('${dir.path}/state.json');
    AppUpdater.debugSupported = true;
    AppUpdater.debugVersion = '0.1.0';
    AppUpdater.debugFetch = () async => [
          {
            'tag_name': 'v0.2.0',
            'prerelease': false,
            'draft': false,
            'body': '- Long-press a difficulty for a menu\n- Refresh feedback\n- Update check',
            'html_url': 'https://github.com/inix1257/osuEdit/releases/tag/v0.2.0',
            'assets': [
              {'name': 'osuEdit-0.2.0.apk', 'size': 1, 'browser_download_url': 'https://example.com/osuEdit-0.2.0.apk'},
            ],
          },
        ];
    addTearDown(() {
      AppUpdater.debugStateFile = null;
      AppUpdater.debugSupported = null;
      AppUpdater.debugVersion = null;
      AppUpdater.debugFetch = null;
      dir.deleteSync(recursive: true);
    });

    await pumpApp(tester, lib);
    await waitFor(tester, find.text('Update available: v0.2.0'));
    await shot(tester, 'update_dialog');

    await tester.tap(find.text('Skip this version'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(find.text('Update available: v0.2.0'), findsNothing);

    // The automatic check is quiet now (interval + skipped); the menu item
    // still finds it.
    await tester.tap(find.byTooltip('More'));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('Check for updates'));
    await waitFor(tester, find.text('Update available: v0.2.0'));
    await tester.tap(find.text('Later'));
    await settle(tester, const Duration(milliseconds: 400));

    AppUpdater.debugVersion = '0.2.0';
    await tester.tap(find.byTooltip('More'));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('Check for updates'));
    await waitFor(tester, find.textContaining("You're up to date"));
    await shot(tester, 'update_uptodate');
  });
}
