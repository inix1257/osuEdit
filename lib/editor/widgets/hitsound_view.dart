import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/core.dart';
import '../editor_controller.dart';
import '../render/hitsound_painter.dart';
import '../render/timeline_painter.dart';
import 'form_fields.dart';

/// The Hitsound mode's screen: layer names on the left, then the hitsound
/// timeline and its layers ([HitsoundPainter]). It shows the same time and
/// zoom as the top timeline (seeking either moves both):
/// * one-finger drag scrubs, and a fast one keeps gliding (fling); a touch,
///   playing or any other seek stops it;
/// * two-finger pinch zooms;
/// * a tap on the timeline strip seeks there (snapped to the beat divisor);
/// * mouse wheel steps by the beat divisor, Ctrl / Alt + wheel zooms.
///
/// Editing (each tap one undo step, on the note under it — one slider edge
/// at a time — whatever is selected):
/// * Timing row: cycles that timing point's sample set (default → normal →
///   soft → drum);
/// * Sampleset / Additions rows: cycles the note's own sample / addition set
///   (inherit → normal → soft → drum; additions only on notes that have
///   some); on a slider body between notes, the slider's own set;
/// * Whistle / Finish / Clap rows: toggles that addition on the note; on a
///   slider body, Whistle toggles the body whistle (sliderwhistle);
/// * long press on a note, body or timing chip: sample index and volume
///   ([HitsoundSampleDialog]).
class HitsoundView extends StatelessWidget {
  final EditorController controller;
  const HitsoundView({super.key, required this.controller});

  /// Width of the layer names column.
  static const labelWidth = 96.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      final g = HitsoundGeometry(constraints.maxHeight);
      final style = TextStyle(fontSize: (g.rowHeight * 0.34).clamp(10.0, 13.0), color: scheme.onSurface);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: labelWidth,
            child: ColoredBox(
              color: const Color(0xFF15171B),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(height: g.rulerHeight),
                  for (final layer in HitsoundLayer.values)
                    Container(
                      height: g.rowHeight,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4))),
                      ),
                      child: Row(
                        children: [
                          Container(width: 3, height: g.rowHeight * 0.5, color: _layerColour(layer)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(layer.label, style: style, maxLines: 1, overflow: TextOverflow.fade, softWrap: false),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(child: HitsoundTimeline(controller: controller)),
        ],
      );
    });
  }

  static Color _layerColour(HitsoundLayer layer) => switch (layer) {
        HitsoundLayer.timing => const Color(0xFF3BD16F),
        HitsoundLayer.sampleSet || HitsoundLayer.additions => const Color(0xFF8A8F99),
        HitsoundLayer.whistle => HitsoundPainter.whistleColour,
        HitsoundLayer.finish => HitsoundPainter.finishColour,
        HitsoundLayer.clap => HitsoundPainter.clapColour,
      };
}

/// The hitsound timeline with its layers (see [HitsoundView]).
class HitsoundTimeline extends StatefulWidget {
  final EditorController controller;
  const HitsoundTimeline({super.key, required this.controller});

  @override
  State<HitsoundTimeline> createState() => _HitsoundTimelineState();
}

class _HitsoundTimelineState extends State<HitsoundTimeline> with SingleTickerProviderStateMixin {
  double _width = 0, _height = 0;
  double _zoomAtStart = 1;
  bool _scrubbed = false;

  // Scrub fling, as on the top timeline.
  late final Ticker _flingTicker = createTicker(_onFlingTick);
  FrictionSimulation? _fling;
  double _flingTime = 0, _flingStartTime = 0;
  static const _minFlingSpeed = 300.0;
  static const _maxFlingSpeed = 8000.0;
  static const _flingDrag = 0.05;

  EditorController get c => widget.controller;

  @override
  void dispose() {
    _flingTicker.dispose();
    super.dispose();
  }

  void _startFling(double pxPerSecond) {
    _stopFling();
    final v = pxPerSecond.clamp(-_maxFlingSpeed, _maxFlingSpeed);
    if (v.abs() < _minFlingSpeed || _width <= 0) return;
    _fling = FrictionSimulation(_flingDrag, 0, v, tolerance: const Tolerance(velocity: 20));
    _flingTime = _flingStartTime = c.time.value;
    _flingTicker.start();
  }

  void _onFlingTick(Duration elapsed) {
    final sim = _fling;
    if (sim == null || !mounted) return _stopFling();
    if (c.isPlaying || c.time.value != _flingTime) return _stopFling();
    final s = elapsed.inMicroseconds / 1e6;
    final target = _flingStartTime - sim.x(s) / c.timelineZoom;
    c.seek(target);
    _flingTime = c.time.value;
    if (sim.isDone(s) || _flingTime != target) _stopFling();
  }

  void _stopFling() {
    _fling = null;
    if (_flingTicker.isActive) _flingTicker.stop();
  }

  void _onScaleStart(ScaleStartDetails d) {
    _zoomAtStart = c.timelineZoom;
    _scrubbed = false;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount >= 2) {
      c.timelineZoom = _zoomAtStart * d.horizontalScale;
      return;
    }
    final dx = d.focalPointDelta.dx;
    if (dx == 0) return;
    if (!_scrubbed) {
      c.pause();
      _scrubbed = true;
    }
    c.seek(c.time.value - dx / c.timelineZoom);
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_scrubbed && d.pointerCount == 0) _startFling(d.velocity.pixelsPerSecond.dx);
    _scrubbed = false;
  }

  /// Touch slop around a note block, in logical pixels.
  static const _hitSlop = 12.0;

  double _timeAt(double x) => TimelinePainter.timeAt(x, c.time.value, c.timelineZoom, _width);

  /// The note whose block is nearest [x] (within its half width or the
  /// touch slop), or null.
  HitsoundNote? _noteAt(double x) {
    final t = _timeAt(x);
    final reach = math.max(HitsoundPainter.maxNoteWidth / 2, _hitSlop) / c.timelineZoom;
    HitsoundNote? best;
    var bestDx = double.infinity;
    for (final n in c.hitsoundNotesInRange(t - reach, t + reach)) {
      final dx = (n.time - t).abs() * c.timelineZoom;
      final limit = math.max(HitsoundPainter.noteWidthAt(c, n.time) / 2, _hitSlop);
      if (dx <= limit && dx < bestDx) {
        best = n;
        bestDx = dx;
      }
    }
    return best;
  }

  /// The slider whose body is under [x] (between its head and tail).
  SliderObject? _bodyAt(double x) {
    final t = _timeAt(x);
    SliderObject? hit;
    for (final o in c.objectsInRange(t, t)) {
      if (o is SliderObject && o.time <= t && c.endTimeOf(o) >= t) hit = o;
    }
    return hit;
  }

  /// The timing point whose chip is at [x]: a marker within the touch slop,
  /// else the last point at or before [x] (its chip runs to the next one).
  TimingPoint? _timingPointAt(double x) {
    final pts = c.timing.points;
    if (pts.isEmpty) return null;
    final t = _timeAt(x + _hitSlop);
    final i = Beatmap.lowerBound(pts, t, (p) => p.time);
    // Upper bound: the last point with time <= t (later ones of equal time
    // are drawn on top).
    var j = i;
    while (j < pts.length && pts[j].time <= t) {
      j++;
    }
    return j > 0 ? pts[j - 1] : null;
  }

  void _onTapUp(TapUpDetails d) {
    final layer = HitsoundGeometry(_height).layerAt(d.localPosition.dy);
    final x = d.localPosition.dx;
    if (layer == null) {
      c.seek(c.timing.snap(_timeAt(x), c.divisor));
      return;
    }
    if (layer == HitsoundLayer.timing) {
      final p = _timingPointAt(x);
      if (p != null) c.cycleTimingPointSet(p);
      return;
    }
    final note = _noteAt(x);
    if (note != null) {
      switch (layer) {
        case HitsoundLayer.sampleSet:
          c.cycleNoteSet(note, addition: false);
        case HitsoundLayer.additions:
          // Only notes with additions show (and use) an addition set.
          if (note.hasAdditions) c.cycleNoteSet(note, addition: true);
        case HitsoundLayer.whistle:
          c.toggleNoteAddition(note, HitSoundFlags.whistle);
        case HitsoundLayer.finish:
          c.toggleNoteAddition(note, HitSoundFlags.finish);
        case HitsoundLayer.clap:
          c.toggleNoteAddition(note, HitSoundFlags.clap);
        case HitsoundLayer.timing:
          break;
      }
      return;
    }
    final body = _bodyAt(x);
    if (body == null || body.sample.filename.isNotEmpty) return;
    switch (layer) {
      case HitsoundLayer.sampleSet:
        c.cycleBodySet(body, addition: false);
      case HitsoundLayer.additions:
        if (body.hitSound & HitSoundFlags.whistle != 0) c.cycleBodySet(body, addition: true);
      case HitsoundLayer.whistle:
        c.toggleBodyWhistle(body);
      default:
        break;
    }
  }

  void _onLongPressStart(LongPressStartDetails d) {
    final layer = HitsoundGeometry(_height).layerAt(d.localPosition.dy);
    final x = d.localPosition.dx;
    if (layer == null) return;
    if (layer == HitsoundLayer.timing) {
      final p = _timingPointAt(x);
      if (p != null) HitsoundSampleDialog.show(context, c, point: p);
      return;
    }
    final HitObject? o = _noteAt(x)?.object ?? _bodyAt(x);
    if (o is SliderObject) {
      // osu! ignores a slider's own index / volume: its timing point's count.
      final p = c.timing.effectivePointAt(o.time + 5);
      if (p != null) {
        HitsoundSampleDialog.show(context, c,
            point: p, note: "Sliders use their timing point's sample index and volume (osu! ignores a slider's own).");
      }
    } else if (o != null) {
      HitsoundSampleDialog.show(context, c, object: o);
    }
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    _stopFling();
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isAltPressed) {
      c.stepTimelineZoom(e.scrollDelta.dy > 0 ? -1 : 1);
    } else {
      c.pause();
      c.stepBeat(forward: e.scrollDelta.dy > 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      _width = constraints.maxWidth;
      _height = constraints.maxHeight;
      return Listener(
        onPointerSignal: _onPointerSignal,
        onPointerDown: (_) => _stopFling(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: _onTapUp,
          onLongPressStart: _onLongPressStart,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          child: RepaintBoundary(
            child: CustomPaint(painter: HitsoundPainter(c), size: Size(_width, _height)),
          ),
        ),
      );
    });
  }
}

/// Long press on the Hitsound screen: an object's own sample index and
/// volume (0 = from the timing point), or a timing point's. Each change is
/// one undo step.
class HitsoundSampleDialog extends StatefulWidget {
  final EditorController controller;
  final HitObject? object;
  final TimingPoint? point;

  /// Shown above the controls (why this point is being edited).
  final String? note;

  const HitsoundSampleDialog({super.key, required this.controller, this.object, this.point, this.note})
      : assert((object == null) != (point == null));

  static Future<void> show(BuildContext context, EditorController controller,
          {HitObject? object, TimingPoint? point, String? note}) =>
      showDialog<void>(
        context: context,
        builder: (_) => HitsoundSampleDialog(controller: controller, object: object, point: point, note: note),
      );

  static const maxIndex = 99;

  @override
  State<HitsoundSampleDialog> createState() => _HitsoundSampleDialogState();
}

class _HitsoundSampleDialogState extends State<HitsoundSampleDialog> {
  late HitObject? _object = widget.object;
  late TimingPoint? _point = widget.point;

  EditorController get c => widget.controller;

  int get _index => _object?.sample.index ?? _point!.sampleIndex;
  int get _volume => _object?.sample.volume ?? _point!.volume;

  /// The volume an object without its own plays at (its timing point's).
  int get _inheritedVolume => c.timing.effectivePointAt(_object!.time + 5)?.volume ?? 100;

  void _set({int? index, int? volume}) => setState(() {
        final o = _object, p = _point;
        if (o != null) {
          _object = c.setObjectSample(o, index: index, volume: volume);
        } else if (p != null) {
          _point = c.updateTimingPoint(p, p.copyWith(sampleIndex: index, volume: volume));
        }
      });

  String get _title {
    final o = _object, p = _point;
    final time = EditorTimestamp((o?.time ?? p!.time).round()).format().replaceAll(' - ', '');
    final kind = switch (o) {
      SliderObject() => 'Slider',
      Spinner() => 'Spinner',
      HitObject() => 'Circle',
      null => p!.uninherited ? 'Timing point' : 'Inherited point',
    };
    return '$kind $time';
  }

  @override
  Widget build(BuildContext context) {
    final object = _object != null;
    final index = _index, volume = _volume;
    final ownVolume = !object || volume != 0;
    return Theme(
      data: compactFormTheme(Theme.of(context)),
      child: AlertDialog(
        title: Text(_title, style: Theme.of(context).textTheme.titleMedium),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.note != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(widget.note!, style: Theme.of(context).textTheme.bodySmall),
                ),
              Row(
                children: [
                  const Expanded(child: Text('Sample index')),
                  IconButton(
                    tooltip: 'Lower index',
                    icon: const Icon(Icons.remove),
                    onPressed: index > 0 ? () => _set(index: index - 1) : null,
                  ),
                  SizedBox(
                    width: 64,
                    child: Text(
                      index == 0 ? (object ? 'Inherit' : 'Default') : '$index',
                      textAlign: TextAlign.center,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Raise index',
                    icon: const Icon(Icons.add),
                    onPressed: index < HitsoundSampleDialog.maxIndex ? () => _set(index: index + 1) : null,
                  ),
                ],
              ),
              if (object)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Own volume'),
                  value: ownVolume,
                  onChanged: (on) => _set(volume: on ? _inheritedVolume : 0),
                ),
              CommitSlider(
                label: 'Volume',
                value: (ownVolume ? volume : _inheritedVolume).toDouble(),
                min: 5,
                max: 100,
                divisions: 95,
                format: (v) => '${v.round()}%',
                onCommit: ownVolume ? (v) => _set(volume: v.round()) : null,
              ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }
}
