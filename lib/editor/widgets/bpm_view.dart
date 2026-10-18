import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../editor_controller.dart';
import '../render/bpm_painter.dart';

/// The Timing mode's BPM view, for timing a song by eye: no objects, only
/// the song and the beat grid of its red points.
/// * Strip (top): the detailed waveform around the playhead (own zoom)
///   with the metronome ticks of the beat divisor and the red points.
///   One-finger drag scrubs, pinch / Ctrl + wheel zooms, a tap seeks there
///   (snapped), the wheel steps by the divisor.
/// * Beat rows (below): lazer's waveform comparison — one row per beat (or
///   bar) of the red point at the playhead, each centred on its beat
///   ([BpmRowsPainter]). Vertical drag scrolls through the rows, a tap
///   seeks to that spot (snapped), the wheel steps by a row.
///
/// The detailed waveform is decoded when the view first opens (a few
/// seconds); until then the timeline's coarse envelope stands in.
class BpmView extends StatefulWidget {
  final EditorController controller;
  const BpmView({super.key, required this.controller});

  @override
  State<BpmView> createState() => _BpmViewState();
}

class _BpmViewState extends State<BpmView> {
  EditorController get c => widget.controller;

  /// Strip: ms across its width.
  double _stripMs = 1500;
  double _stripMsAtStart = 1500;
  double _stripWidth = 0;
  bool _scrubbed = false;

  /// Rows are bars instead of beats.
  bool _bars = false;

  /// Rows: height in logical pixels and where a vertical drag started.
  double _rowHeight = 30;
  double _rowsDrag = 0;

  /// Height of a row as laid out (the rows fill the view).
  double _laidOutRowHeight = 30;

  static const _minStripMs = 40.0, _maxStripMs = 20000.0;

  @override
  void initState() {
    super.initState();
    c.requestDetailedWaveform();
  }

  @override
  void didUpdateWidget(BpmView old) {
    super.didUpdateWidget(old);
    c.requestDetailedWaveform(); // the audio may have been swapped
  }

  double get _stripZoom => _stripWidth <= 0 ? 1 : _stripWidth / _stripMs;

  // ---------------------------------------------------------------------------
  // Strip gestures

  void _stripScaleStart(ScaleStartDetails d) {
    _stripMsAtStart = _stripMs;
    _scrubbed = false;
  }

  void _stripScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount >= 2) {
      if (d.horizontalScale > 0) {
        setState(() => _stripMs = (_stripMsAtStart / d.horizontalScale).clamp(_minStripMs, _maxStripMs));
      }
      return;
    }
    final dx = d.focalPointDelta.dx;
    if (dx == 0) return;
    if (!_scrubbed) {
      c.pause();
      _scrubbed = true;
    }
    c.seek(c.time.value - dx / _stripZoom);
  }

  void _stripTap(TapUpDetails d) {
    final t = c.time.value + (d.localPosition.dx - _stripWidth / 2) / _stripZoom;
    c.seek(c.timing.snap(t, c.divisor));
  }

  void _stripWheel(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isAltPressed) {
      setState(() => _stripMs = (_stripMs * (e.scrollDelta.dy > 0 ? 1.25 : 0.8)).clamp(_minStripMs, _maxStripMs));
    } else {
      c.pause();
      c.stepBeat(forward: e.scrollDelta.dy > 0);
    }
  }

  // ---------------------------------------------------------------------------
  // Rows gestures

  BpmRows? _rows(int count) => BpmRows.at(c.timing, c.time.value, bars: _bars, count: count);

  void _rowsDragStart(DragStartDetails d) {
    c.pause();
    _rowsDrag = 0;
  }

  void _rowsDragUpdate(DragUpdateDetails d) {
    final rows = _rows(1);
    if (rows == null) return;
    // Dragging up brings later rows up: the playhead moves on by a row's
    // length per row height dragged.
    _rowsDrag -= d.delta.dy;
    final ms = _rowsDrag / _laidOutRowHeight * rows.length;
    if (ms.abs() < 1) return;
    _rowsDrag = 0;
    c.seek(c.time.value + ms);
  }

  void _rowsTap(TapUpDetails d, Size size, int count) {
    final rows = _rows(count);
    if (rows == null) return;
    final i = (d.localPosition.dy / (size.height / count)).floor().clamp(0, count - 1);
    final width = size.width - BpmRowsPainter.gutter;
    if (width <= 0) return;
    final f = ((d.localPosition.dx - BpmRowsPainter.gutter) / width).clamp(0.0, 1.0);
    c.seek(c.timing.snap(rows.timeAt(i, f), c.divisor));
  }

  void _rowsWheel(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final rows = _rows(1);
    if (rows == null) return;
    c.pause();
    final forward = e.scrollDelta.dy > 0;
    final t = c.time.value + (forward ? rows.length : -rows.length);
    c.seek(c.timing.snap(t, c.divisor));
  }

  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final loading = c.detailedWaveformLoading;
    final hasRed = c.timing.redPoints.isNotEmpty;
    return ColoredBox(
      color: const Color(0xFF101216),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: what the rows are, waveform status.
          SizedBox(
            height: 30,
            child: Row(
              children: [
                const SizedBox(width: 8),
                Text('Rows', style: small),
                const SizedBox(width: 6),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity(horizontal: -4, vertical: -4),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  segments: const [
                    ButtonSegment(value: false, label: Text('Beat')),
                    ButtonSegment(value: true, label: Text('Bar')),
                  ],
                  selected: {_bars},
                  onSelectionChanged: (s) => setState(() => _bars = s.first),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: 'Taller rows',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  onPressed: _rowHeight < 80 ? () => setState(() => _rowHeight += 10) : null,
                  icon: const Icon(Icons.unfold_more),
                ),
                IconButton(
                  tooltip: 'More rows',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  onPressed: _rowHeight > 20 ? () => setState(() => _rowHeight -= 10) : null,
                  icon: const Icon(Icons.unfold_less),
                ),
                const Spacer(),
                if (loading) ...[
                  const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                  const SizedBox(width: 6),
                  Text('Decoding waveform…', style: small),
                  const SizedBox(width: 8),
                ] else if (!c.hasAudio)
                  Padding(padding: const EdgeInsets.only(right: 8), child: Text('No audio', style: small)),
              ],
            ),
          ),
          // Strip.
          Expanded(
            flex: 3,
            child: LayoutBuilder(builder: (context, constraints) {
              _stripWidth = constraints.maxWidth;
              return Listener(
                onPointerSignal: _stripWheel,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: _stripTap,
                  onScaleStart: _stripScaleStart,
                  onScaleUpdate: _stripScaleUpdate,
                  child: RepaintBoundary(
                    child: CustomPaint(
                      key: const ValueKey('bpm-strip'),
                      painter: BpmStripPainter(c, zoom: _stripZoom, dpr: dpr),
                      size: Size(constraints.maxWidth, constraints.maxHeight),
                    ),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 2),
          // Beat rows.
          Expanded(
            flex: 7,
            child: hasRed
                ? LayoutBuilder(builder: (context, constraints) {
                    final size = Size(constraints.maxWidth, constraints.maxHeight);
                    final count = (size.height / _rowHeight).floor().clamp(1, 32);
                    _laidOutRowHeight = size.height / count;
                    return Listener(
                      onPointerSignal: _rowsWheel,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (d) => _rowsTap(d, size, count),
                        onVerticalDragStart: _rowsDragStart,
                        onVerticalDragUpdate: _rowsDragUpdate,
                        child: RepaintBoundary(
                          child: CustomPaint(
                            key: const ValueKey('bpm-rows'),
                            painter: BpmRowsPainter(c, bars: _bars, count: count, dpr: dpr),
                            size: size,
                          ),
                        ),
                      ),
                    );
                  })
                : Center(child: Text('Add a timing point to see the beat rows.', style: small)),
          ),
        ],
      ),
    );
  }
}
