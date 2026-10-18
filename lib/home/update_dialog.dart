import 'dart:io';

import 'package:flutter/material.dart';

import '../platform/app_updater.dart';
import '../platform/web_links.dart';

/// Looks for a newer release and offers it. [manual] (the menu item) also
/// says "up to date" / "couldn't check"; the automatic check on start stays
/// silent unless there is something to install.
Future<void> checkForUpdates(BuildContext context, {bool manual = false}) async {
  final messenger = ScaffoldMessenger.of(context);
  final UpdateInfo? info;
  try {
    info = await AppUpdater.check(manual: manual);
  } catch (_) {
    if (manual) messenger.showSnackBar(const SnackBar(content: Text('Could not check for updates')));
    return;
  }
  if (!context.mounted) return;
  if (info == null) {
    if (manual) {
      final v = await AppUpdater.currentVersion();
      messenger.showSnackBar(SnackBar(content: Text("You're up to date${v == null ? '' : ' (v$v)'}")));
    }
    return;
  }
  await showDialog<void>(context: context, builder: (_) => _UpdateDialog(info!));
}

class _UpdateDialog extends StatefulWidget {
  final UpdateInfo info;
  const _UpdateDialog(this.info);

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  /// Null: asking; 0..1: downloading.
  double? _progress;
  String? _error;

  Future<void> _update() async {
    final info = widget.info;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      final apk = await AppUpdater.download(info, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      final r = await AppUpdater.install(apk);
      if (!mounted) return;
      switch (r) {
        case InstallResult.started:
          navigator.pop();
        case InstallResult.needsPermission:
          navigator.pop();
          messenger.showSnackBar(const SnackBar(
            content: Text('Allow installs from osuEdit in the settings that just opened, then check for updates again.'),
            duration: Duration(seconds: 8),
          ));
        case InstallResult.failed:
          setState(() {
            _progress = null;
            _error = 'Could not start the installer.';
          });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _progress = null;
        _error = e is HttpException ? e.message : 'Download failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final downloading = _progress != null;
    return PopScope(
      canPop: !downloading,
      child: AlertDialog(
        title: Text('Update available: v${info.version}'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (downloading) ...[
              Text('Downloading… ${(_progress! * 100).round()}%'),
              const SizedBox(height: 10),
              LinearProgressIndicator(value: _progress == 0 ? null : _progress),
            ] else ...[
              if (info.notes.isNotEmpty)
                Flexible(child: SingleChildScrollView(child: Text(info.notes, style: const TextStyle(fontSize: 13))))
              else
                const Text('A new version of osuEdit is available.'),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ]),
        ),
        actions: downloading
            ? null
            : [
                TextButton(
                  onPressed: () {
                    AppUpdater.skip(info.version);
                    Navigator.pop(context);
                  },
                  child: const Text('Skip this version'),
                ),
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),
                if (AppUpdater.supported)
                  FilledButton(onPressed: _update, child: const Text('Update'))
                else
                  FilledButton(
                    onPressed: () {
                      WebLinks.open(info.pageUrl);
                      Navigator.pop(context);
                    },
                    child: const Text('Open release page'),
                  ),
              ],
      ),
    );
  }
}
