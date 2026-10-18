import 'package:flutter/material.dart';

import '../../app_fonts.dart';

/// A text field that commits its value on submit / focus loss instead of on
/// every keystroke (each commit is one undo step). [onCommit] returns false
/// to reject the text, which then reverts to [value]. External changes to
/// [value] (undo, another control) show up while the field isn't focused.
/// [validate] checks the text as it is typed: its message is shown under
/// the field, and invalid text is never committed (it reverts instead).
class CommitTextField extends StatefulWidget {
  final String value;
  final String label;
  final bool Function(String text) onCommit;
  final TextInputType? keyboardType;
  final String? suffix;
  final String? errorText;
  final String? Function(String text)? validate;

  const CommitTextField({
    super.key,
    required this.value,
    required this.label,
    required this.onCommit,
    this.keyboardType,
    this.suffix,
    this.errorText,
    this.validate,
  });

  @override
  State<CommitTextField> createState() => _CommitTextFieldState();
}

class _CommitTextFieldState extends State<CommitTextField> {
  late final TextEditingController _text = TextEditingController(text: widget.value);
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  void _onFocus() {
    if (!_focus.hasFocus) _commit();
  }

  @override
  void didUpdateWidget(CommitTextField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _text.text != widget.value) _text.text = widget.value;
  }

  @override
  void dispose() {
    // Text still being edited when the screen closes is dropped.
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  /// Text already handed to [CommitTextField.onCommit], so the focus loss
  /// after a submit doesn't commit it a second time.
  String? _committed;

  void _commit() {
    final text = _text.text;
    if (text == widget.value || text == _committed) return;
    if (widget.validate?.call(text) == null && widget.onCommit(text)) {
      _committed = text;
    } else {
      setState(() => _text.text = widget.value);
    }
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _text,
        focusNode: _focus,
        keyboardType: widget.keyboardType,
        decoration: InputDecoration(
          labelText: widget.label.isEmpty ? null : widget.label,
          suffixText: widget.suffix,
          errorText: widget.validate?.call(_text.text) ?? widget.errorText,
          isDense: true,
        ),
        onChanged: widget.validate == null ? null : (_) => setState(() {}),
        onSubmitted: (_) => _commit(),
      );
}

/// A labelled Material [Slider] that only reports the final value
/// ([onCommit] on release), so a drag is one undo step. Shows the value
/// being dragged via [format]. With [parse] the value is a small text
/// field instead, so it can also be typed: [parse] turns the text into a
/// value (null rejects it; it may lie outside the slider's range) that goes
/// to [onCommit] like a drag.
class CommitSlider extends StatefulWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String Function(double) format;
  final ValueChanged<double>? onCommit;
  final double? Function(String text)? parse;

  /// Text in the [parse] field (defaults to [format]) and its suffix.
  final String Function(double)? fieldFormat;
  final String? fieldSuffix;

  /// Lays the label, slider and value out in one row (label [labelWidth]
  /// wide) instead of the label / value above the slider.
  final bool inline;
  final double labelWidth;

  const CommitSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.format,
    required this.onCommit,
    this.divisions,
    this.parse,
    this.fieldFormat,
    this.fieldSuffix,
    this.inline = false,
    this.labelWidth = 36,
  });

  @override
  State<CommitSlider> createState() => _CommitSliderState();
}

class _CommitSliderState extends State<CommitSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final v = (_dragging ?? widget.value).clamp(widget.min, widget.max).toDouble();
    final parse = widget.parse, commit = widget.onCommit;
    if (widget.inline) {
      return Row(
        children: [
          SizedBox(width: widget.labelWidth, child: Text(widget.label)),
          Expanded(child: _slider(v)),
          SizedBox(
            width: 40,
            child: Text(
              widget.format(v),
              textAlign: TextAlign.end,
              style: monoNumbers,
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Expanded(child: Text(widget.label)),
              if (parse == null || commit == null)
                Text(widget.format(v), style: monoNumbers),
              if (parse != null && commit != null)
                SizedBox(
                  width: 72,
                  child: CommitTextField(
                    label: '',
                    // The typed value itself when it is off the slider.
                    value: (widget.fieldFormat ?? widget.format)(_dragging ?? widget.value),
                    suffix: widget.fieldSuffix,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onCommit: (text) {
                      final x = parse(text.trim());
                      if (x == null) return false;
                      commit(x);
                      return true;
                    },
                  ),
                ),
            ],
          ),
        ),
        _slider(v),
      ],
    );
  }

  Widget _slider(double v) => Slider(
        value: v,
        min: widget.min,
        max: widget.max,
        divisions: widget.divisions,
        label: widget.format(v),
        onChanged: widget.onCommit == null ? null : (x) => setState(() => _dragging = x),
        onChangeEnd: (x) {
          setState(() => _dragging = null);
          widget.onCommit?.call(x);
        },
      );
}

/// Denser controls for the timing panels: compact density, no padding up to
/// 48 dp tap targets, 14 sp field text, a slimmer slider.
ThemeData compactFormTheme(ThemeData t) => t.copyWith(
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textTheme: t.textTheme.copyWith(bodyLarge: t.textTheme.bodyMedium, titleMedium: t.textTheme.bodyMedium),
      inputDecorationTheme: t.inputDecorationTheme.copyWith(isDense: true),
      sliderTheme: t.sliderTheme.copyWith(
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      ),
    );
