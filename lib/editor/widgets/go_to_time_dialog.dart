import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../app_fonts.dart';

/// What [GoToTimeDialog] was closed with: a time picked on the wheels, or
/// a request for the manual (pasted timestamp) input instead.
sealed class GoToTimeResult {
  const GoToTimeResult();
}

class GoToTimePicked extends GoToTimeResult {
  final int ms;
  const GoToTimePicked(this.ms);
}

class GoToTimeManual extends GoToTimeResult {
  const GoToTimeManual();
}

/// "Go to time": minute / second / millisecond wheels starting at
/// [initialMs]. [maxMs] bounds the minute wheel (the song length when
/// known).
class GoToTimeDialog extends StatefulWidget {
  final int initialMs;
  final int maxMs;
  const GoToTimeDialog({super.key, required this.initialMs, required this.maxMs});

  @override
  State<GoToTimeDialog> createState() => _GoToTimeDialogState();
}

class _GoToTimeDialogState extends State<GoToTimeDialog> {
  static const _itemExtent = 32.0;

  late final int _minutes = math.max(1, widget.maxMs ~/ 60000 + 1);
  late int _m = math.min(widget.initialMs ~/ 60000, _minutes - 1);
  late int _s = (widget.initialMs ~/ 1000) % 60;
  late int _x = widget.initialMs % 1000;
  late final _mCtl = FixedExtentScrollController(initialItem: _m);
  late final _sCtl = FixedExtentScrollController(initialItem: _s);
  late final _xCtl = FixedExtentScrollController(initialItem: _x);

  @override
  void dispose() {
    _mCtl.dispose();
    _sCtl.dispose();
    _xCtl.dispose();
    super.dispose();
  }

  int get _ms => _m * 60000 + _s * 1000 + _x;

  Widget _wheel(FixedExtentScrollController ctl, int count, int digits, ValueChanged<int> onChanged, {bool loop = false}) {
    final style = Theme.of(context).textTheme.titleLarge!.copyWith(fontFamily: kMonoFont);
    return SizedBox(
      width: digits == 3 ? 72 : 56,
      child: CupertinoPicker.builder(
        scrollController: ctl,
        itemExtent: _itemExtent,
        childCount: loop ? null : count,
        onSelectedItemChanged: (i) => onChanged(i % count),
        itemBuilder: (_, i) => loop || (i >= 0 && i < count)
            ? Center(child: Text((i % count).toString().padLeft(digits, '0'), style: style))
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sep = Text(':', style: Theme.of(context).textTheme.titleLarge);
    return AlertDialog(
      title: const Text('Go to time'),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: SizedBox(
        height: _itemExtent * 4,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _wheel(_mCtl, _minutes, 2, (v) => _m = v),
            sep,
            _wheel(_sCtl, 60, 2, (v) => _s = v, loop: true),
            sep,
            _wheel(_xCtl, 1000, 3, (v) => _x = v, loop: true),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, const GoToTimeManual()), child: const Text('Manual input')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, GoToTimePicked(_ms)), child: const Text('Go')),
      ],
    );
  }
}
