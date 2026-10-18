// osu! editor timestamps: "00:01:234 (1,2,3) - " — what stable puts on the
// clipboard when objects are copied, and what modding posts link to.

class EditorTimestamp {
  /// Milliseconds.
  final int time;

  /// Combo numbers of the referenced objects, in order (may be empty).
  final List<int> combos;

  const EditorTimestamp(this.time, [this.combos = const []]);

  static final _re = RegExp(r'(\d+):(\d{2}):(\d{3})(?:\s*\(([^)]*)\))?');

  /// The first timestamp in [text], or null. Object lists that aren't plain
  /// combo numbers (mania's `time|column`) are ignored, keeping the time.
  static EditorTimestamp? parse(String text) {
    final m = _re.firstMatch(text);
    if (m == null) return null;
    final time = int.parse(m.group(1)!) * 60000 + int.parse(m.group(2)!) * 1000 + int.parse(m.group(3)!);
    final list = m.group(4);
    if (list == null || list.trim().isEmpty) return EditorTimestamp(time);
    final combos = <int>[];
    for (final part in list.split(',')) {
      final n = int.tryParse(part.trim());
      if (n == null) return EditorTimestamp(time);
      combos.add(n);
    }
    return EditorTimestamp(time, combos);
  }

  /// Stable's clipboard text, e.g. `00:01:234 (1,2,3) - `.
  String format() {
    final t = time < 0 ? 0 : time;
    String p(int v, int w) => v.toString().padLeft(w, '0');
    final s = '${p(t ~/ 60000, 2)}:${p((t ~/ 1000) % 60, 2)}:${p(t % 1000, 3)}';
    return combos.isEmpty ? '$s - ' : '$s (${combos.join(',')}) - ';
  }
}
