import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'incoming_files.dart';

/// "Open map folder" (osu!'s "Open song folder"): shows a set's folder in
/// the platform's file browser.
///
/// Android: the library lives in private app storage, so the app exposes
/// it to the system Files app (`LibraryDocumentsProvider`) and opens the
/// folder there; files can be copied in and out from there. Desktop: the
/// system's file manager. iOS: not supported (the Files app only sees the
/// Documents root, where the library isn't).
abstract final class MapFolder {
  /// Replaces the platform call in tests.
  @visibleForTesting
  static Future<MapFolderResult> Function(String path)? debugOpen;

  /// Whether this platform can open folders at all.
  static bool get supported =>
      debugOpen != null || Platform.isAndroid || Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// Opens the folder at [path].
  static Future<MapFolderResult> open(String path) async {
    final hook = debugOpen;
    if (hook != null) return hook(path);
    try {
      if (Platform.isAndroid) {
        return switch (await IncomingFiles.channel.invokeMethod<String>('openFolder', path)) {
          'folder' => MapFolderResult.opened,
          'root' => MapFolderResult.openedLibraryRoot,
          _ => MapFolderResult.failed,
        };
      }
      // Explorer's exit code doesn't tell success; it opens a window or an
      // error dialog itself.
      if (Platform.isWindows) await Process.start('explorer', [path]);
      if (Platform.isMacOS) await Process.start('open', [path]);
      if (Platform.isLinux) await Process.start('xdg-open', [path]);
      return supported ? MapFolderResult.opened : MapFolderResult.failed;
    } on MissingPluginException {
      return MapFolderResult.failed;
    } on PlatformException {
      return MapFolderResult.failed;
    } on ProcessException {
      return MapFolderResult.failed;
    }
  }
}

enum MapFolderResult {
  opened,

  /// Android: the Files app could only be opened at the library's root
  /// (some Files apps don't open a given folder).
  openedLibraryRoot,
  failed,
}
