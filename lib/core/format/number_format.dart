// Number formatting/parsing helpers matching what osu! reads and writes.

/// Writes integral values without a decimal point ("120", not "120.0") and
/// everything else with Dart's shortest round-trip representation.
String formatNumber(double v) {
  if (v.isFinite && v == v.roundToDouble() && v.abs() < 1e15) {
    return v.toInt().toString();
  }
  return v.toString();
}

/// Lenient int parse: accepts "4", " 4 ", "4.0" (seen in hand-edited maps).
int? parseIntLenient(String s) {
  final t = s.trim();
  return int.tryParse(t) ?? double.tryParse(t)?.toInt();
}

double? parseDoubleLenient(String s) => double.tryParse(s.trim());
