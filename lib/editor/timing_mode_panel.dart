import 'package:flutter/material.dart';

import '../core/core.dart';
import 'editor_controller.dart';
import 'editor_screen.dart' show formatEditorTime;
import 'widgets/bpm_view.dart';
import 'widgets/form_fields.dart';
import 'widgets/setup_style.dart';

/// The editor's Timing mode: on the left the red point governing the
/// playhead (BPM, offset, meter, tap tempo, beat lamps, "Move objects with
/// timing") on Song setup style cards, edited in place instead of from a
/// point list (that is the Control Points popup, which also has the
/// sounds / kiai / SV / omit-first-bar-line settings; base SV and tick
/// rate are in Song setup); on the right the [BpmView]
/// (detailed waveform strip + beat rows) to time the song by eye. Every
/// change is one undo step.
///
/// Follows the playhead: it listens to `controller.time` but only rebuilds
/// when the red point in effect changes (section boundaries), never per
/// frame; the beat lamps and the BPM view repaint from `controller.time` on
/// their own.
class TimingModePanel extends StatefulWidget {
  final EditorController controller;
  const TimingModePanel({super.key, required this.controller});

  @override
  State<TimingModePanel> createState() => _TimingModePanelState();
}

class _TimingModePanelState extends State<TimingModePanel> {
  EditorController get c => widget.controller;

  /// The red point in effect at the playhead when last built.
  TimingPoint? _red;

  /// Tap tempo: tap times (ms on [_tapClock]), the latest last.
  final List<double> _taps = [];
  final Stopwatch _tapClock = Stopwatch()..start();

  @override
  void initState() {
    super.initState();
    c.time.addListener(_onTime);
  }

  @override
  void didUpdateWidget(TimingModePanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, c)) {
      old.controller.time.removeListener(_onTime);
      c.time.addListener(_onTime);
    }
  }

  @override
  void dispose() {
    c.time.removeListener(_onTime);
    super.dispose();
  }

  void _onTime() {
    final t = c.time.value;
    if (!identical(c.timing.redPointAt(t), _red)) {
      setState(() {});
    }
  }

  // ---------------------------------------------------------------------------
  // Edits

  /// Replaces the red point (moving its section along when the controller's
  /// "Move objects with timing" is on). A point moved past the playhead
  /// would stop being the one shown: the playhead follows it.
  void _editRed(TimingPoint red, TimingPoint after) {
    final r = c.retimePoint(red, after);
    if (r.time > c.time.value) c.seek(r.time);
  }

  void _tap() {
    final now = _tapClock.elapsedMicroseconds / 1000;
    setState(() {
      // A pause of two seconds starts a new count.
      if (_taps.isNotEmpty && now - _taps.last > 2000) _taps.clear();
      _taps.add(now);
      if (_taps.length > 16) _taps.removeAt(0);
    });
  }

  /// The tapped tempo (average over the last taps), or null below 2 taps.
  double? get _tappedBpm =>
      _taps.length < 2 ? null : 60000 * (_taps.length - 1) / (_taps.last - _taps.first);

  void _applyTapped(TimingPoint red) {
    final bpm = _tappedBpm;
    if (bpm == null) return;
    setState(_taps.clear);
    _editRed(red, red.copyWith(beatLength: 60000 / bpm.round()));
  }

  @override
  Widget build(BuildContext context) {
    final t = c.time.value;
    final red = _red = c.timing.redPointAt(t);
    final theme = setupTheme(Theme.of(context));
    return Theme(
      data: theme,
      child: Material(
        color: theme.colorScheme.surface,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: settingsWidth, child: _redColumn(context, red)),
            const VerticalDivider(width: 1),
            Expanded(child: BpmView(controller: c)),
          ],
        ),
      ),
    );
  }

  /// Width of the red point column.
  static const settingsWidth = 300.0;

  static const _gap = SizedBox(height: 8);
  static const _step = SizedBox(width: 6);

  // ---------------------------------------------------------------------------
  // Red point

  Widget _redColumn(BuildContext context, TimingPoint? red) {
    final reds = c.timing.redPoints;
    final i = red == null ? -1 : reds.indexWhere((p) => identical(p, red));
    final addHere = TextButton.icon(
      onPressed: () => c.addTimingPoint(red: true),
      icon: const Icon(Icons.add, color: timingRed, size: 18),
      label: const Text('Timing point here'),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      children: [
        SetupSection(
          marker: timingRed,
          title: 'Timing point',
          subtitle: red == null ? 'None here' : formatEditorTime(red.time),
          trailing: [
            IconButton(
              tooltip: 'Previous',
              onPressed: i > 0 ? () => c.seek(reds[i - 1].time) : null,
              icon: const Icon(Icons.chevron_left, size: 20),
            ),
            IconButton(
              tooltip: 'Next',
              onPressed: i >= 0 && i + 1 < reds.length ? () => c.seek(reds[i + 1].time) : null,
              icon: const Icon(Icons.chevron_right, size: 20),
            ),
            IconButton(
              tooltip: 'Delete point',
              onPressed: red == null ? null : () => c.deleteTimingPoint(red),
              icon: const Icon(Icons.delete_outline, size: 20),
            ),
          ],
          children: [
            if (red == null)
              const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No timing point yet.'))
            else
              // Fields belong to this point: typing must never commit to
              // the next section's point after the playhead moves on.
              KeyedSubtree(key: ValueKey(('red', red.time)), child: _redFields(context, red)),
            Align(alignment: Alignment.centerLeft, child: addHere),
          ],
        ),
        if (red != null) SetupSection(icon: Icons.touch_app_outlined, title: 'Tap tempo', children: [_tapTempo(red)]),
        SetupSection(
          icon: Icons.tune,
          title: 'Options',
          children: [
            SetupRow(
              label: 'Move objects with timing',
              subtitle: "Offset / BPM changes keep the section's objects on their beats",
              trailing: Switch(value: c.moveObjectsWithTiming, onChanged: (v) => c.moveObjectsWithTiming = v),
              onTap: () => c.moveObjectsWithTiming = !c.moveObjectsWithTiming,
            ),
          ],
        ),
      ],
    );
  }

  static const _meters = [1, 2, 3, 4, 5, 6, 7, 8];

  Widget _redFields(BuildContext context, TimingPoint red) {
    final bpm = red.bpm;
    void setBpm(double v) => _editRed(red, red.copyWith(beatLength: 60000 / v));
    void shift(double ms) => _editRed(red, red.copyWith(time: red.time + ms));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: CommitTextField(
                label: 'BPM',
                value: _fmt(bpm, 3),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onCommit: (s) {
                  final v = double.tryParse(s.trim());
                  if (v == null || !(v > 0 && v <= 10000)) return false;
                  setBpm(v);
                  return true;
                },
              ),
            ),
            _step,
            SetupStepButton('−1', bpm > 1 ? () => setBpm(_round3(bpm - 1)) : null),
            _step,
            SetupStepButton('+1', bpm < 9999 ? () => setBpm(_round3(bpm + 1)) : null),
          ],
        ),
        _gap,
        Row(
          children: [
            Expanded(
              child: CommitTextField(
                label: 'Offset',
                suffix: 'ms',
                value: formatNumber(red.time),
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                onCommit: (s) {
                  final v = double.tryParse(s.trim());
                  if (v == null || !v.isFinite) return false;
                  _editRed(red, red.copyWith(time: v));
                  return true;
                },
              ),
            ),
            _step,
            TextButton(
              onPressed: () => _editRed(red, red.copyWith(time: c.time.value.roundToDouble())),
              child: const Text('Use current'),
            ),
          ],
        ),
        _gap,
        Row(
          children: [
            SetupStepButton('−10', () => shift(-10)),
            _step,
            SetupStepButton('−1', () => shift(-1)),
            _step,
            SetupStepButton('+1', () => shift(1)),
            _step,
            SetupStepButton('+10', () => shift(10)),
          ],
        ),
        _gap,
        SetupRow(
          label: 'Meter',
          trailing: SetupChoicePill<int>(
            value: red.meter,
            choices: [..._meters, if (!_meters.contains(red.meter)) red.meter],
            name: (m) => '$m/4',
            tooltip: 'Meter',
            onPick: (m) => _editRed(red, red.copyWith(meter: m)),
          ),
        ),
      ],
    );
  }

  Widget _tapTempo(TimingPoint red) {
    final tapped = _tappedBpm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            // Counted on touch down: waiting for the release would skew taps.
            Listener(
              onPointerDown: (_) => _tap(),
              child: FilledButton.tonal(onPressed: () {}, child: const Text('Tap')),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                tapped == null ? 'Tap along to the beat' : '${_taps.length} taps · ${tapped.toStringAsFixed(1)} BPM',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: _taps.length >= 4 ? () => _applyTapped(red) : null,
              child: Text(tapped == null || _taps.length < 4 ? 'Apply' : 'Apply ${tapped.round()}'),
            ),
          ],
        ),
        _gap,
        SizedBox(height: 22, child: _BeatLamps(controller: c)),
      ],
    );
  }
}

const timingRed = Color(0xFFE53935);

String _fmt(double v, [int digits = 2]) => formatNumber(double.parse(v.toStringAsFixed(digits)));
double _round3(double v) => double.parse(v.toStringAsFixed(3));

/// One lamp per beat of the measure at the playhead, the current beat lit
/// (the first beat in the accent colour) and fading through the beat.
/// Repaints from `controller.time`, not by rebuilding.
class _BeatLamps extends StatelessWidget {
  final EditorController controller;
  const _BeatLamps({required this.controller});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Own layer: repainting every frame doesn't re-record the panel.
    return RepaintBoundary(
      child: CustomPaint(
        painter: _BeatLampsPainter(
          controller,
          off: scheme.surfaceContainerHighest,
          on: scheme.primary,
          accent: const Color(0xFFFFB300),
        ),
      ),
    );
  }
}

class _BeatLampsPainter extends CustomPainter {
  final EditorController c;
  final Color off, on, accent;

  _BeatLampsPainter(this.c, {required this.off, required this.on, required this.accent}) : super(repaint: c.time);

  /// The beat (in the measure) at [time] and how far into it, or null
  /// without a red point.
  static (int beat, int meter, double phase)? beatAt(TimingInfo timing, double time) {
    final red = timing.redPointAt(time);
    if (red == null || !(red.beatLength > 0)) return null;
    final meter = red.meter < 1 ? 4 : red.meter;
    final beats = (time - red.time) / red.beatLength + 1e-6;
    final whole = beats.floor();
    return (whole % meter, meter, beats - whole);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final b = beatAt(c.timing, c.time.value);
    if (b == null) return;
    final (beat, meter, phase) = b;
    final r = (size.height / 2 - 2).clamp(2.0, 9.0);
    final paint = Paint();
    for (var i = 0; i < meter.clamp(1, 16); i++) {
      final centre = Offset(r + 2 + i * (r * 2 + 8), size.height / 2);
      if (i == beat) {
        final lit = i == 0 ? accent : on;
        paint.color = Color.lerp(lit, off, (phase * 0.8).clamp(0, 1))!;
      } else {
        paint.color = off;
      }
      canvas.drawCircle(centre, r, paint);
    }
  }

  // A rebuild means the timing may have changed (paused edits don't tick
  // `controller.time`); rebuilds are rare.
  @override
  bool shouldRepaint(_BeatLampsPainter old) => true;
}
