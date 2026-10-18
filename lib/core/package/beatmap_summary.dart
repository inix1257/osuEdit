/// What the library list needs to know about one difficulty, read with a
/// cheap line scan instead of a full parse (a set can have dozens of
/// difficulties with thousands of objects each).
class BeatmapSummary {
  final String title;
  final String artist;
  final String creator;
  final String version;
  final int mode;
  final int? beatmapSetId;
  final int? beatmapId;
  final String audioFilename;
  final int hitObjectCount;

  /// [hitObjectCount] by type (mania hold notes are in none of them).
  final int circleCount;
  final int sliderCount;
  final int spinnerCount;

  /// `[General] PreviewTime` in ms; -1 when unset (osu! then starts the
  /// preview at 40% of the song).
  final int previewTime;

  /// Background image from `[Events]` (`0,0,"bg.jpg",0,0`); empty if none.
  final String backgroundFile;

  /// Start time of the last hit object (0 without objects), in ms.
  final int lastObjectTime;

  /// Lowest / highest BPM of the uninherited timing points; 0 without any.
  final double minBpm;
  final double maxBpm;

  final double circleSize;
  final double approachRate;
  final double overallDifficulty;
  final double hpDrain;

  const BeatmapSummary({
    this.title = '',
    this.artist = '',
    this.creator = '',
    this.version = '',
    this.mode = 0,
    this.beatmapSetId,
    this.beatmapId,
    this.audioFilename = '',
    this.hitObjectCount = 0,
    this.circleCount = 0,
    this.sliderCount = 0,
    this.spinnerCount = 0,
    this.previewTime = -1,
    this.backgroundFile = '',
    this.lastObjectTime = 0,
    this.minBpm = 0,
    this.maxBpm = 0,
    this.circleSize = 5,
    this.approachRate = 5,
    this.overallDifficulty = 5,
    this.hpDrain = 5,
  });

  static BeatmapSummary scan(String text) {
    var section = '';
    final values = <String, String>{};
    var objects = 0, circles = 0, sliders = 0, spinners = 0;
    String? lastObject;
    var background = '';
    double minBpm = 0, maxBpm = 0;
    for (var line in text.split('\n')) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('//')) continue;
      if (line.startsWith('[') && line.endsWith(']')) {
        section = line.substring(1, line.length - 1);
        continue;
      }
      switch (section) {
        case 'HitObjects':
          objects++;
          lastObject = line;
          final parts = line.split(',');
          final type = parts.length >= 4 ? int.tryParse(parts[3].trim()) ?? 0 : 0;
          if (type & 1 != 0) {
            circles++;
          } else if (type & 2 != 0) {
            sliders++;
          } else if (type & 8 != 0) {
            spinners++;
          }
        case 'General' || 'Metadata' || 'Difficulty':
          final i = line.indexOf(':');
          if (i > 0) values.putIfAbsent(line.substring(0, i).trim(), () => line.substring(i + 1).trim());
        case 'Events':
          if (background.isEmpty) {
            final parts = line.split(',');
            final kind = parts[0].trim();
            if (parts.length >= 3 && (kind == '0' || kind == 'Background')) {
              background = parts[2].trim().replaceAll('"', '');
            }
          }
        case 'TimingPoints':
          final parts = line.split(',');
          final beatLength = parts.length >= 2 ? double.tryParse(parts[1].trim()) : null;
          // Uninherited: positive beat length (and `uninherited` not 0).
          final red = parts.length < 7 || parts[6].trim() != '0';
          if (beatLength != null && beatLength > 0 && red) {
            final bpm = 60000 / beatLength;
            if (minBpm == 0 || bpm < minBpm) minBpm = bpm;
            if (bpm > maxBpm) maxBpm = bpm;
          }
      }
    }
    double d(String key) => double.tryParse(values[key] ?? '') ?? 5;
    final od = d('OverallDifficulty');
    final lastParts = lastObject?.split(',');
    return BeatmapSummary(
      title: values['Title'] ?? '',
      artist: values['Artist'] ?? '',
      creator: values['Creator'] ?? '',
      version: values['Version'] ?? '',
      mode: int.tryParse(values['Mode'] ?? '') ?? 0,
      beatmapSetId: int.tryParse(values['BeatmapSetID'] ?? ''),
      beatmapId: int.tryParse(values['BeatmapID'] ?? ''),
      audioFilename: values['AudioFilename'] ?? '',
      hitObjectCount: objects,
      circleCount: circles,
      sliderCount: sliders,
      spinnerCount: spinners,
      previewTime: int.tryParse(values['PreviewTime'] ?? '') ?? -1,
      backgroundFile: background,
      lastObjectTime: lastParts != null && lastParts.length >= 3 ? (double.tryParse(lastParts[2].trim()) ?? 0).round() : 0,
      minBpm: minBpm,
      maxBpm: maxBpm,
      circleSize: d('CircleSize'),
      // Old maps have no ApproachRate: it equals OverallDifficulty.
      approachRate: double.tryParse(values['ApproachRate'] ?? '') ?? od,
      overallDifficulty: od,
      hpDrain: d('HPDrainRate'),
    );
  }

  /// The difficulty's page on the osu! website, or null when the map isn't
  /// submitted: no positive `BeatmapSetID`, and (osu!stable folders are named
  /// `<SetID> Artist - Title`) no leading set number in [folderName] either.
  String? websiteUrl({String? folderName}) {
    var set = beatmapSetId;
    if (set == null || set <= 0) {
      final m = folderName == null ? null : RegExp(r'^(\d+) ').firstMatch(folderName);
      set = m == null ? null : int.tryParse(m.group(1)!);
    }
    if (set == null || set <= 0) return null;
    final id = beatmapId;
    const rulesets = ['osu', 'taiko', 'fruits', 'mania'];
    final ruleset = mode >= 0 && mode < rulesets.length ? rulesets[mode] : 'osu';
    return 'https://osu.ppy.sh/beatmapsets/$set${id != null && id > 0 ? '#$ruleset/$id' : ''}';
  }
}
