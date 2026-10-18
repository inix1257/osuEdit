import 'package:flutter/services.dart';

/// `.osz` files handed to the app by other apps ("Open with", share sheet).
///
/// The native side copies each file into the library's inbox folder (see
/// `BeatmapLibrary.inboxes`) and then calls `changed` on this channel:
/// Android's MainActivity does so; on iOS the SceneDelegate copies into
/// Documents/Inbox and the library screen rescans when the app resumes.
abstract final class IncomingFiles {
  static const channel = MethodChannel('osuedit/incoming');

  /// Calls [onChanged] whenever new files have arrived. Replaces any earlier
  /// listener; pass null to stop.
  ///
  /// Then tells the native side Dart is listening (`ready`): files that
  /// arrived before that — the ones the app was launched with — are reported
  /// in its reply, so a cold start doesn't lose them.
  static Future<void> listen(void Function()? onChanged) async {
    channel.setMethodCallHandler(onChanged == null
        ? null
        : (call) async {
            if (call.method == 'changed') onChanged();
          });
    if (onChanged == null) return;
    try {
      if (await channel.invokeMethod<bool>('ready') == true) onChanged();
    } on MissingPluginException {
      // Desktop / tests: nothing hands files over.
    }
  }

  /// Android: opens the system "App info" page where the default app for
  /// `.osz` can be changed — osu!lazer's if it is installed (its "Open by
  /// default → Clear defaults" makes Android ask again), otherwise this app's.
  /// Returns which one was opened (`lazer` / `self`), or null if the platform
  /// can't (desktop, iOS) or the settings screen failed to open.
  static Future<String?> openDefaultAppSettings() async {
    try {
      return await channel.invokeMethod<String>('openDefaultAppSettings');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
