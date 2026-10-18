import '../format/osu_parser.dart';
import '../format/osu_writer.dart';
import '../geometry/lazer_path.dart';
import '../model/beatmap.dart';
import '../model/hit_object.dart';
import 'commands.dart';

/// osu!stable vs osu!lazer slider formats: finding sliders only lazer can
/// read (several curve types in one path, B-splines) and converting them to
/// stable's format like lazer's "Export for stable" does.
abstract final class SliderFormatOps {
  /// Sliders of [b] in lazer's path model.
  static Iterable<SliderObject> lazerSliders(Beatmap b) =>
      b.hitObjects.whereType<SliderObject>().where((s) => s.isLazerPath);

  /// [s] in stable's format: the same path if stable can express it,
  /// otherwise bezier pieces of the same shape (circular arcs are
  /// approximated; points rounded to whole osu!pixels). The length is kept.
  /// Stable-format sliders are returned as they are.
  static SliderObject toStable(SliderObject s) {
    final types = s.pointTypes;
    if (types == null) return s;
    final stable = LazerPath.toStableForm(s.allPoints, types);
    final (type, all) = stable ?? (CurveType.bezier, LazerPath.toStableBezier(s.allPoints, types));
    return s.copyWith(
      position: all.first,
      controlPoints: all.sublist(1),
      curveType: type,
      stablePath: true,
    );
  }

  /// One undoable step converting every lazer-format slider of [b], or
  /// null if there are none.
  static EditCommand? convertToStable(Beatmap b) {
    final before = lazerSliders(b).toList();
    if (before.isEmpty) return null;
    return ReplaceHitObjectsCommand(before, [for (final s in before) toStable(s)],
        label: 'Convert sliders to stable format');
  }

  /// [text] (a whole `.osu` file) with its lazer-format sliders converted;
  /// every other line stays as it was. Null if there was nothing to convert.
  static String? convertText(String text) {
    final b = OsuParser.parse(text);
    final command = convertToStable(b);
    if (command == null) return null;
    command.apply(b);
    return OsuWriter.write(b);
  }
}
