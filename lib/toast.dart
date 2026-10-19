import 'dart:async';

import 'package:flutter/material.dart';

/// In-app toast notifications (replaces Material snack bars). Call
/// [AppToast.show] from anywhere, no [BuildContext] needed; [ToastHost]
/// (installed by `MaterialApp.builder`) draws it above every screen and dialog.
class AppToast {
  AppToast._();

  static final ValueNotifier<_ToastData?> _current = ValueNotifier(null);
  static int _serial = 0;

  /// Shows [message] at the bottom centre, replacing any toast on screen.
  /// With [actionLabel] / [onAction] the toast carries a button (e.g. Undo).
  static void show(
    String message, {
    Duration duration = const Duration(seconds: 3),
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    _current.value = _ToastData(++_serial, message, duration, actionLabel, onAction);
  }

  static void hide() => _current.value = null;
}

class _ToastData {
  final int id;
  final String message;
  final Duration duration;
  final String? actionLabel;
  final VoidCallback? onAction;
  const _ToastData(this.id, this.message, this.duration, this.actionLabel, this.onAction);
}

class ToastHost extends StatefulWidget {
  final Widget? child;
  const ToastHost({super.key, this.child});

  @override
  State<ToastHost> createState() => _ToastHostState();
}

class _ToastHostState extends State<ToastHost> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    AppToast._current.addListener(_onChanged);
  }

  @override
  void dispose() {
    AppToast._current.removeListener(_onChanged);
    _timer?.cancel();
    super.dispose();
  }

  void _onChanged() {
    _timer?.cancel();
    final t = AppToast._current.value;
    if (t != null) {
      _timer = Timer(t.duration, () {
        if (AppToast._current.value?.id == t.id) AppToast.hide();
      });
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = AppToast._current.value;
    final insets = MediaQuery.paddingOf(context);
    return Stack(
      children: [
        if (widget.child != null) Positioned.fill(child: widget.child!),
        Positioned(
          left: 16 + insets.left,
          right: 16 + insets.right,
          bottom: 16 + insets.bottom,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(anim),
                child: child,
              ),
            ),
            child: t == null ? const SizedBox.shrink(key: ValueKey(0)) : _ToastCard(key: ValueKey(t.id), data: t),
          ),
        ),
      ],
    );
  }
}

class _ToastCard extends StatelessWidget {
  final _ToastData data;
  const _ToastCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Material(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
          elevation: 6,
          shadowColor: Colors.black,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: AppToast.hide,
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 10, data.actionLabel == null ? 16 : 6, 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      data.message,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onSurface, fontSize: 14),
                    ),
                  ),
                  if (data.actionLabel != null) ...[
                    const SizedBox(width: 8),
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: scheme.primary),
                      onPressed: () {
                        AppToast.hide();
                        data.onAction?.call();
                      },
                      child: Text(data.actionLabel!),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
