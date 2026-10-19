import 'package:flutter/material.dart';

/// The app's own dialog (replaces Material's [AlertDialog]): a rounded
/// surface card in the style of the Song setup sections, a bold title, the
/// content, and a right-aligned row of buttons. Same parameters as
/// [AlertDialog], so call sites keep their paddings.
class AppDialog extends StatelessWidget {
  final Widget? title;
  final Widget? content;
  final List<Widget> actions;
  final EdgeInsets insetPadding;
  final EdgeInsets titlePadding;
  final EdgeInsets contentPadding;
  final EdgeInsets actionsPadding;

  const AppDialog({
    super.key,
    this.title,
    this.content,
    this.actions = const [],
    this.insetPadding = const EdgeInsets.symmetric(horizontal: 40, vertical: 12),
    this.titlePadding = const EdgeInsets.fromLTRB(24, 20, 24, 0),
    this.contentPadding = const EdgeInsets.fromLTRB(24, 12, 24, 0),
    this.actionsPadding = const EdgeInsets.fromLTRB(16, 8, 16, 12),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    return Dialog(
      insetPadding: insetPadding,
      backgroundColor: s.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Padding(
                padding: titlePadding,
                child: DefaultTextStyle(
                  style: theme.textTheme.titleLarge!.copyWith(color: s.onSurface, fontWeight: FontWeight.w600),
                  child: title!,
                ),
              ),
            if (content != null)
              Flexible(
                child: Padding(
                  padding: contentPadding,
                  child: DefaultTextStyle(
                    style: theme.textTheme.bodyMedium!.copyWith(color: s.onSurfaceVariant),
                    child: content!,
                  ),
                ),
              ),
            if (actions.isNotEmpty)
              Padding(
                padding: actionsPadding,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 4,
                  children: actions,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
