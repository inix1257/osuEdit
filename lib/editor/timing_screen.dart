import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_fonts.dart';
import '../core/core.dart';
import 'editor_controller.dart';
import 'editor_screen.dart' show formatEditorTime;
import 'widgets/form_fields.dart';
import 'widgets/setup_style.dart';

/// The Control Points popup: the timing point list on the left, the
/// selected point's settings on the right. Every change is one undoable
/// command on the editor's history. Shown under the editor's top bar, so
/// undo / redo and the playhead time come from the editor around it.
class ControlPointsPanel extends StatefulWidget {
  final EditorController controller;

  /// Closes the popup (a button in the header).
  final VoidCallback? onClose;

  const ControlPointsPanel({super.key, required this.controller, this.onClose});

  @override
  State<ControlPointsPanel> createState() => _ControlPointsPanelState();
}

class _ControlPointsPanelState extends State<ControlPointsPanel> {
  TimingPoint? _selected;

  /// Bumped when the user picks another point. Keys the point editor: an
  /// edit swaps in a new instance of the same point, which must keep the
  /// editor (and its scroll position) instead of building a fresh one.
  int _selection = 0;

  /// Points picked by long-press (multi-select). Active with two or more;
  /// the right side then edits only what they share.
  final Set<TimingPoint> _marked = LinkedHashSet.identity();

  bool get _multi => _marked.length >= 2;

  EditorController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    // Start on the point in effect at the playhead, or on the point an
    // undo / redo just brought up there.
    _selected = c.timing.effectivePointAt(c.time.value);
    _seenStep = c.lastHistoryStep.value;
    final f = _seenStep?.focus;
    if (f != null && f.area == EditArea.timing && f.time == c.time.value) _focusPoints(f);
  }

  /// The last undo / redo already shown.
  HistoryStep? _seenStep;

  /// Selects the points an undo / redo changed (several: multi-select), or
  /// the one in effect where it seeked when they are gone.
  void _focusPoints(EditFocus f) {
    final prev = _current;
    final points = f.timingPoints;
    // Already selected (an undo of an edit made here): keep the selection.
    final shown = _multi ? _currentMarked : [?prev];
    if (points.isNotEmpty && points.every((p) => shown.any((q) => identical(p, q)))) return;
    _marked.clear();
    if (points.length >= 2) _marked.addAll(points);
    final next = points.firstOrNull ?? c.timing.effectivePointAt(c.time.value);
    if (!identical(prev, next)) _selection++;
    _selected = next;
  }

  /// [p] if it is still in the map, else the point that replaced it.
  /// Undo / redo swap in another instance of an edited point: follow it
  /// (same time and kind) so the selection stays on it.
  TimingPoint? _resolve(TimingPoint p) {
    if (c.beatmap.indexOfTimingPoint(p) >= 0) return p;
    for (final q in c.beatmap.timingPoints) {
      if (q.time == p.time && q.uninherited == p.uninherited) return q;
    }
    return null;
  }

  /// The selected point, if it still exists.
  TimingPoint? get _current {
    final s = _selected;
    return s == null ? null : _selected = _resolve(s);
  }

  /// The multi-selection, following replaced points, in list order.
  List<TimingPoint> get _currentMarked {
    final now = [for (final m in _marked) ?_resolve(m)];
    _marked
      ..clear()
      ..addAll(now);
    return [for (final p in c.beatmap.timingPoints) if (_marked.contains(p)) p];
  }

  /// Commits a pending text edit to the point it was typed for, handing
  /// focus back to the editor (its keyboard shortcuts).
  void _commitText() =>
      FocusManager.instance.primaryFocus?.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);

  void _select(TimingPoint p) {
    _commitText();
    setState(() {
      if (!identical(p, _selected)) _selection++;
      _selected = p;
    });
    c.seek(p.time);
  }

  /// Long-press (or a tap while multi-selecting): adds [p] to the
  /// multi-selection, which starts from the selected point, or takes it
  /// out again.
  void _toggleMarked(TimingPoint p) {
    _commitText();
    setState(() {
      if (!_multi) {
        _marked.clear();
        final sel = _current;
        if (sel != null) _marked.add(sel);
      }
      if (!_marked.remove(p)) _marked.add(p);
      if (!_multi) {
        // Down to one point (or none): back to editing a single point.
        final single = _marked.isEmpty ? p : _marked.single;
        _marked.clear();
        if (!identical(single, _selected)) _selection++;
        _selected = single;
      }
    });
  }

  void _clearMarked() => setState(_marked.clear);

  void _add({required bool red}) {
    _commitText();
    setState(() {
      _marked.clear();
      _selection++;
      _selected = c.addTimingPoint(red: red);
    });
  }

  void _update(TimingPoint before, TimingPoint after) =>
      setState(() => _selected = c.updateTimingPoint(before, after));

  void _updateMarked(TimingPoint Function(TimingPoint) change) {
    final before = _currentMarked;
    final after = c.updateTimingPoints(before, change);
    setState(() {
      final i = before.indexWhere((m) => identical(m, _selected));
      _marked
        ..clear()
        ..addAll(after);
      if (i >= 0 && i < after.length) _selected = after[i];
    });
  }

  void _delete(TimingPoint p) {
    final points = c.beatmap.timingPoints;
    final i = points.indexOf(p);
    c.deleteTimingPoint(p);
    setState(() {
      _selection++;
      _selected = points.isEmpty ? null : points[(i - 1).clamp(0, points.length - 1)];
    });
  }

  void _deleteMarked() {
    final points = c.beatmap.timingPoints;
    final marked = _currentMarked;
    final i = points.indexOf(marked.first);
    c.deleteTimingPoints(marked);
    setState(() {
      _marked.clear();
      _selection++;
      _selected = points.isEmpty ? null : points[(i - 1).clamp(0, points.length - 1)];
    });
  }

  @override
  Widget build(BuildContext context) {
    final step = c.lastHistoryStep.value;
    if (!identical(step, _seenStep)) {
      _seenStep = step;
      if (step != null && step.focus.area == EditArea.timing) _focusPoints(step.focus);
    }
    final points = c.beatmap.timingPoints;
    final shown = _filter == _PointFilter.all ? points : [for (final p in points) if (_filter.accepts(p)) p];
    final marked = _multi ? _currentMarked : const <TimingPoint>[];
    // An undo can take the multi-selection down to one point.
    if (marked.length == 1) {
      _selected = marked.single;
      _marked.clear();
    }
    final multi = _multi;
    final sel = _current;
    final theme = setupTheme(Theme.of(context));
    final scheme = theme.colorScheme;
    return Theme(
      data: theme,
      child: Material(
        color: scheme.surface,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 6, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(theme),
                    const SizedBox(height: 4),
                    _listTools(shown),
                    const SizedBox(height: 4),
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: shown.isEmpty
                            ? Center(
                                child: Text(points.isEmpty
                                    ? 'No timing points. Add a timing (red) point first.'
                                    : 'No points match the filter.'),
                              )
                            : ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: ListView.builder(
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  itemCount: shown.length,
                                  itemExtent: _rowHeight,
                                  itemBuilder: (context, i) {
                                    final p = shown[i];
                                    return _PointRow(
                                      point: p,
                                      multi: multi,
                                      selected: multi ? _marked.contains(p) : identical(p, sel),
                                      onTap: () => multi ? _toggleMarked(p) : _select(p),
                                      onLongPress: () => _toggleMarked(p),
                                    );
                                  },
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: _editorWidth,
              child: multi
                  ? _MultiEditor(
                      points: marked,
                      onChanged: _updateMarked,
                      onDelete: _deleteMarked,
                      onClear: _clearMarked,
                    )
                  : sel == null
                      ? const Center(child: Text('Select a point'))
                      : _PointEditor(
                          key: ValueKey(_selection),
                          point: sel,
                          currentTime: () => c.timing.snap(c.time.value, c.divisor).roundToDouble(),
                          onChanged: (after) => _update(sel, after),
                          onDelete: () => _delete(sel),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  /// List row height and the settings column's width: as small as stays
  /// comfortable to tap, so the popup covers little of the screen.
  static const _rowHeight = 28.0;
  static const _editorWidth = 300.0;

  /// Which points the list shows.
  _PointFilter _filter = _PointFilter.all;

  /// Selects every point the list shows (multi-select with two or more).
  void _selectAll(List<TimingPoint> shown) {
    if (shown.isEmpty) return;
    if (shown.length == 1) return _select(shown.single);
    _commitText();
    setState(() {
      _marked
        ..clear()
        ..addAll(shown);
      if (!_marked.contains(_selected)) {
        _selection++;
        _selected = shown.first;
      }
    });
  }

  /// Under the header: the list filter and "Select all".
  Widget _listTools(List<TimingPoint> shown) => Row(
    children: [
      const Icon(Icons.filter_list, size: 18),
      const SizedBox(width: 6),
      SetupChoicePill<_PointFilter>(
        value: _filter,
        choices: _PointFilter.values,
        name: (f) => f.label,
        tooltip: 'Filter',
        onPick: (f) => setState(() => _filter = f),
      ),
      const SizedBox(width: 8),
      Text('${shown.length} shown', style: Theme.of(context).textTheme.bodySmall),
      const Spacer(),
      TextButton.icon(
        onPressed: shown.isEmpty ? null : () => _selectAll(shown),
        icon: const Icon(Icons.select_all, size: 18),
        label: const Text('Select all'),
      ),
    ],
  );

  Widget _header(ThemeData theme) {
    final s = theme.colorScheme;
    return Row(
      children: [
        Icon(Icons.linear_scale, size: 16, color: s.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Control Points'.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: s.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.1,
            ),
          ),
        ),
        FilledButton.tonalIcon(
          onPressed: () => _add(red: true),
          icon: const Icon(Icons.add, color: _red, size: 18),
          label: const Text('Timing'),
        ),
        const SizedBox(width: 6),
        FilledButton.tonalIcon(
          onPressed: c.timing.redPoints.isEmpty ? null : () => _add(red: false),
          icon: const Icon(Icons.add, color: _green, size: 18),
          label: const Text('Inherited'),
        ),
        if (widget.onClose != null)
          IconButton(tooltip: 'Close', onPressed: widget.onClose, icon: const Icon(Icons.close, size: 20)),
      ],
    );
  }
}

/// The Control Points list filter.
enum _PointFilter {
  all('All points'),
  timing('Timing'),
  inherited('Inherited'),
  kiai('Kiai');

  final String label;
  const _PointFilter(this.label);

  bool accepts(TimingPoint p) => switch (this) {
    all => true,
    timing => p.uninherited,
    inherited => !p.uninherited,
    kiai => p.kiai,
  };
}

const _red = Color(0xFFE53935);
const _green = Color(0xFF43A047);

const _editorPadding = EdgeInsets.fromLTRB(6, 8, 12, 4);

/// Typed slider velocity: 0.01–10x (the slider only covers 0.1–4x).
double? _parseSv(String s) {
  final v = double.tryParse(s);
  return v != null && v >= 0.01 && v <= 10 ? v : null;
}

/// Typed volume: a whole 5–100 %.
double? _parseVolume(String s) {
  final v = int.tryParse(s);
  return v != null && v >= 5 && v <= 100 ? v.toDouble() : null;
}

String _sampleSetName(int s) => s == SampleSet.auto ? 'Auto' : SampleSet.name(s);

const _sampleSets = [SampleSet.auto, SampleSet.normal, SampleSet.soft, SampleSet.drum];

String _fmt(double v, [int digits = 2]) => formatNumber(double.parse(v.toStringAsFixed(digits)));

class _PointRow extends StatelessWidget {
  final TimingPoint point;
  final bool selected;

  /// Multi-select is on: rows show a check box.
  final bool multi;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _PointRow({
    required this.point,
    required this.selected,
    required this.multi,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final p = point;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final main = p.uninherited ? '${_fmt(p.bpm)} BPM  ${p.meter}/4' : '${_fmt(p.sliderVelocity)}x SV';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: () {
            HapticFeedback.selectionClick();
            onLongPress();
          },
          child: Row(
            children: [
              const SizedBox(width: 8),
              Container(
                width: 4,
                height: 18,
                decoration: BoxDecoration(
                  color: p.uninherited ? _red : _green,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              if (multi)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(selected ? Icons.check_box : Icons.check_box_outline_blank, size: 18),
                ),
              const SizedBox(width: 10),
              SizedBox(
                width: 84,
                child: Text(formatEditorTime(p.time), style: monoNumbers),
              ),
              Expanded(child: Text(main, maxLines: 1, overflow: TextOverflow.ellipsis)),
              Text(
                '${_sampleSetName(p.sampleSet)}${p.sampleIndex > 0 ? ':${p.sampleIndex}' : ''} · ${p.volume}%',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              SizedBox(
                width: 28,
                child: p.kiai ? const Icon(Icons.star, size: 16, color: Color(0xFFFFB300)) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sample set (pill menu) and custom index, one row.
Widget _sampleRow({
  required int? sampleSet,
  required String index,
  required ValueChanged<int> onSet,
  required bool Function(int) onIndex,
}) =>
    Row(
      children: [
        const Expanded(child: Text('Sample set')),
        SetupChoicePill<int>(
          value: sampleSet,
          choices: _sampleSets,
          name: _sampleSetName,
          tooltip: 'Sample set',
          onPick: onSet,
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 72,
          child: CommitTextField(
            label: 'Custom',
            value: index,
            keyboardType: TextInputType.number,
            onCommit: (s) {
              final i = int.tryParse(s.trim());
              if (i == null || i < 0) return false;
              return onIndex(i);
            },
          ),
        ),
      ],
    );

class _PointEditor extends StatelessWidget {
  final TimingPoint point;
  final double Function() currentTime;
  final ValueChanged<TimingPoint> onChanged;
  final VoidCallback onDelete;

  const _PointEditor({
    super.key,
    required this.point,
    required this.currentTime,
    required this.onChanged,
    required this.onDelete,
  });

  static const _meters = [1, 2, 3, 4, 5, 6, 7, 8];

  /// Applies an effects bit.
  TimingPoint _withEffect(int bit, bool on) =>
      point.copyWith(effects: on ? point.effects | bit : point.effects & ~bit);

  @override
  Widget build(BuildContext context) {
    final p = point;
    const gap = SizedBox(height: 8);
    final omit = p.effects & TimingEffects.omitFirstBarLine != 0;
    return ListView(
      padding: _editorPadding,
      children: [
        SetupSection(
          marker: p.uninherited ? _red : _green,
          title: p.uninherited ? 'Timing point' : 'Inherited point',
          subtitle: formatEditorTime(p.time),
          trailing: [
            IconButton(tooltip: 'Delete point', onPressed: onDelete, icon: const Icon(Icons.delete_outline, size: 20)),
          ],
          children: [
            Row(
              children: [
                Expanded(
                  child: CommitTextField(
                    label: 'Offset',
                    suffix: 'ms',
                    value: formatNumber(p.time),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    onCommit: (s) {
                      final t = double.tryParse(s.trim());
                      if (t == null || !t.isFinite) return false;
                      onChanged(p.copyWith(time: t));
                      return true;
                    },
                  ),
                ),
                const SizedBox(width: 6),
                TextButton(
                  onPressed: () => onChanged(p.copyWith(time: currentTime())),
                  child: const Text('Use current'),
                ),
              ],
            ),
            gap,
            if (p.uninherited) ...[
              Row(
                children: [
                  Expanded(
                    child: CommitTextField(
                      label: 'BPM',
                      value: _fmt(p.bpm, 3),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onCommit: (s) {
                        final bpm = double.tryParse(s.trim());
                        if (bpm == null || !(bpm > 0 && bpm <= 10000)) return false;
                        onChanged(p.copyWith(beatLength: 60000 / bpm));
                        return true;
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  SetupChoicePill<int>(
                    value: p.meter,
                    choices: [..._meters, if (!_meters.contains(p.meter)) p.meter],
                    name: (m) => '$m/4',
                    tooltip: 'Meter',
                    onPick: (m) => onChanged(p.copyWith(meter: m)),
                  ),
                ],
              ),
              gap,
              SetupRow(
                label: 'Omit first bar line',
                trailing: Switch(
                  value: omit,
                  onChanged: (v) => onChanged(_withEffect(TimingEffects.omitFirstBarLine, v)),
                ),
                onTap: () => onChanged(_withEffect(TimingEffects.omitFirstBarLine, !omit)),
              ),
            ] else
              CommitSlider(
                label: 'Slider velocity',
                value: p.sliderVelocity,
                min: 0.1,
                max: 4,
                divisions: 78,
                format: (v) => '${_fmt(v)}x',
                fieldFormat: (v) => _fmt(v, 3),
                fieldSuffix: 'x',
                parse: _parseSv,
                onCommit: (v) => onChanged(p.copyWith(beatLength: -100 / double.parse(v.toStringAsFixed(4)))),
              ),
          ],
        ),
        SetupSection(
          icon: Icons.music_note_outlined,
          title: 'Sounds & kiai',
          children: [
            _sampleRow(
              sampleSet: p.sampleSet.clamp(0, 3),
              index: '${p.sampleIndex}',
              onSet: (s) => onChanged(p.copyWith(sampleSet: s)),
              onIndex: (i) {
                onChanged(p.copyWith(sampleIndex: i));
                return true;
              },
            ),
            gap,
            CommitSlider(
              label: 'Volume',
              value: p.volume.toDouble(),
              min: 5,
              max: 100,
              divisions: 95,
              format: (v) => '${v.round()}%',
              fieldFormat: (v) => '${v.round()}',
              fieldSuffix: '%',
              parse: _parseVolume,
              onCommit: (v) => onChanged(p.copyWith(volume: v.round())),
            ),
            SetupRow(
              label: 'Kiai time',
              trailing: Switch(value: p.kiai, onChanged: (v) => onChanged(_withEffect(TimingEffects.kiai, v))),
              onTap: () => onChanged(_withEffect(TimingEffects.kiai, !p.kiai)),
            ),
          ],
        ),
      ],
    );
  }
}

/// Settings shared by several points (sample set, custom index, volume,
/// kiai); each change applies to all of them as one undo step. Values that
/// differ show as mixed until set.
class _MultiEditor extends StatelessWidget {
  final List<TimingPoint> points;
  final void Function(TimingPoint Function(TimingPoint)) onChanged;
  final VoidCallback onDelete;
  final VoidCallback onClear;

  const _MultiEditor({required this.points, required this.onChanged, required this.onDelete, required this.onClear});

  /// The value all points share, or null if they differ.
  T? _shared<T>(T Function(TimingPoint) of) {
    final v = of(points.first);
    return points.every((p) => of(p) == v) ? v : null;
  }

  @override
  Widget build(BuildContext context) {
    final sampleSet = _shared((p) => p.sampleSet.clamp(0, 3));
    final index = _shared((p) => p.sampleIndex);
    final volume = _shared((p) => p.volume);
    final kiai = _shared((p) => p.kiai);
    // Mixed or off → all on; all on → all off.
    void toggleKiai() {
      final on = kiai != true;
      onChanged((p) => p.copyWith(effects: on ? p.effects | TimingEffects.kiai : p.effects & ~TimingEffects.kiai));
    }

    return ListView(
      padding: _editorPadding,
      children: [
        SetupSection(
          icon: Icons.checklist,
          title: '${points.length} points selected',
          trailing: [
            IconButton(tooltip: 'Clear selection', onPressed: onClear, icon: const Icon(Icons.close, size: 20)),
            IconButton(
              tooltip: 'Delete ${points.length} points',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline, size: 20),
            ),
          ],
          children: [
            _sampleRow(
              sampleSet: sampleSet,
              index: index == null ? '' : '$index',
              onSet: (s) => onChanged((p) => p.copyWith(sampleSet: s)),
              onIndex: (i) {
                onChanged((p) => p.copyWith(sampleIndex: i));
                return true;
              },
            ),
            const SizedBox(height: 8),
            CommitSlider(
              label: volume == null ? 'Volume (mixed)' : 'Volume',
              value: (volume ?? points.first.volume).toDouble(),
              min: 5,
              max: 100,
              divisions: 95,
              format: (v) => '${v.round()}%',
              fieldFormat: (v) => volume == null ? '' : '${v.round()}',
              fieldSuffix: '%',
              parse: _parseVolume,
              onCommit: (v) => onChanged((p) => p.copyWith(volume: v.round())),
            ),
            SetupRow(
              label: 'Kiai time',
              subtitle: kiai == null ? 'Mixed' : null,
              trailing: Switch(value: kiai == true, onChanged: (_) => toggleKiai()),
              onTap: toggleKiai,
            ),
          ],
        ),
      ],
    );
  }
}
