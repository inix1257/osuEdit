import 'package:flutter/material.dart';

import 'form_fields.dart';

/// The look shared by the Song setup, Timing and Control Points panels:
/// compact controls, borderless filled fields and rounded buttons on flat
/// rounded section cards ([SetupSection]) with small pills for values
/// ([SetupPill]).
ThemeData setupTheme(ThemeData base) {
  final t = compactFormTheme(base);
  final s = t.colorScheme;
  final radius = BorderRadius.circular(10);
  OutlineInputBorder border([Color? color]) => OutlineInputBorder(
    borderRadius: radius,
    borderSide: color == null ? BorderSide.none : BorderSide(color: color, width: 1.5),
  );
  final shape = WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: radius));
  const padding = WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12, vertical: 8));
  return t.copyWith(
    inputDecorationTheme: t.inputDecorationTheme.copyWith(
      filled: true,
      fillColor: s.surfaceContainerHighest,
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      border: border(),
      enabledBorder: border(),
      disabledBorder: border(),
      focusedBorder: border(s.primary),
      errorBorder: border(s.error),
      focusedErrorBorder: border(s.error),
      labelStyle: TextStyle(color: s.onSurfaceVariant),
    ),
    textButtonTheme: TextButtonThemeData(style: ButtonStyle(shape: shape, padding: padding)),
    filledButtonTheme: FilledButtonThemeData(style: ButtonStyle(shape: shape, padding: padding)),
    sliderTheme: t.sliderTheme.copyWith(trackHeight: 4, inactiveTrackColor: s.surfaceContainerHighest),
  );
}

/// A flat rounded card with a small icon (or colour [marker]) and caps
/// title, optional [trailing] widgets on the title row.
class SetupSection extends StatelessWidget {
  final IconData? icon;

  /// A small colour square instead of the icon (timing point kind).
  final Color? marker;
  final String title;

  /// Under the title, smaller (e.g. the point's time).
  final String? subtitle;
  final List<Widget> trailing;
  final List<Widget> children;

  const SetupSection({
    super.key,
    this.icon,
    this.marker,
    required this.title,
    this.subtitle,
    this.trailing = const [],
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final m = marker;
    final sub = subtitle;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.fromLTRB(14, trailing.isEmpty ? 12 : 4, trailing.isEmpty ? 14 : 4, 14),
      decoration: BoxDecoration(color: s.surfaceContainerLow, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: trailing.isEmpty ? null : 40,
            child: Row(
              children: [
                if (m != null)
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(color: m, borderRadius: BorderRadius.circular(3)),
                  )
                else if (icon != null)
                  Icon(icon, size: 16, color: s.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: s.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.1,
                        ),
                      ),
                      if (sub != null)
                        Text(
                          sub,
                          maxLines: 1,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                    ],
                  ),
                ),
                ...trailing,
              ],
            ),
          ),
          SizedBox(height: trailing.isEmpty ? 12 : 6),
          Padding(
            padding: EdgeInsets.only(right: trailing.isEmpty ? 0 : 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ],
      ),
    );
  }
}

/// [child] in a small rounded pill (tabular figures).
class SetupPill extends StatelessWidget {
  final Widget child;
  const SetupPill({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    child: DefaultTextStyle.merge(
      style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
      child: child,
    ),
  );
}

/// A pill showing [value]'s name with a compact pick-one menu of [choices];
/// [value] null shows [mixed] (several values).
class SetupChoicePill<T> extends StatelessWidget {
  final T? value;
  final List<T> choices;
  final String Function(T) name;
  final ValueChanged<T> onPick;
  final String tooltip;
  final String mixed;

  const SetupChoicePill({
    super.key,
    required this.value,
    required this.choices,
    required this.name,
    required this.onPick,
    required this.tooltip,
    this.mixed = 'Mixed',
  });

  @override
  Widget build(BuildContext context) {
    final v = value;
    return PopupMenuButton<T>(
      initialValue: v,
      tooltip: tooltip,
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      onSelected: onPick,
      itemBuilder: (_) => [for (final c in choices) PopupMenuItem(value: c, height: 36, child: Text(name(c)))],
      child: SetupPill(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(v == null ? mixed : name(v)),
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// A 40 dp row: [label] (and an optional [subtitle]) with [trailing] at
/// the end; [onTap] makes the whole row tappable (a switch's label).
class SetupRow extends StatelessWidget {
  final String label;
  final String? subtitle;
  final Widget trailing;
  final VoidCallback? onTap;

  const SetupRow({super.key, required this.label, this.subtitle, required this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 40),
      child: Row(
        children: [
          Expanded(
            child: sub == null
                ? Text(label)
                : Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label),
                        Text(sub, style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
          ),
          trailing,
        ],
      ),
    );
    final tap = onTap;
    return tap == null ? row : InkWell(onTap: tap, borderRadius: BorderRadius.circular(10), child: row);
  }
}

/// A small rounded tonal button for fine steps (±1 BPM, ±10 ms).
class SetupStepButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final double width;
  const SetupStepButton(this.label, this.onPressed, {super.key, this.width = 44});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: 34,
    child: FilledButton.tonal(
      style: FilledButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: Size(width, 34),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onPressed: onPressed,
      child: Text(label),
    ),
  );
}
