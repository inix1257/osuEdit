import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app_fonts.dart';

/// [time] (ms) as `mm:ss:mmm`, centred, repainted every frame from cached
/// glyphs. A [Text] here would lay out a new paragraph every frame during
/// playback; those native paragraphs pile up and are freed together in a
/// GC every ~1.2 s, which on the phone stalled one frame by 10–15 ms each
/// time (and cost ~1.3 ms of UI time per frame).
class TimeText extends StatelessWidget {
  final ValueListenable<double> time;
  final String Function(double ms) format;
  const TimeText({super.key, required this.time, required this.format});

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(monoNumbers);
    // Its own layer: repainting every frame must not re-record the screen
    // around it (the toolbars' labels and icons).
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: TimeTextPainter(time, format, style, MediaQuery.textScalerOf(context)),
      ),
    );
  }
}

class TimeTextPainter extends CustomPainter {
  final ValueListenable<double> time;
  final String Function(double ms) format;
  final TextStyle style;
  final TextScaler scaler;
  TimeTextPainter(this.time, this.format, this.style, this.scaler) : super(repaint: time);

  /// What is shown (for tests).
  String get text => format(time.value);

  // One laid-out painter per character, per style (the font is monospaced:
  // every glyph has the advance of '0').
  static final _glyphs = <(TextStyle, TextScaler), Map<String, TextPainter>>{};

  TextPainter _glyph(String ch) {
    final cache = _glyphs.putIfAbsent((style, scaler), () {
      if (_glyphs.length > 4) _glyphs.clear(); // a theme / text-scale change
      return {};
    });
    return cache[ch] ??= TextPainter(
      text: TextSpan(text: ch, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = text;
    final advance = _glyph('0').width;
    final height = _glyph('0').height;
    var x = (size.width - advance * s.length) / 2;
    final y = (size.height - height) / 2;
    for (var i = 0; i < s.length; i++) {
      final g = _glyph(s[i]);
      g.paint(canvas, Offset(x + (advance - g.width) / 2, y));
      x += advance;
    }
  }

  @override
  bool shouldRepaint(TimeTextPainter old) =>
      old.time != time || old.style != style || old.scaler != scaler || old.format != format;
}
