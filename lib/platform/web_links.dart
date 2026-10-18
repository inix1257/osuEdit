import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'incoming_files.dart';

/// Opens web pages (a map's osu! website page) in the system browser.
abstract final class WebLinks {
  /// Replaces the platform call in tests (no browser pops up).
  @visibleForTesting
  static Future<bool> Function(String url)? debugOpen;

  /// Opens [url]; false when no browser could be started.
  static Future<bool> open(String url) async {
    final hook = debugOpen;
    if (hook != null) return hook(url);
    try {
      if (Platform.isAndroid) return await IncomingFiles.channel.invokeMethod<bool>('openUrl', url) ?? false;
      if (Platform.isWindows) {
        await Process.start('rundll32', ['url.dll,FileProtocolHandler', url]);
        return true;
      }
      if (Platform.isMacOS) {
        await Process.start('open', [url]);
        return true;
      }
      if (Platform.isLinux) {
        await Process.start('xdg-open', [url]);
        return true;
      }
      return false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } on ProcessException {
      return false;
    }
  }
}
