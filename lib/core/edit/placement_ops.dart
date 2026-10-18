import '../geometry/slider_shape.dart';
import '../model/hit_object.dart';

/// Placing an object where another one already starts replaces it.
abstract final class PlacementOps {
  /// Objects of [objects] (sorted by time) that start at [time], as the
  /// file would store it (whole ms): a slider counts by its head only.
  static List<HitObject> startingAt(List<HitObject> objects, double time) {
    final ms = time.round();
    return [for (final h in objects) if (h.time.round() == ms) h];
  }

  /// [placed] with the hitsounds of [old], the object it replaces.
  ///
  /// * Both sliders: all of [old]'s sounds (body, sample, per-edge sounds
  ///   and sets, resized to [placed]'s repeats).
  /// * Otherwise [old]'s head sound: for a slider [old] its first edge
  ///   (its edge sound and sets, falling back to the slider's), for a
  ///   circle / spinner its own; it becomes [placed]'s sound (for a slider
  ///   [placed], its head edge, the sets as its sample sets).
  ///
  /// Custom index, volume and file name come along. The new combo of
  /// [old] (and its colour skip) is kept when [placed] has none.
  static HitObject withSoundsOf(HitObject placed, HitObject old) {
    final keepCombo = old.newCombo && !placed.newCombo;
    HitObject combo(HitObject h) => keepCombo ? h.copyWithBase(newCombo: true, comboSkip: old.comboSkip) : h;

    if (placed is SliderObject && old is SliderObject) {
      final n = placed.slides;
      return combo(placed.copyWith(
        hitSound: old.hitSound,
        sample: old.sample,
        edgeSounds: SliderShape.resizeEdges(old.edgeSounds ?? [for (var i = 0; i <= old.slides; i++) old.hitSound], n, 0),
        edgeSets: SliderShape.resizeEdges(old.edgeSets, n, const EdgeSet(0, 0)),
      ));
    }

    // [old]'s head: flags and sample sets.
    var flags = old.hitSound;
    var normal = old.sample.normalSet, addition = old.sample.additionSet;
    if (old is SliderObject) {
      final sounds = old.edgeSounds, sets = old.edgeSets;
      if (sounds != null && sounds.isNotEmpty) flags = sounds.first;
      if (sets != null && sets.isNotEmpty) {
        if (sets.first.normalSet != 0) normal = sets.first.normalSet;
        if (sets.first.additionSet != 0) addition = sets.first.additionSet;
      }
    }
    final sample = HitSample(
      normalSet: normal,
      additionSet: addition,
      index: old.sample.index,
      volume: old.sample.volume,
      filename: old.sample.filename,
    );
    if (placed is SliderObject) {
      final edges = placed.slides + 1;
      return combo(placed.copyWith(
        hitSound: 0,
        sample: sample,
        edgeSounds: [flags, for (var i = 1; i < edges; i++) 0],
        edgeSets: List.filled(edges, const EdgeSet(0, 0)),
      ));
    }
    return combo(placed.copyWithBase(hitSound: flags, sample: sample));
  }
}
