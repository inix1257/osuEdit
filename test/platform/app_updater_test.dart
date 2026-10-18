import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/platform/app_updater.dart';

Map<String, Object?> release(String tag, {String asset = 'osuEdit-x.apk', bool pre = false, bool draft = false}) => {
      'tag_name': tag,
      'prerelease': pre,
      'draft': draft,
      'body': 'notes $tag',
      'html_url': 'https://github.com/inix1257/osuEdit/releases/tag/$tag',
      'assets': [
        {'name': asset, 'size': 10, 'browser_download_url': 'https://example.com/$tag/$asset'},
      ],
    };

void main() {
  tearDown(() {
    AppUpdater.debugFetch = null;
    AppUpdater.debugVersion = null;
    AppUpdater.debugStateFile = null;
  });

  test('version parsing and comparison', () {
    expect(AppUpdater.parseVersion('v1.2.3'), [1, 2, 3]);
    expect(AppUpdater.parseVersion('0.1.0+4'), [0, 1, 0]);
    expect(AppUpdater.parseVersion('nightly'), isNull);
    int cmp(String a, String b) => AppUpdater.compareVersions(AppUpdater.parseVersion(a)!, AppUpdater.parseVersion(b)!);
    expect(cmp('1.0.1', '1.0.0'), greaterThan(0));
    expect(cmp('1.0', '1.0.0'), 0);
    expect(cmp('0.9.9', '0.10.0'), lessThan(0));
  });

  test('pickLatest: highest release with an osuEdit APK; skips drafts, pre-releases, old Java assets', () {
    final info = AppUpdater.pickLatest([
      release('v0.03', asset: 'app-release.apk'),
      release('v9.0.0', pre: true),
      release('v8.0.0', draft: true),
      release('v1.0.0'),
      release('v1.2.0'),
      release('v1.1.0'),
      release('v2.0.0', asset: 'notes.txt'),
    ]);
    expect(info?.version, '1.2.0');
    expect(info?.apkUrl, 'https://example.com/v1.2.0/osuEdit-x.apk');
    expect(info?.notes, 'notes v1.2.0');
    expect(AppUpdater.pickLatest([release('v0.03', asset: 'app-release.apk')]), isNull);
  });

  test('check: newer only, interval, skipped version, manual overrides', () async {
    final dir = await Directory.systemTemp.createTemp('upd');
    addTearDown(() => dir.delete(recursive: true));
    AppUpdater.debugStateFile = File('${dir.path}/state.json');
    var calls = 0;
    AppUpdater.debugFetch = () async {
      calls++;
      return [release('v1.1.0')];
    };

    AppUpdater.debugVersion = '1.1.0';
    expect(await AppUpdater.check(manual: true), isNull); // up to date
    AppUpdater.debugVersion = '1.0.0';
    expect(await AppUpdater.check(), isNull); // checked a moment ago
    expect(calls, 1);
    expect((await AppUpdater.check(manual: true))?.version, '1.1.0');
    await AppUpdater.skip('1.1.0');
    expect(await AppUpdater.check(), isNull); // interval again
    expect((await AppUpdater.check(manual: true))?.version, '1.1.0'); // manual ignores the skip
  });

  test('check: a failing fetch throws (the automatic caller ignores it)', () async {
    final dir = await Directory.systemTemp.createTemp('upd');
    addTearDown(() => dir.delete(recursive: true));
    AppUpdater.debugStateFile = File('${dir.path}/state.json');
    AppUpdater.debugVersion = '1.0.0';
    AppUpdater.debugFetch = () async => throw const SocketException('offline');
    await expectLater(AppUpdater.check(), throwsA(isA<SocketException>()));
  });
}
