import 'package:flutter/material.dart';

import '../core/core.dart';
import 'editor_controller.dart';
import 'editor_screen.dart' show formatEditorTime;
import 'widgets/form_fields.dart';
import 'widgets/setup_style.dart';
import '../toast.dart';
import '../app_dialog.dart';

/// The editor's Song setup mode: metadata, the set's audio / background
/// files, difficulty settings and preview time. Every field commits on its
/// own (one undo step each, like the timing screen) and shows the map's
/// current value, so undo / redo and mode switches never leave stale text.
/// Rebuilt by the editor screen whenever the controller notifies.
class SongSetupPanel extends StatelessWidget {
  final EditorController controller;

  /// Pick a file and make it the map's audio / background (the editor
  /// screen's pickers, which also report errors).
  final VoidCallback onSetAudio;
  final VoidCallback onSetBackground;

  /// Add a difficulty to the set: empty, or ([copy]) with this one's
  /// objects and timing (the editor screen's dialogs; may switch to it).
  final void Function(bool copy) onNewDifficulty;

  /// Delete this difficulty from the set (the editor screen asks first and
  /// closes the editor). Null: no button.
  final VoidCallback? onDeleteDifficulty;

  const SongSetupPanel({
    super.key,
    required this.controller,
    required this.onSetAudio,
    required this.onSetBackground,
    required this.onNewDifficulty,
    this.onDeleteDifficulty,
  });

  /// `[Metadata]` fields, one row each (romanised / unicode side by side).
  static const List<List<_TextKey>> _metadata = [
    [('Artist', 'Artist (romanised)'), ('ArtistUnicode', 'Artist')],
    [('Title', 'Title (romanised)'), ('TitleUnicode', 'Title')],
    [('Creator', 'Creator'), ('Version', 'Difficulty name')],
    [('Source', 'Source')],
    [('Tags', 'Tags')],
  ];

  static const List<_DiffKey> _difficulty = [
    ('HPDrainRate', 'HP', 0, 10, 0.1),
    ('CircleSize', 'CS', 0, 10, 0.1),
    ('ApproachRate', 'AR', 0, 10, 0.1),
    ('OverallDifficulty', 'OD', 0, 10, 0.1),
  ];

  /// Shares its row with the tick rate.
  static const _DiffKey _sliderVelocity = ('SliderMultiplier', 'SV', 0.4, 3.6, 0.05);

  static const _tickRates = [0.5, 1.0, 2.0, 3.0, 4.0];

  static final _ascii = RegExp(r'^[\x20-\x7E]*$');

  static String? _validate(String key, String v) => switch (key) {
    'Version' when v.trim().isEmpty => 'Required',
    'Artist' || 'Title' when !_ascii.hasMatch(v) => 'Latin characters only',
    _ => null,
  };

  EditorController get c => controller;
  Beatmap get b => c.beatmap;

  bool _commitText(String key, String text) {
    var v = text.trim();
    // osu! falls back to the romanised text when no unicode one is given.
    if (v.isEmpty && key == 'ArtistUnicode') v = b.artist;
    if (v.isEmpty && key == 'TitleUnicode') v = b.title;
    // Leave keys a map doesn't have alone unless they now have a value.
    if (v.isEmpty && b.getValue(SectionNames.metadata, key) == null) return true;
    // A fallback equal to the current value changes nothing: revert the
    // field so it shows that value again.
    return c.setValues('Song setup', [(SectionNames.metadata, key, v)]) || v == text.trim();
  }

  double _difficultyValue(String key) => switch (key) {
    'HPDrainRate' => b.hpDrainRate,
    'CircleSize' => b.circleSize,
    'ApproachRate' => b.approachRate,
    'OverallDifficulty' => b.overallDifficulty,
    'SliderMultiplier' => b.sliderMultiplier,
    _ => b.sliderTickRate,
  };

  void _setDifficulty(String key, double v) {
    // Untouched values keep their exact text (a slider would round 4.25).
    if (v == _difficultyValue(key)) return;
    c.setValues('Song setup', [(SectionNames.difficulty, key, formatNumber(v))]);
  }

  int get _preview => int.tryParse(b.getValue(SectionNames.general, 'PreviewTime')?.trim() ?? '') ?? -1;

  void _setPreview(int ms) => c.setValues('Song setup', [(SectionNames.general, 'PreviewTime', '$ms')]);

  Future<void> _syncSet(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: const Text('Copy metadata to other difficulties?'),
        content: const Text(
          'Artist, title, creator, source and tags of this difficulty are written to the '
          "set's other difficulties right away. This can't be undone.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Copy')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final n = await c.syncMetadataToSet();
      AppToast.show('Updated metadata in $n other difficult${n == 1 ? 'y' : 'ies'}');
    } catch (e) {
      AppToast.show('Could not update other difficulties: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = _theme(Theme.of(context));
    return Theme(
      data: theme,
      child: Material(
        color: theme.colorScheme.surface,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _metadataColumn(context, theme)),
            Expanded(child: _filesAndDifficultyColumn(context, theme)),
          ],
        ),
      ),
    );
  }

  /// The panel's look (shared with the Timing and Control Points panels).
  static ThemeData _theme(ThemeData base) => setupTheme(base);

  /// A flat rounded card with a small icon and caps title.
  Widget _section(ThemeData theme, IconData icon, String title, List<Widget> children) =>
      SetupSection(icon: icon, title: title, children: children);

  /// Marks [child] as changed since the last save (tinted background and an
  /// accent bar on the left). Only horizontal insets so the row's height
  /// does not change when it becomes marked.
  Widget _mark(BuildContext context, String id, Widget child) {
    final scheme = Theme.of(context).colorScheme;
    final changed = c.songSetupChanged(id);
    return Container(
      decoration: BoxDecoration(
        color: changed ? scheme.primary.withValues(alpha: 0.12) : null,
        border: changed ? Border(left: BorderSide(color: scheme.primary, width: 3)) : null,
        borderRadius: BorderRadius.circular(10),
      ),
      padding: changed ? const EdgeInsets.fromLTRB(6, 0, 2, 0) :EdgeInsets.zero,
      child: child,
    );
  }

  /// [child] in a small rounded pill (tabular figures).
  static Widget _pill(ThemeData theme, Widget child) => SetupPill(child: child);

  /// One `[Colours]` key colour (slider track / border): a swatch and its
  /// value, or [fallback] when the map doesn't set it; tap to edit.
  Widget _keyColour(BuildContext context, ThemeData theme, String key, String label, String fallback) {
    final s = theme.colorScheme;
    final value = c.mapColour(key);
    Future<void> edit() async {
      final result = await showDialog<_ColourResult>(
        context: context,
        builder: (_) => _ComboColourDialog(
          title: label,
          initial: value ?? const RgbColour(255, 255, 255),
          canDelete: value != null,
          deleteLabel: 'Use default',
        ),
      );
      if (result == null) return;
      c.setMapColour(key, result.delete ? null : result.colour);
    }

    return _mark(
      context,
      'Colours.$key',
      InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: edit,
        child: SizedBox(
          height: 40,
          child: Row(
            children: [
              Expanded(child: Text(label)),
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: value == null ? null : EditorController.colourOf(value),
                  shape: BoxShape.circle,
                  border: Border.all(color: s.outline, width: 1.5),
                ),
                child: value == null ? Icon(Icons.auto_awesome, size: 14, color: s.onSurfaceVariant) : null,
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 112,
                child: Text(
                  value?.hex ?? fallback,
                  style: TextStyle(color: value == null ? s.onSurfaceVariant : s.onSurface),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: s.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  Widget _metadataField(BuildContext context, _TextKey f) {
    final (k, label) = f;
    return _mark(
      context,
      '${SectionNames.metadata}.$k',
      CommitTextField(
        value: b.getValue(SectionNames.metadata, k) ?? '',
        label: label,
        validate: (v) => _validate(k, v),
        onCommit: (v) => _commitText(k, v),
      ),
    );
  }

  Widget _metadataColumn(BuildContext context, ThemeData theme) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 12, 6, 4),
    children: [
      _section(theme, Icons.library_music_outlined, 'Metadata', [
        for (final (i, row) in _metadata.indexed)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (j, f) in row.indexed) ...[
                  if (j > 0) const SizedBox(width: 10),
                  Expanded(child: _metadataField(context, f)),
                ],
              ],
            ),
          ),
        if (c.canChangeSetFiles)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _syncSet(context),
                icon: const Icon(Icons.copy_all, size: 18),
                label: const Text('Copy metadata to other difficulties…'),
              ),
            ),
          ),
      ]),
      _section(theme, Icons.palette_outlined, 'Colours', [
        _comboColours(context, theme),
        const SizedBox(height: 10),
        _keyColour(context, theme, ComboColours.sliderTrack, 'Slider track', 'Combo colour'),
        _keyColour(context, theme, ComboColours.sliderBorder, 'Slider border', 'White'),
      ]),
    ],
  );

  /// The map's combo colours as swatches (tap one to edit or delete it,
  /// "+" adds one). A map without its own shows the default ones, dimmed;
  /// editing them makes them the map's.
  Widget _comboColours(BuildContext context, ThemeData theme) {
    final s = theme.colorScheme;
    final own = c.mapComboColours;
    final shown = own.isNotEmpty ? own : [for (final x in EditorController.defaultComboColours) EditorController.rgbOf(x)];
    Future<void> edit(int? index) async {
      final list = List.of(shown);
      final result = await showDialog<_ColourResult>(
        context: context,
        builder: (_) => _ComboColourDialog(
          title: index == null ? 'New combo colour' : 'Combo ${index + 1}',
          initial: index == null ? list.last : list[index],
          canDelete: index != null && list.length > 1,
        ),
      );
      if (result == null || (index != null && !result.delete && result.colour == list[index])) return;
      if (index == null) {
        list.add(result.colour);
      } else if (result.delete) {
        list.removeAt(index);
      } else {
        list[index] = result.colour;
      }
      c.setComboColours(list);
    }

    Widget swatch(int i) {
      final colour = EditorController.colourOf(shown[i]);
      final light = colour.computeLuminance() > 0.45;
      return Tooltip(
        message: 'Combo ${i + 1} ${shown[i].hex}',
        child: InkResponse(
          onTap: () => edit(i),
          radius: 24,
          child: Opacity(
            opacity: own.isEmpty ? 0.55 : 1,
            child: Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colour,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.5),
              ),
              child: Text(
                '${i + 1}',
                style: TextStyle(fontWeight: FontWeight.bold, color: light ? Colors.black87 : Colors.white),
              ),
            ),
          ),
        ),
      );
    }

    return _mark(
      context,
      'Colours.Combo',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (var i = 0; i < shown.length; i++) swatch(i),
              if (shown.length < ComboColours.max)
                IconButton.filledTonal(
                  tooltip: 'Add combo colour',
                  onPressed: () => edit(null),
                  icon: const Icon(Icons.add),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    own.isEmpty
                        ? 'Default colours (the map has none). Editing them saves them in the map.'
                        : 'The first combo uses colour 2; colour 1 comes last.',
                    style: theme.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant),
                  ),
                ),
                if (own.isNotEmpty)
                  TextButton(onPressed: () => c.setComboColours(const []), child: const Text('Use defaults')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fileRow(
    BuildContext context,
    ThemeData theme,
    String id,
    IconData icon,
    String label,
    String? name,
    VoidCallback onChange,
  ) {
    final s = theme.colorScheme;
    final none = name == null || name.isEmpty;
    return _mark(
      context,
      id,
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: s.primary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: s.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: theme.textTheme.labelSmall?.copyWith(color: s.onSurfaceVariant)),
                  Text(
                    none ? 'None' : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(color: none ? s.onSurfaceVariant : null),
                  ),
                ],
              ),
            ),
            FilledButton.tonal(onPressed: c.canChangeSetFiles ? onChange : null, child: const Text('Change…')),
          ],
        ),
      ),
    );
  }

  Widget _slider(BuildContext context, _DiffKey d) {
    final (k, label, min, max, step) = d;
    return _mark(
      context,
      '${SectionNames.difficulty}.$k',
      CommitSlider(
        label: label,
        inline: true,
        value: _difficultyValue(k),
        min: min,
        max: max,
        divisions: ((max - min) / step).round(),
        format: (v) => v.toStringAsFixed(step < 0.1 ? 2 : 1),
        onCommit: (v) => _setDifficulty(k, double.parse(v.toStringAsFixed(2))),
      ),
    );
  }

  String? _general(String key) => b.getValue(SectionNames.general, key)?.trim();

  int _generalInt(String key, int fallback) => int.tryParse(_general(key) ?? '') ?? fallback;

  void _setGeneral(String key, String value) {
    if (_general(key) == value) return;
    c.setValues('Song setup', [(SectionNames.general, key, value)]);
  }

  static const _countdowns = ['None', 'Normal', 'Half speed', 'Double speed'];

  /// A [label] with a compact pick-one menu of [choices] (shown as [names]).
  Widget _choice<T>(
    BuildContext context,
    ThemeData theme,
    String key,
    String label,
    T value,
    List<T> choices,
    String Function(T) name,
    ValueChanged<T> onPick,
  ) {
    final s = theme.colorScheme;
    return _mark(
      context,
      '${SectionNames.general}.$key',
      SizedBox(
        height: 40,
        child: Row(
          children: [
            Expanded(child: Text(label)),
            PopupMenuButton<T>(
              initialValue: value,
              tooltip: label,
              position: PopupMenuPosition.under,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              onSelected: onPick,
              itemBuilder: (_) => [for (final v in choices) PopupMenuItem(value: v, height: 36, child: Text(name(v)))],
              child: _pill(
                theme,
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(name(value)),
                    const SizedBox(width: 2),
                    Icon(Icons.arrow_drop_down, size: 18, color: s.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _switch(BuildContext context, String key, String label) => _mark(
    context,
    '${SectionNames.general}.$key',
    SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Switch(value: _generalInt(key, 0) == 1, onChanged: (v) => _setGeneral(key, v ? '1' : '0')),
        ],
      ),
    ),
  );

  /// `[General]` settings (osu!stable's Song setup "Audio", "Design" and
  /// "Advanced" tabs): one undo step each. Missing keys show osu!'s default.
  List<Widget> _generalSettings(BuildContext context, ThemeData theme) {
    final sampleSet = b.defaultSampleSet == SampleSet.auto ? SampleSet.normal : b.defaultSampleSet;
    final countdown = _generalInt('Countdown', 1).clamp(0, 3);
    final offset = _generalInt('CountdownOffset', 0).clamp(0, 3);
    return [
      _choice<int>(context, theme, 'SampleSet', 'Default sample set', sampleSet,
          const [SampleSet.normal, SampleSet.soft, SampleSet.drum], SampleSet.name,
          (v) => _setGeneral('SampleSet', SampleSet.name(v))),
      _mark(
        context,
        '${SectionNames.general}.AudioLeadIn',
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: CommitTextField(
            value: '${_generalInt('AudioLeadIn', 0)}',
            label: 'Audio lead-in',
            suffix: 'ms',
            keyboardType: TextInputType.number,
            validate: (v) => int.tryParse(v.trim()) == null || int.parse(v.trim()) < 0 ? 'Whole ms, 0 or more' : null,
            onCommit: (v) {
              _setGeneral('AudioLeadIn', '${int.parse(v.trim())}');
              return true;
            },
          ),
        ),
      ),
      _mark(
        context,
        '${SectionNames.general}.StackLeniency',
        CommitSlider(
          label: 'Stack leniency',
          inline: true,
          labelWidth: 108,
          value: b.stackLeniency.clamp(0, 1).toDouble(),
          min: 0,
          max: 1,
          divisions: 10,
          format: (v) => v.toStringAsFixed(1),
          onCommit: (v) {
            final text = formatNumber(double.parse(v.toStringAsFixed(1)));
            if (double.tryParse(_general('StackLeniency') ?? '') != double.parse(text)) {
              _setGeneral('StackLeniency', text);
            }
          },
        ),
      ),
      _choice<int>(context, theme, 'Countdown', 'Countdown', countdown, const [0, 1, 2, 3], (v) => _countdowns[v],
          (v) => _setGeneral('Countdown', '$v')),
      if (countdown != 0)
        _choice<int>(context, theme, 'CountdownOffset', 'Countdown offset', offset, const [0, 1, 2, 3],
            (v) => '$v beat${v == 1 ? '' : 's'}', (v) => _setGeneral('CountdownOffset', '$v')),
      _switch(context, 'LetterboxInBreaks', 'Letterbox during breaks'),
      _switch(context, 'WidescreenStoryboard', 'Widescreen storyboard'),
      _switch(context, 'EpilepsyWarning', 'Epilepsy warning'),
    ];
  }

  Widget _filesAndDifficultyColumn(BuildContext context, ThemeData theme) {
    final s = theme.colorScheme;
    final tickRate = b.sliderTickRate;
    final preview = _preview;
    return ListView(
      padding: const EdgeInsets.fromLTRB(6, 12, 16, 4),
      children: [
        _section(theme, Icons.folder_outlined, 'Files', [
          _fileRow(context, theme, 'Files.Audio', Icons.music_note_outlined, 'Audio', b.audioFilename, onSetAudio),
          const SizedBox(height: 6),
          _fileRow(
            context,
            theme,
            'Files.Background',
            Icons.image_outlined,
            'Background',
            b.backgroundFilename,
            onSetBackground,
          ),
          if (!c.canChangeSetFiles)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Files can only be changed for maps in the library.',
                style: theme.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant),
              ),
            ),
        ]),
        if (c.canChangeSetFiles)
          _section(theme, Icons.layers_outlined, 'Difficulties', [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => onNewDifficulty(false),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New difficulty…'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => onNewDifficulty(true),
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Duplicate this difficulty…'),
                ),
                if (onDeleteDifficulty != null)
                  TextButton.icon(
                    onPressed: onDeleteDifficulty,
                    style: TextButton.styleFrom(foregroundColor: s.error),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Delete this difficulty…'),
                  ),
              ],
            ),
          ]),
        _section(theme, Icons.tune, 'Difficulty', [
          for (final d in _difficulty) _slider(context, d),
          // Slider velocity and tick rate share a row.
          Row(
            children: [
              Expanded(child: _slider(context, _sliderVelocity)),
              const SizedBox(width: 12),
              _mark(
                context,
                '${SectionNames.difficulty}.SliderTickRate',
                Row(
                  children: [
                    const Text('Tick rate'),
                    const SizedBox(width: 8),
                    PopupMenuButton<double>(
                      initialValue: tickRate,
                      tooltip: 'Slider tick rate',
                      position: PopupMenuPosition.under,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      onSelected: (r) => _setDifficulty('SliderTickRate', r),
                      itemBuilder: (_) => [
                        for (final r in {..._tickRates, tickRate})
                          PopupMenuItem(value: r, height: 36, child: Text(formatNumber(r))),
                      ],
                      child: _pill(
                        theme,
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(formatNumber(tickRate)),
                            const SizedBox(width: 2),
                            Icon(Icons.arrow_drop_down, size: 18, color: s.onSurfaceVariant),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ]),
        _section(theme, Icons.play_circle_outline, 'Song preview', [
          _mark(
            context,
            '${SectionNames.general}.PreviewTime',
            Row(
              children: [
                _pill(
                  theme,
                  Text(
                    preview < 0 ? 'Not set' : formatEditorTime(preview.toDouble()),
                    style: TextStyle(color: preview < 0 ? s.onSurfaceVariant : s.onSurface),
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => _setPreview(c.time.value.round().clamp(0, 1 << 31)),
                  child: const Text('Use current time'),
                ),
                TextButton(onPressed: preview < 0 ? null : () => _setPreview(-1), child: const Text('Clear')),
              ],
            ),
          ),
        ]),
        _section(theme, Icons.settings_outlined, 'General', _generalSettings(context, theme)),
      ],
    );
  }
}

/// What the combo colour dialog returns: the colour, or a deletion.
class _ColourResult {
  final RgbColour colour;
  final bool delete;
  const _ColourResult(this.colour, {this.delete = false});
}

/// Edits one combo colour: a preview, R / G / B sliders and a hex field.
class _ComboColourDialog extends StatefulWidget {
  final String title;
  final RgbColour initial;
  final bool canDelete;

  /// The delete button's text (removing a single colour key means going
  /// back to the default).
  final String deleteLabel;
  const _ComboColourDialog(
      {required this.title, required this.initial, required this.canDelete, this.deleteLabel = 'Delete'});

  @override
  State<_ComboColourDialog> createState() => _ComboColourDialogState();
}

class _ComboColourDialogState extends State<_ComboColourDialog> {
  late RgbColour _colour = widget.initial;
  late final TextEditingController _hex = TextEditingController(text: widget.initial.hex);

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _set(RgbColour c, {bool fromHex = false}) {
    setState(() => _colour = c);
    if (!fromHex) _hex.text = c.hex;
  }

  Widget _channel(String label, int value, Color tint, RgbColour Function(int) apply) => SizedBox(
    height: 36,
    child: Row(
      children: [
        SizedBox(width: 16, child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold))),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: Slider(
              value: value.toDouble(),
              max: 255,
              divisions: 255,
              activeColor: tint,
              onChanged: (v) => _set(apply(v.round())),
            ),
          ),
        ),
        SizedBox(width: 30, child: Text('$value', textAlign: TextAlign.end)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = _colour;
    // Compact: fits a landscape phone (about 380dp tall) without scrolling.
    return AppDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 12),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      title: Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 108,
                child: Column(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: EditorController.colourOf(c),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _hex,
                      decoration: const InputDecoration(labelText: 'Hex', isDense: true),
                      onChanged: (v) {
                        final parsed = RgbColour.parseHex(v);
                        if (parsed != null) _set(parsed, fromHex: true);
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _channel('R', c.r, Colors.red, (v) => RgbColour(v, c.g, c.b)),
                    _channel('G', c.g, Colors.green, (v) => RgbColour(c.r, v, c.b)),
                    _channel('B', c.b, Colors.blue, (v) => RgbColour(c.r, c.g, v)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.canDelete)
          TextButton(
            onPressed: () => Navigator.pop(context, _ColourResult(c, delete: true)),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: Text(widget.deleteLabel),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _ColourResult(c)), child: const Text('OK')),
      ],
    );
  }
}

/// One `[Metadata]` text field.
typedef _TextKey = (String key, String label);

/// One `[Difficulty]` slider.
typedef _DiffKey = (String key, String label, double min, double max, double step);
