/// File / folder naming rules for beatmap sets (matching osu!stable where
/// it matters, and safe on Android, iOS and Windows file systems).
abstract final class BeatmapNaming {
  static final _illegal = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

  /// Windows reserved device names (also avoided so exported sets open
  /// everywhere).
  static const _reserved = {
    'CON', 'PRN', 'AUX', 'NUL', //
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };

  /// Makes [name] a valid single path segment. Never returns empty.
  static String sanitize(String name, {String fallback = 'untitled'}) {
    var s = name.replaceAll(_illegal, '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    // Windows silently drops trailing dots / spaces.
    s = s.replaceAll(RegExp(r'[. ]+$'), '');
    if (s.isEmpty) s = fallback;
    final stem = s.split('.').first.toUpperCase();
    if (_reserved.contains(stem)) s = '_$s';
    // Keep well under common 255-byte limits (UTF-8 may triple the size).
    if (s.length > 80) s = s.substring(0, 80).trimRight();
    return s;
  }

  /// `Artist - Title (Creator) [Version].osu`, like osu!stable.
  static String osuFileName({
    required String artist,
    required String title,
    required String creator,
    required String version,
  }) =>
      '${sanitize('$artist - $title ($creator) [$version]', fallback: 'beatmap')}.osu';

  /// `Artist - Title (Creator).osb`: the name osu!stable looks for to find a
  /// set's storyboard (characters a file name can't hold are dropped; no
  /// shortening, unlike [osuFileName], so long titles still match).
  static String osbFileName({
    required String artist,
    required String title,
    required String creator,
  }) =>
      '${'$artist - $title ($creator)'.replaceAll(_illegal, '')}.osb';

  /// `<SetID> Artist - Title`, or `Artist - Title` for unsubmitted sets.
  static String setFolderName({
    required String artist,
    required String title,
    int? beatmapSetId,
  }) {
    final base = artist.isEmpty && title.isEmpty ? '' : '$artist - $title';
    final id = beatmapSetId != null && beatmapSetId > 0 ? '$beatmapSetId ' : '';
    return sanitize('$id$base', fallback: 'Untitled set');
  }

  /// First of `base`, `base (2)`, `base (3)`, … not in [taken]
  /// (compared case-insensitively).
  static String unique(String base, Iterable<String> taken) {
    final lower = {for (final t in taken) t.toLowerCase()};
    if (!lower.contains(base.toLowerCase())) return base;
    for (var i = 2;; i++) {
      final c = '$base ($i)';
      if (!lower.contains(c.toLowerCase())) return c;
    }
  }
}
