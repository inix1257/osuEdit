import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_fonts.dart';
import '../../core/core.dart';
import '../editor_controller.dart';
import 'editor_icons.dart';
import 'form_fields.dart';

/// Editor chrome sizes. Phones get the compact stable-like strips; tablets
/// (shortest side ≥ 600 dp) get wider toolboxes and taller bars so touch
/// targets and the timeline grow with the screen.
class EditorLayout {
  final double toolboxWidth;
  final double maxTile;
  final double topBarHeight;
  final double bottomBarHeight;

  const EditorLayout._(this.toolboxWidth, this.maxTile, this.topBarHeight, this.bottomBarHeight);

  /// Empty strip above the timeline. The Android status-bar swipe starts at
  /// the very top edge, so a finger scrubbing the timeline needs this much
  /// room before it can drift into the system gesture.
  static const topDeadZone = 12.0;

  static const phone = EditorLayout._(60, 60, 44 + topDeadZone, 40);
  static const tablet = EditorLayout._(76, 76, 64 + topDeadZone, 40);

  static const tabletShortestSide = 600.0;

  static EditorLayout forSize(Size size) => size.shortestSide >= tabletShortestSide ? tablet : phone;

  static EditorLayout of(BuildContext context) => forSize(MediaQuery.sizeOf(context));
}

/// One square-ish toolbox button: icon over a short label, highlighted when
/// [active]. Shared by both side toolboxes.
class ToolboxTile extends StatelessWidget {
  /// Material icon, or [glyph] for an editor-specific painted one.
  final IconData? icon;
  final EditorGlyph? glyph;
  final String label;
  final String tooltip;
  final bool active;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const ToolboxTile({
    super.key,
    this.icon,
    this.glyph,
    required this.label,
    required this.tooltip,
    this.active = false,
    this.onTap,
    this.onLongPress,
  }) : assert((icon == null) != (glyph == null));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = active ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Material(
          color: active ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            onLongPress: onLongPress,
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (glyph case final g?)
                      EditorGlyphIcon(g, size: 20, color: fg)
                    else
                      Icon(icon, size: 20, color: fg),
                    Text(label, style: TextStyle(fontSize: 10, color: fg)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Lays [children] out in a column of equal tiles, at most [maxTile] tall
/// each, so the toolboxes fill short phone screens and stay compact on
/// tablets.
class _TileColumn extends StatelessWidget {
  final List<Widget> children;
  const _TileColumn({required this.children});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final h = math.min(EditorLayout.of(context).maxTile, (constraints.maxHeight - 8) / children.length);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [for (final c in children) SizedBox(height: h, child: c)],
        ),
      );
    });
  }
}

/// Left toolbox (stable's compose tools): sample set, addition set, then
/// select / circle / slider / spinner.
class ComposeToolbox extends StatelessWidget {
  final EditorController controller;
  const ComposeToolbox({super.key, required this.controller});

  static const _tools = [
    (EditorTool.select, Icons.near_me, null, 'Select', '1'),
    (EditorTool.circle, Icons.circle_outlined, null, 'Circle', '2'),
    (EditorTool.slider, null, EditorGlyph.slider, 'Slider', '3'),
    (EditorTool.spinner, null, EditorGlyph.spinner, 'Spinner', '4'),
  ];

  static const _sets = [SampleSet.auto, SampleSet.normal, SampleSet.soft, SampleSet.drum];

  static String _setName(int? id) => switch (id) {
        null => '—',
        SampleSet.auto => 'Auto',
        _ => SampleSet.name(id),
      };

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SizedBox(
        width: EditorLayout.of(context).toolboxWidth,
        child: _TileColumn(children: [
          _SetPicker(
            label: 'Sample',
            tooltip: 'Sample set',
            icon: Icons.music_note_outlined,
            value: c.normalSetState,
            name: _setName,
            options: _sets,
            onSelected: c.setNormalSet,
          ),
          _SetPicker(
            label: 'Addition',
            tooltip: 'Addition sample set',
            icon: Icons.library_music_outlined,
            value: c.additionSetState,
            name: _setName,
            options: _sets,
            onSelected: c.setAdditionSet,
          ),
          for (final (tool, icon, glyph, label, key) in _tools)
            ToolboxTile(
              icon: icon,
              glyph: glyph,
              label: label,
              tooltip: '$label ($key)',
              active: c.tool == tool,
              onTap: () => c.tool = tool,
            ),
        ]),
      ),
    );
  }
}

class _SetPicker extends StatelessWidget {
  final String label;
  final String tooltip;
  final IconData icon;
  final int? value;
  final String Function(int?) name;
  final List<int> options;
  final ValueChanged<int> onSelected;

  const _SetPicker({
    required this.label,
    required this.tooltip,
    required this.icon,
    required this.value,
    required this.name,
    required this.options,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<int>(
      tooltip: tooltip,
      initialValue: value,
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final o in options) PopupMenuItem(value: o, child: Text('$label: ${name(o)}')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: scheme.onSurfaceVariant),
                Text(label, style: TextStyle(fontSize: 9, color: scheme.onSurfaceVariant)),
                Text(name(value), style: TextStyle(fontSize: 11, color: scheme.primary)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Right toolbox: new combo, whistle / finish / clap, grid snap, distance
/// snap, lock notes. Combo / hitsound toggles act on the selection, or on
/// the next placed object when nothing is selected.
class HitsoundToolbox extends StatelessWidget {
  final EditorController controller;
  const HitsoundToolbox({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    Widget addition(int flag, String label, String key, {IconData? icon, EditorGlyph? glyph}) =>
        ToolboxTile(
          icon: icon,
          glyph: glyph,
          label: label,
          tooltip: '$label ($key)',
          active: c.additionState(flag),
          onTap: () => c.toggleAddition(flag),
        );
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SizedBox(
        width: EditorLayout.of(context).toolboxWidth,
        child: _TileColumn(children: [
          Builder(builder: (tileContext) {
            final skip = c.comboSkipState ?? 0;
            return ToolboxTile(
              icon: Icons.fiber_new_outlined,
              label: skip > 0 ? 'NC +$skip' : 'NC',
              tooltip: 'New combo (Q) · long-press: colour skip',
              active: c.newComboState,
              onTap: c.toggleNewCombo,
              onLongPress: () => showComboSkipPicker(tileContext, c),
            );
          }),
          addition(HitSoundFlags.whistle, 'Whistle', 'W', glyph: EditorGlyph.whistle),
          addition(HitSoundFlags.finish, 'Finish', 'E', glyph: EditorGlyph.finish),
          addition(HitSoundFlags.clap, 'Clap', 'R', icon: Icons.back_hand_outlined),
          Builder(
            builder: (tileContext) => ToolboxTile(
              icon: Icons.grid_4x4,
              label: 'Grid ${c.gridSize}',
              tooltip: 'Grid snap (T) · long-press: grid size',
              active: c.gridSnap,
              onTap: () => c.gridSnap = !c.gridSnap,
              onLongPress: () => showGridSettings(tileContext, c),
            ),
          ),
          Builder(
            builder: (tileContext) => ToolboxTile(
              icon: Icons.straighten,
              label: 'Dist ${formatSpacing(c.distanceSpacing)}×',
              tooltip: 'Distance snap (Y) · long-press: distance spacing',
              active: c.distanceSnap,
              onTap: () => c.distanceSnap = !c.distanceSnap,
              onLongPress: () => showDistanceSettings(tileContext, c),
            ),
          ),
          ToolboxTile(
            icon: c.lockNotes ? Icons.lock_outline : Icons.lock_open,
            label: 'Lock',
            tooltip: 'Lock notes (L)',
            active: c.lockNotes,
            onTap: () => c.lockNotes = !c.lockNotes,
          ),
        ]),
      ),
    );
  }
}

/// A distance spacing as stable shows it: one decimal, two when needed
/// (1.0, 1.25).
String formatSpacing(double v) {
  final two = v.toStringAsFixed(2);
  return two.endsWith('0') ? v.toStringAsFixed(1) : two;
}

/// Shows [panel] as a side panel just left of [context]'s button (no
/// barrier tint; a tap outside closes it), kept inside the screen.
Future<void> _showSidePanel(BuildContext context, double height, Widget panel) {
  final box = context.findRenderObject()! as RenderBox;
  final rect = box.localToGlobal(Offset.zero) & box.size;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 100),
    pageBuilder: (ctx, _, _) {
      final screen = MediaQuery.sizeOf(ctx);
      return Stack(
        children: [
          Positioned(
            right: screen.width - rect.left + 4,
            top: math.max(4, math.min(rect.top, screen.height - height - 4)),
            child: panel,
          ),
        ],
      );
    },
  );
}

class _SidePanel extends StatelessWidget {
  final String title;
  final EditorController controller;
  final List<Widget> Function(EditorController c) children;
  const _SidePanel({required this.title, required this.controller, required this.children});

  static const width = 280.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 6,
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                ...children(controller),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Grid size ([Editor] value saved with the map; each change is one undo
/// step), as a side panel beside the Grid button.
Future<void> showGridSettings(BuildContext context, EditorController c) => _showSidePanel(
      context,
      90,
      _SidePanel(
        title: 'Grid size',
        controller: c,
        children: (c) => [
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              for (final g in EditorController.gridSizes) ButtonSegment(value: g, label: Text('$g')),
            ],
            selected: {c.gridSize},
            onSelectionChanged: (v) => c.setGridSize(v.first),
          ),
        ],
      ),
    );

/// Distance spacing, as a side panel beside the Dist button.
Future<void> showDistanceSettings(BuildContext context, EditorController c) => _showSidePanel(
      context,
      170,
      _SidePanel(
        title: 'Distance snap',
        controller: c,
        children: (c) => [
          // The slider steps 0.1 (stable's Alt+scroll); the field and the ±
          // buttons 0.01 (Alt+Shift+scroll).
          CommitSlider(
            label: 'Distance spacing',
            value: c.distanceSpacing,
            min: EditorController.minDistanceSpacing,
            max: EditorController.maxDistanceSpacing,
            divisions: 59,
            format: (v) => '${formatSpacing(v)}×',
            parse: (t) => double.tryParse(t.trim().replaceAll('×', '').replaceAll('x', '')),
            fieldFormat: formatSpacing,
            fieldSuffix: '×',
            onCommit: c.setDistanceSpacing,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              for (final d in const [-0.01, 0.01])
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: OutlinedButton(
                    onPressed: () => c.setDistanceSpacing(c.distanceSpacing + d),
                    style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                    child: Text(d < 0 ? '−0.01' : '+0.01', style: monoNumbers),
                  ),
                ),
            ],
          ),
        ],
      ),
    );

/// Long-press menu of the NC button: how many combo colours the new combo
/// skips ("colour hax", 0-7), shown just left of [context]'s button. Each
/// choice previews the colour it gives when there is a single target.
Future<void> showComboSkipPicker(BuildContext context, EditorController c) async {
  final box = context.findRenderObject()! as RenderBox;
  final rect = box.localToGlobal(Offset.zero) & box.size;
  final current = c.comboSkipState;
  final base = c.comboSkipBaseColour;
  final picked = await showGeneralDialog<int>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 100),
    pageBuilder: (ctx, _, _) {
      final screen = MediaQuery.sizeOf(ctx);
      return Stack(
        children: [
          Positioned(
            right: screen.width - rect.left + 4,
            top: math.max(4, math.min(rect.top, screen.height - _ComboSkipPanel.height - 4)),
            child: _ComboSkipPanel(
              current: current,
              colourOf: base == null ? null : (n) => c.comboColourAt(base + n),
            ),
          ),
        ],
      );
    },
  );
  if (picked != null) c.setComboSkip(picked);
}

class _ComboSkipPanel extends StatelessWidget {
  final int? current;
  final Color Function(int skip)? colourOf;

  const _ComboSkipPanel({required this.current, required this.colourOf});

  static const _cell = 44.0, _gap = 4.0, _pad = 8.0, _header = 22.0;
  static const _perRow = 4;
  static const height = _pad * 2 + _header + _cell * 2 + _gap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget cell(int n) {
      final colour = colourOf?.call(n);
      final selected = n == current;
      final fg = colour == null
          ? scheme.onSurface
          : (colour.computeLuminance() > 0.45 ? Colors.black : Colors.white);
      return Padding(
        padding: EdgeInsets.only(left: n % _perRow == 0 ? 0 : _gap),
        child: Material(
          color: colour ?? scheme.surfaceContainerHighest,
          shape: CircleBorder(
            side: selected
                ? BorderSide(color: scheme.primary, width: 3)
                : BorderSide(color: scheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => Navigator.pop(context, n),
            child: SizedBox.square(
              dimension: _cell,
              child: Center(
                child: Text('$n', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: fg)),
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 6,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.all(_pad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: _header,
              child: Text('Combo colour skip', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ),
            Row(children: [for (var n = 0; n < _perRow; n++) cell(n)]),
            const SizedBox(height: _gap),
            Row(children: [for (var n = _perRow; n <= EditorController.maxComboSkip; n++) cell(n)]),
          ],
        ),
      ),
    );
  }
}
