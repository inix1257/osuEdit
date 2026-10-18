import '../format/osu_parser.dart';
import '../format/osu_writer.dart';
import '../model/beatmap.dart';
import '../package/beatmap_naming.dart';

/// Operations across the difficulties of one set: deriving a new
/// difficulty from an open one, and keeping the set-wide metadata in sync.
abstract final class DifficultyOps {
  /// `[Metadata]` keys shared by every difficulty of a set (everything but
  /// `Version` and `BeatmapID`).
  static const setMetadataKeys = [
    'Title',
    'TitleUnicode',
    'Artist',
    'ArtistUnicode',
    'Creator',
    'Source',
    'Tags',
    'BeatmapSetID',
  ];

  /// A copy of [source] named [version], with a fresh `BeatmapID`. Without
  /// [keepObjects] it is an empty difficulty: same audio, timing, metadata,
  /// difficulty settings and background, but no hit objects, breaks or
  /// bookmarks. Untouched lines keep their original text.
  static Beatmap derive(Beatmap source, {required String version, bool keepObjects = false}) {
    final b = OsuParser.parse(OsuWriter.write(source));
    b.setValue(SectionNames.metadata, 'Version', version);
    if (b.getValue(SectionNames.metadata, 'BeatmapID') != null) {
      b.setValue(SectionNames.metadata, 'BeatmapID', '0');
    }
    if (!keepObjects) {
      b.hitObjects.clear();
      // Comments about the removed objects go with them.
      for (final s in b.sections) {
        if (s is ModeledSection && s.name == SectionNames.hitObjects) s.extraLines.clear();
      }
      b.removeValue(SectionNames.editor, 'Bookmarks');
      for (final s in b.sections) {
        if (s is RawSection && s.name == SectionNames.events) {
          s.lines.removeWhere(_isBreak);
        }
      }
    }
    b.revision = 0;
    return b;
  }

  static bool _isBreak(String line) {
    final kind = line.split(',').first.trim();
    return kind == '2' || kind == 'Break';
  }

  /// The set metadata of [b], keyed by `[Metadata]` key (missing keys are
  /// left out).
  static Map<String, String> setMetadataOf(Beatmap b) => {
        for (final k in setMetadataKeys) k: ?b.getValue(SectionNames.metadata, k),
      };

  /// Writes [values] into [target]'s `[Metadata]`. Only keys whose value
  /// differs are touched (others keep their original line). Returns whether
  /// anything changed.
  static bool applySetMetadata(Beatmap target, Map<String, String> values) {
    var changed = false;
    for (final MapEntry(:key, :value) in values.entries) {
      if (target.getValue(SectionNames.metadata, key) == value) continue;
      target.setValue(SectionNames.metadata, key, value);
      changed = true;
    }
    return changed;
  }

  /// The set storyboard name osu!stable expects for [b]'s metadata:
  /// `Artist - Title (Creator).osb`.
  static String osbFileNameOf(Beatmap b) =>
      BeatmapNaming.osbFileName(artist: b.artist, title: b.title, creator: b.creator);

  /// The file name osu!stable gives [b]: `Artist - Title (Creator) [Version].osu`.
  static String fileNameOf(Beatmap b) => BeatmapNaming.osuFileName(
        artist: b.artist,
        title: b.title,
        creator: b.creator,
        version: b.version,
      );
}
