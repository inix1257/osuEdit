import 'package:flutter/material.dart';

import '../../platform/beatmap_file_service.dart';
import '../../platform/skin_library.dart';
import '../../app_dialog.dart';

/// Picks the editor's skin: the built-in look or an imported `.osk`; also
/// imports and deletes skins. Applied live (the playfield follows
/// [SkinManager.current]).
Future<void> showSkinPicker(BuildContext context, {BeatmapFileService files = const BeatmapFileService()}) =>
    showDialog<void>(context: context, builder: (_) => _SkinPicker(files: files));

class _SkinPicker extends StatefulWidget {
  final BeatmapFileService files;

  const _SkinPicker({required this.files});

  @override
  State<_SkinPicker> createState() => _SkinPickerState();
}

class _SkinPickerState extends State<_SkinPicker> {
  final _manager = SkinManager.instance;
  List<SkinInfo>? _skins;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final skins = await _manager.library?.list() ?? const <SkinInfo>[];
    if (mounted) setState(() => _skins = skins);
  }

  Future<void> _run(Future<void> Function() job) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await job();
    } catch (e) {
      if (mounted) setState(() => _message = e is FormatException ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() => _run(() async {
        final lib = _manager.library;
        if (lib == null) return;
        final picked = await widget.files.pickOskFile();
        if (picked == null) return;
        final skin = await lib.importOsk(picked.bytes, fallbackName: picked.name);
        await _manager.select(skin);
        await _reload();
      });

  Future<void> _select(SkinInfo? skin) => _run(() => _manager.select(skin));

  Future<void> _delete(SkinInfo skin) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: const Text('Delete skin?'),
        content: Text('"${skin.name}" will be removed from the app.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      final wasSelected = _manager.selected == skin.folder;
      await _manager.library?.delete(skin);
      if (wasSelected) await _manager.select(null);
      await _reload();
    });
  }

  @override
  Widget build(BuildContext context) {
    final skins = _skins;
    return AppDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 12),
      titlePadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      title: Row(
        children: [
          Text('Skin', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          if (_busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: skins == null
            ? const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
            : ValueListenableBuilder(
                valueListenable: _manager.current,
                builder: (context, _, _) => ListView(
                  shrinkWrap: true,
                  children: [
                    _tile(null, 'Default', 'Built-in look'),
                    for (final s in skins) _tile(s, s.name, s.author == null ? null : 'by ${s.author}'),
                    if (_message != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                        child: Text(_message!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _busy || _manager.library == null ? null : _import,
          icon: const Icon(Icons.file_download_outlined),
          label: const Text('Import .osk'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }

  Widget _tile(SkinInfo? skin, String title, String? subtitle) {
    final selected = _manager.selected == skin?.folder;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? Theme.of(context).colorScheme.primary : null),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null ? null : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: skin == null
          ? null
          : IconButton(
              tooltip: 'Delete skin',
              icon: const Icon(Icons.delete_outline),
              onPressed: _busy ? null : () => _delete(skin),
            ),
      onTap: _busy || selected ? null : () => _select(skin),
    );
  }
}
