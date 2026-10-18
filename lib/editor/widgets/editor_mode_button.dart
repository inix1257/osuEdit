import 'package:flutter/material.dart';

/// The editor's screens (osu!stable's top-left mode tabs).
enum EditorMode {
  compose('Compose', Icons.edit),
  timing('Timing', Icons.timer_outlined),
  hitsound('Hitsound', Icons.music_note_outlined),
  songSetup('Song setup', Icons.tune);

  final String label;
  final IconData icon;
  const EditorMode(this.label, this.icon);
}

/// One button showing the current [mode]; tapping it opens a small list of
/// all modes just to its right, and picking one calls [onChanged]. Below
/// them, "Control Points" calls [onControlPoints] instead: a popup over
/// the current screen, not a mode.
class EditorModeButton extends StatelessWidget {
  final EditorMode mode;
  final ValueChanged<EditorMode> onChanged;
  final VoidCallback onControlPoints;

  const EditorModeButton({super.key, required this.mode, required this.onChanged, required this.onControlPoints});

  /// What the list returns for its "Control Points" entry.
  static const _controlPoints = 'controlPoints';

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject()! as RenderBox;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final picked = await showGeneralDialog<Object>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 100),
      pageBuilder: (_, _, _) => Stack(
        children: [
          Positioned(left: rect.right + 4, top: rect.top, child: _ModeList(current: mode)),
        ],
      ),
    );
    if (picked == _controlPoints) {
      onControlPoints();
    } else if (picked is EditorMode && picked != mode) {
      onChanged(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Editor screen',
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Material(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _open(context),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(mode.icon, size: 18, color: scheme.onSecondaryContainer),
                Text(
                  mode == EditorMode.songSetup ? 'Setup' : mode.label,
                  maxLines: 1,
                  style: TextStyle(fontSize: 10, height: 1.2, color: scheme.onSecondaryContainer),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeList extends StatelessWidget {
  final EditorMode current;
  const _ModeList({required this.current});

  Widget _item(BuildContext context, IconData icon, String label, Object result, {bool selected = false}) => InkWell(
    onTap: () => Navigator.pop(context, result),
    child: Container(
      height: 38,
      color: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Text(label),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 6,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final m in EditorMode.values)
              _item(context, m.icon, m.label, m, selected: m == current),
            const Divider(height: 1),
            _item(context, Icons.linear_scale, 'Control Points', EditorModeButton._controlPoints),
          ],
        ),
      ),
    );
  }
}
