import 'dart:typed_data';

import '../model/beatmap.dart';
import 'easing.dart';

/// Storyboard layers, in draw order (numbers as written in event lines).
enum StoryboardLayer { background, fail, pass, foreground, overlay }

/// Where a sprite's position sits on its image, as fractions of its size.
enum StoryboardOrigin {
  topLeft(0, 0),
  centre(0.5, 0.5),
  centreLeft(0, 0.5),
  topRight(1, 0),
  bottomCentre(0.5, 1),
  topCentre(0.5, 0),
  // osu! stable treats Custom as TopLeft.
  custom(0, 0),
  centreRight(1, 0.5),
  bottomLeft(0, 1),
  bottomRight(1, 1);

  final double x, y;
  const StoryboardOrigin(this.x, this.y);
}

/// A tint multiplied into a sprite's image (`C` command), 0–255 per channel.
class StoryboardColour {
  final double r, g, b;
  const StoryboardColour(this.r, this.g, this.b);

  static const white = StoryboardColour(255, 255, 255);

  bool get isWhite => r >= 255 && g >= 255 && b >= 255;
}

/// The commands of one property (with [dims] components: 1 for F/S/R/MX/MY,
/// 2 for V, 3 for C), packed as float32 — big storyboards have a million
/// commands. Per command: `easing, start, end, from[dims], to[dims]`,
/// sorted by start time (ties keep line order, so the later line wins).
class CommandTimeline {
  final int dims;
  final Float32List _data;

  /// Number of commands.
  final int length;

  /// Earliest start / latest end (±infinity when empty).
  final double start, end;

  CommandTimeline._(this.dims, this._data, this.length, this.start, this.end);

  static final _empty = [
    for (var d = 0; d <= 3; d++) CommandTimeline._(d, Float32List(0), 0, double.infinity, double.negativeInfinity),
  ];

  bool get isEmpty => length == 0;

  int get _stride => 3 + 2 * dims;

  double startOf(int i) => _data[i * _stride + 1];
  double endOf(int i) => _data[i * _stride + 2];

  /// Start times in order.
  List<double> get starts => [for (var i = 0; i < length; i++) startOf(i)];

  /// Component [c] at [time]: before the first command, its start value;
  /// otherwise the latest-started command's value (held after it ends).
  /// Must not be empty.
  double valueAt(double time, [int c = 0]) {
    final d = _data, st = _stride;
    var lo = 0, hi = length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (d[mid * st + 1] <= time) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo == 0) return d[3 + c];
    final o = (lo - 1) * st;
    final from = d[o + 3 + c], to = d[o + 3 + dims + c];
    final e = d[o + 2];
    if (time >= e) return to;
    final s = d[o + 1];
    return from + (to - from) * StoryboardEasing.apply(d[o].toInt(), (time - s) / (e - s));
  }
}

/// `P` command kinds.
enum StoryboardParameter { flipH, flipV, additive }

/// A `P` command: [parameter] is on during [start]..[end]; an instant one
/// (start == end) stays on for the sprite's whole life (osu!).
class StoryboardParameterCommand {
  final StoryboardParameter parameter;
  final double start, end;
  const StoryboardParameterCommand(this.parameter, this.start, this.end);

  bool activeAt(double time) => start == end || (time >= start && time < end);

  StoryboardParameterCommand shifted(double by) => StoryboardParameterCommand(parameter, start + by, end + by);
}

/// A sprite's state at one moment, in storyboard pixels (640x480).
/// Mutable so the painter can reuse one per frame ([StoryboardSprite.stateInto]).
class SpriteState {
  double x = 0, y = 0, scaleX = 1, scaleY = 1, rotation = 0, opacity = 1;

  /// Tint, 0–255 per channel.
  double r = 255, g = 255, b = 255;
  bool flipH = false, flipV = false, additive = false;

  StoryboardColour get colour => StoryboardColour(r, g, b);
  bool get isTinted => r < 255 || g < 255 || b < 255;
}

/// A `Sample` event: a sound played at [time] (Fail-layer samples are
/// dropped: the editor shows the Pass state).
class StoryboardSample {
  final double time;

  /// File relative to the set folder, with `/` separators.
  final String path;

  /// 0–100.
  final int volume;

  const StoryboardSample(this.time, this.path, this.volume);
}

/// A `Sprite` or `Animation` event and its commands (loops expanded).
///
/// Triggers (`T`) are ignored, like osu!lazer: the editor has no gameplay
/// to fire them.
class StoryboardSprite {
  final StoryboardLayer layer;
  final StoryboardOrigin origin;

  /// Image path relative to the set folder, with `/` separators. For an
  /// animation, the name its frame files are made from ([framePaths]).
  final String path;
  final double initialX, initialY;

  /// Animation frames (1 for a plain sprite) shown [frameDelay] ms each,
  /// counted from [startTime]; [loopOnce] stops on the last frame,
  /// otherwise they repeat.
  final int frameCount;
  final double frameDelay;
  final bool loopOnce;
  final bool isAnimation;

  final CommandTimeline opacity, x, y, scale, rotation;

  /// `V` (2 components) and `C` (3 components, 0–255).
  final CommandTimeline vectorScale, colour;
  final List<StoryboardParameterCommand> parameters;

  /// Lifetime: from the earliest command start to the latest command end.
  /// A sprite without commands is never shown.
  final double startTime, endTime;

  StoryboardSprite._(this.layer, this.origin, this.path, this.initialX, this.initialY, this.opacity, this.x, this.y,
      this.scale, this.rotation, this.vectorScale, this.colour, this.parameters, this.startTime, this.endTime,
      {this.frameCount = 1, this.frameDelay = 0, this.loopOnce = false, this.isAnimation = false});

  bool get hasCommands => startTime <= endTime;

  /// The image files this sprite shows: [path] itself, or for an animation
  /// `name0.png`, `name1.png`, ... (the index goes before the extension).
  List<String> get framePaths =>
      isAnimation ? [for (var i = 0; i < frameCount; i++) frameFile(path, i)] : [path];

  /// `sb/anim.png` -> `sb/anim3.png` (osu!: index before the extension).
  static String frameFile(String path, int index) {
    final dot = path.lastIndexOf('.');
    if (dot <= path.lastIndexOf('/')) return '$path$index';
    return '${path.substring(0, dot)}$index${path.substring(dot)}';
  }

  /// Index into [framePaths] at [time].
  int frameAt(double time) {
    final n = isAnimation ? frameCount : 1;
    if (n <= 1 || frameDelay <= 0) return 0;
    final i = ((time - startTime) / frameDelay).floor();
    if (i <= 0) return 0;
    return loopOnce ? (i < n ? i : n - 1) : i % n;
  }

  /// The image shown at [time].
  String imageAt(double time) => isAnimation ? frameFile(path, frameAt(time)) : path;

  bool _param(StoryboardParameter p, double time) {
    for (final c in parameters) {
      if (c.parameter == p && c.activeAt(time)) return true;
    }
    return false;
  }

  /// Writes the state at [time] into [out]; false (and [out] untouched)
  /// outside the lifetime or when fully transparent.
  bool stateInto(double time, SpriteState out) {
    if (time < startTime || time > endTime) return false;
    final a = opacity.isEmpty ? 1.0 : opacity.valueAt(time);
    if (a <= 0) return false;
    final s = scale.isEmpty ? 1.0 : scale.valueAt(time);
    out
      ..opacity = a > 1 ? 1 : a
      ..x = x.isEmpty ? initialX : x.valueAt(time)
      ..y = y.isEmpty ? initialY : y.valueAt(time)
      ..scaleX = vectorScale.isEmpty ? s : s * vectorScale.valueAt(time, 0)
      ..scaleY = vectorScale.isEmpty ? s : s * vectorScale.valueAt(time, 1)
      ..rotation = rotation.isEmpty ? 0 : rotation.valueAt(time);
    if (colour.isEmpty) {
      out
        ..r = 255
        ..g = 255
        ..b = 255;
    } else {
      out
        ..r = colour.valueAt(time, 0)
        ..g = colour.valueAt(time, 1)
        ..b = colour.valueAt(time, 2);
    }
    if (parameters.isEmpty) {
      out
        ..flipH = false
        ..flipV = false
        ..additive = false;
    } else {
      out
        ..flipH = _param(StoryboardParameter.flipH, time)
        ..flipV = _param(StoryboardParameter.flipV, time)
        ..additive = _param(StoryboardParameter.additive, time);
    }
    return true;
  }

  /// The state at [time], or null outside the lifetime or when fully
  /// transparent (allocates; the painter uses [stateInto]).
  SpriteState? stateAt(double time) {
    final s = SpriteState();
    return stateInto(time, s) ? s : null;
  }
}

/// A parsed storyboard: the `.osu`'s own events plus the set's `.osb`.
class Storyboard {
  /// Sprites in draw order (by layer, then declaration order).
  final List<StoryboardSprite> sprites;

  /// Sound events, sorted by time.
  final List<StoryboardSample> samples;

  Storyboard(this.sprites, [this.samples = const []]) {
    _buildIndex();
  }

  static final empty = Storyboard(const []);

  bool get isEmpty => sprites.isEmpty && samples.isEmpty;

  // ---------------------------------------------------------------------------
  // Time index: which sprites can be alive at a moment, without scanning
  // all of them every frame (big storyboards have ~100k sprites).

  /// 1 s buckets, coarser for absurdly long spans (at most 100k buckets).
  double _bucketMs = 1000;

  /// Sprites living longer than this many buckets are checked every frame
  /// instead of being listed in each bucket.
  static const _maxBuckets = 16;

  double _t0 = 0;
  Int32List _offsets = Int32List(1);
  Int32List _bucketed = Int32List(0);
  Int32List _long = Int32List(0);

  void _buildIndex() {
    if (sprites.isEmpty) return;
    var t0 = double.infinity, t1 = double.negativeInfinity;
    for (final s in sprites) {
      if (s.startTime < t0) t0 = s.startTime;
      if (s.endTime > t1) t1 = s.endTime;
    }
    if (!t0.isFinite || !t1.isFinite) return;
    _t0 = t0;
    if ((t1 - t0) / _bucketMs > 100000) _bucketMs = (t1 - t0) / 100000;
    final n = ((t1 - t0) / _bucketMs).floor() + 1;
    final counts = Int32List(n + 1);
    final long = <int>[];
    for (var i = 0; i < sprites.length; i++) {
      final s = sprites[i];
      final b0 = ((s.startTime - t0) / _bucketMs).floor(), b1 = ((s.endTime - t0) / _bucketMs).floor();
      if (b1 - b0 >= _maxBuckets) {
        long.add(i);
        continue;
      }
      for (var b = b0; b <= b1; b++) {
        counts[b + 1]++;
      }
    }
    for (var b = 0; b < n; b++) {
      counts[b + 1] += counts[b];
    }
    final fill = Int32List.fromList(counts);
    final bucketed = Int32List(counts[n]);
    final longSet = long.toSet();
    for (var i = 0; i < sprites.length; i++) {
      if (longSet.contains(i)) continue;
      final s = sprites[i];
      final b0 = ((s.startTime - t0) / _bucketMs).floor(), b1 = ((s.endTime - t0) / _bucketMs).floor();
      for (var b = b0; b <= b1; b++) {
        bucketed[fill[b]++] = i;
      }
    }
    _offsets = counts;
    _bucketed = bucketed;
    _long = Int32List.fromList(long);
  }

  /// Calls [visit] with the index and sprite of every sprite alive at
  /// [time], in draw order.
  void forEachAlive(double time, void Function(int index, StoryboardSprite sprite) visit) {
    final b = ((time - _t0) / _bucketMs).floor();
    var i = 0, iEnd = 0;
    if (b >= 0 && b + 1 < _offsets.length) {
      i = _offsets[b];
      iEnd = _offsets[b + 1];
    }
    final bucketed = _bucketed, long = _long;
    var j = 0;
    while (i < iEnd || j < long.length) {
      final int idx;
      if (j >= long.length || (i < iEnd && bucketed[i] < long[j])) {
        idx = bucketed[i++];
      } else {
        idx = long[j++];
      }
      final s = sprites[idx];
      if (time >= s.startTime && time <= s.endTime) visit(idx, s);
    }
  }

  // ---------------------------------------------------------------------------

  /// Distinct image paths (animation frames included), as written (first
  /// spelling wins).
  Set<String> get imagePaths {
    final seen = <String>{};
    final out = <String>{};
    for (final s in sprites) {
      for (final p in s.framePaths) {
        if (seen.add(p.toLowerCase())) out.add(p);
      }
    }
    return out;
  }

  /// Distinct sample files, as written (first spelling wins).
  Set<String> get samplePaths {
    final seen = <String>{};
    final out = <String>{};
    for (final s in samples) {
      if (seen.add(s.path.toLowerCase())) out.add(s.path);
    }
    return out;
  }

  /// Whether a sprite shows [fileName] (osu! then hides the plain
  /// background, as the storyboard draws it itself).
  bool usesImage(String fileName) {
    final want = normalizePath(fileName).toLowerCase();
    return sprites.any((s) => s.path.toLowerCase() == want);
  }

  static String normalizePath(String p) {
    var s = p.trim();
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) s = s.substring(1, s.length - 1);
    s = s.replaceAll('\\', '/');
    while (s.startsWith('/')) {
      s = s.substring(1);
    }
    return s;
  }

  /// Parses storyboard sources in order: each is `(eventLines, variables)`.
  /// Later sources draw above earlier ones within a layer (osu!lazer reads
  /// the `.osu` first, then the `.osb`).
  static Storyboard parse(List<(Iterable<String>, Map<String, String>)> sources) {
    final byLayer = [for (final _ in StoryboardLayer.values) <StoryboardSprite>[]];
    final samples = <StoryboardSample>[];
    for (final (lines, vars) in sources) {
      final b = _Parser(vars);
      for (final line in lines) {
        b.line(line);
      }
      b.flush();
      for (final s in b.sprites) {
        if (s.hasCommands) byLayer[s.layer.index].add(s);
      }
      samples.addAll(b.samples);
    }
    // Stable sort by time (List.sort isn't stable).
    final indexed = [for (var i = 0; i < samples.length; i++) (i, samples[i])]
      ..sort((a, b) {
        final c = a.$2.time.compareTo(b.$2.time);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    return Storyboard([for (final l in byLayer) ...l], List.unmodifiable([for (final e in indexed) e.$2]));
  }

  /// Splits a `.osb` file into its `[Events]` lines and `[Variables]`.
  static (List<String>, Map<String, String>) splitOsb(String text) {
    final events = <String>[];
    final vars = <String, String>{};
    String? section;
    for (final raw in text.split('\n')) {
      final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
      final t = line.trim();
      if (t.startsWith('[') && t.endsWith(']')) {
        section = t.substring(1, t.length - 1);
        continue;
      }
      if (section == 'Events') {
        events.add(line);
      } else if (section == 'Variables') {
        final eq = t.indexOf('=');
        if (t.startsWith(r'$') && eq > 1) vars[t.substring(0, eq)] = t.substring(eq + 1);
      }
    }
    return (events, vars);
  }

  /// The storyboard part of a `.osu`: its `[Events]` lines and
  /// `[Variables]`.
  static (List<String>, Map<String, String>) beatmapSource(Beatmap b) {
    final events = <String>[];
    final vars = <String, String>{};
    for (final s in b.sections) {
      if (s is! RawSection) continue;
      if (s.name == SectionNames.events) events.addAll(s.lines);
      if (s.name == 'Variables') vars.addAll(parseVariables(s.lines));
    }
    return (events, vars);
  }

  /// `WidescreenStoryboard: 1` — sprites may use the 16:9 area
  /// (x −107..747) instead of being masked to 640x480.
  static bool isWidescreen(Beatmap b) => b.getValue(SectionNames.general, 'WidescreenStoryboard')?.trim() == '1';

  /// `[Variables]` from raw `$name=value` lines.
  static Map<String, String> parseVariables(Iterable<String> lines) {
    final vars = <String, String>{};
    for (final l in lines) {
      final t = l.trim();
      final eq = t.indexOf('=');
      if (t.startsWith(r'$') && eq > 1) vars[t.substring(0, eq)] = t.substring(eq + 1);
    }
    return vars;
  }
}

/// Collects one timeline's commands while parsing (growable float32).
class _TimelineBuilder {
  final int dims;
  Float32List _a = Float32List(0);
  int _n = 0;

  _TimelineBuilder(this.dims);

  int get _stride => 3 + 2 * dims;
  int get count => _n ~/ _stride;
  bool get isEmpty => _n == 0;

  void _ensure(int extra) {
    if (_n + extra <= _a.length) return;
    var cap = _a.isEmpty ? 16 * _stride : _a.length * 2;
    while (cap < _n + extra) {
      cap *= 2;
    }
    _a = Float32List(cap)..setRange(0, _n, _a);
  }

  /// One command: [dims] values from [src] at [fromAt] and at [toAt].
  void add(int easing, double start, double end, List<double> src, int fromAt, int toAt) {
    _ensure(_stride);
    final a = _a;
    var n = _n;
    a[n++] = easing.toDouble();
    a[n++] = start;
    a[n++] = end;
    for (var c = 0; c < dims; c++) {
      a[n++] = src[fromAt + c];
    }
    for (var c = 0; c < dims; c++) {
      a[n++] = src[toAt + c];
    }
    _n = n;
  }

  void addShifted(_TimelineBuilder o, double by) {
    _ensure(o._n);
    final st = _stride;
    for (var i = 0; i < o._n; i += st) {
      _a.setRange(_n, _n + st, o._a, i);
      _a[_n + 1] += by;
      _a[_n + 2] += by;
      _n += st;
    }
  }

  /// Earliest start and latest end (±infinity when empty).
  (double, double) get span {
    var s = double.infinity, e = double.negativeInfinity;
    for (var i = 0; i < _n; i += _stride) {
      if (_a[i + 1] < s) s = _a[i + 1];
      if (_a[i + 2] > e) e = _a[i + 2];
    }
    return (s, e);
  }

  void clear() => _n = 0;

  CommandTimeline build() {
    if (_n == 0) return CommandTimeline._empty[dims];
    final st = _stride, count = this.count;
    final order = List<int>.generate(count, (i) => i);
    var sorted = true;
    for (var i = 1; i < count && sorted; i++) {
      if (_a[i * st + 1] < _a[(i - 1) * st + 1]) sorted = false;
    }
    // List.sort isn't stable; ties keep line order via the index.
    if (!sorted) {
      order.sort((x, y) {
        final c = _a[x * st + 1].compareTo(_a[y * st + 1]);
        return c != 0 ? c : x.compareTo(y);
      });
    }
    final out = Float32List(_n);
    var end = double.negativeInfinity;
    for (var k = 0; k < count; k++) {
      final from = order[k] * st;
      out.setRange(k * st, k * st + st, _a, from);
      if (_a[from + 2] > end) end = _a[from + 2];
    }
    return CommandTimeline._(dims, out, count, out[1], end);
  }
}

/// Commands collected for one sprite (or one loop body).
class _Commands {
  final opacity = _TimelineBuilder(1);
  final xs = _TimelineBuilder(1);
  final ys = _TimelineBuilder(1);
  final scale = _TimelineBuilder(1);
  final rotation = _TimelineBuilder(1);
  final vector = _TimelineBuilder(2);
  final colour = _TimelineBuilder(3);
  final params = <StoryboardParameterCommand>[];

  late final _all = [opacity, xs, ys, scale, rotation, vector, colour];

  bool get isEmpty => _all.every((t) => t.isEmpty) && params.isEmpty;

  /// Earliest start and latest end, ignoring instant `P` commands (they
  /// mean "on for the whole life", not a moment).
  (double, double) get span {
    var start = double.infinity, end = double.negativeInfinity;
    for (final t in _all) {
      final (s, e) = t.span;
      if (s < start) start = s;
      if (e > end) end = e;
    }
    for (final c in params) {
      if (c.start == c.end) continue;
      if (c.start < start) start = c.start;
      if (c.end > end) end = c.end;
    }
    return (start, end);
  }

  void addShifted(_Commands o, double by) {
    for (var i = 0; i < _all.length; i++) {
      _all[i].addShifted(o._all[i], by);
    }
    params.addAll(o.params.map((c) => c.shifted(by)));
  }

  void clear() {
    for (final t in _all) {
      t.clear();
    }
    params.clear();
  }
}

/// Builds sprites line by line; malformed lines are skipped.
class _Parser {
  final List<MapEntry<String, String>> _vars;
  final sprites = <StoryboardSprite>[];
  final samples = <StoryboardSample>[];

  _Parser(Map<String, String> vars)
      // Longest names first so `$ab` isn't replaced as `$a` + "b".
      : _vars = vars.entries.toList()..sort((a, b) => b.key.length.compareTo(a.key.length));

  // Current sprite being filled.
  StoryboardLayer? _layer;
  StoryboardOrigin _origin = StoryboardOrigin.topLeft;
  String _path = '';
  double _x = 0, _y = 0;
  bool _animation = false;
  int _frameCount = 1;
  double _frameDelay = 0;
  bool _loopOnce = false;
  final _cmds = _Commands();

  /// Inside an `L` group: its start time, iteration count and body.
  double? _loopStart;
  int _loopCount = 1;
  final _loopBody = _Commands();

  /// Inside a `T` group (its children are skipped).
  bool _inTrigger = false;

  /// Inside an object we don't draw (Video, Sample, ...): skip commands.
  bool _skipping = false;

  /// Reused per command line.
  final _values = <double>[];

  /// Paths are often repeated thousands of times: share the strings.
  final _paths = <String, String>{};

  void line(String raw) {
    if (raw.isEmpty || raw.startsWith('//')) return;
    var depth = 0;
    while (depth < raw.length && (raw[depth] == ' ' || raw[depth] == '_')) {
      depth++;
    }
    var l = raw.substring(depth).trimRight();
    if (l.isEmpty || l.startsWith('//')) return;
    if (_vars.isNotEmpty && l.contains(r'$')) {
      for (final v in _vars) {
        l = l.replaceAll(v.key, v.value);
      }
    }
    final p = l.split(',');
    if (depth == 0) {
      flush();
      _object(p);
      return;
    }
    if (_skipping || _layer == null) return;
    if (depth >= 2 && (_loopStart != null || _inTrigger)) {
      if (_loopStart != null) _command(p, _loopBody);
      return;
    }
    // A depth-1 line (or a stray deeper one) ends any group.
    _endGroup();
    final type = p[0].trim();
    if (type == 'L') {
      final start = p.length > 1 ? double.tryParse(p[1].trim()) : null;
      if (start == null) {
        _inTrigger = true; // malformed: skip its children
        return;
      }
      _loopStart = start;
      _loopCount = p.length > 2 ? (int.tryParse(p[2].trim()) ?? 1) : 1;
      return;
    }
    if (type == 'T') {
      _inTrigger = true;
      return;
    }
    _command(p, _cmds);
  }

  /// Expands a finished loop: its body repeats [_loopCount] times (at least
  /// once), each iteration as long as the body (earliest child start to
  /// latest child end); child times count from the loop's start time.
  void _endGroup() {
    final start = _loopStart;
    if (start != null && !_loopBody.isEmpty) {
      final (s, e) = _loopBody.span;
      final duration = s.isFinite && e.isFinite ? e - s : 0.0;
      final n = _loopCount < 1 ? 1 : _loopCount;
      for (var i = 0; i < n; i++) {
        _cmds.addShifted(_loopBody, start + i * duration);
      }
    }
    _loopStart = null;
    _loopBody.clear();
    _inTrigger = false;
  }

  /// `Sprite,layer,origin,"file",x,y`,
  /// `Animation,layer,origin,"file",x,y,frameCount,frameDelay[,looptype]`
  /// or `Sample,time,layer,"file"[,volume]`.
  void _object(List<String> p) {
    _skipping = true;
    final kind = p[0].trim();
    if (kind == 'Sample' || kind == '5') {
      _sample(p);
      return;
    }
    final animation = kind == 'Animation' || kind == '6';
    if (!(kind == 'Sprite' || kind == '4' || animation) || p.length < 6) return;
    final layer = _parseLayer(p[1]);
    final x = double.tryParse(p[4].trim()), y = double.tryParse(p[5].trim());
    if (layer == null || x == null || y == null) return;
    _animation = animation;
    _frameCount = 1;
    _frameDelay = 0;
    _loopOnce = false;
    if (animation) {
      if (p.length < 8) return;
      final count = int.tryParse(p[6].trim()), delay = double.tryParse(p[7].trim());
      if (count == null || count < 1 || delay == null) return;
      _frameCount = count;
      _frameDelay = delay;
      final loop = p.length > 8 ? p[8].trim() : '';
      _loopOnce = loop == 'LoopOnce' || loop == '1';
    }
    _layer = layer;
    _origin = _parseOrigin(p[2]);
    final path = Storyboard.normalizePath(p[3]);
    _path = _paths.putIfAbsent(path, () => path);
    _x = x;
    _y = y;
    _skipping = false;
  }

  void _sample(List<String> p) {
    if (p.length < 4) return;
    final time = double.tryParse(p[1].trim());
    final layer = _parseLayer(p[2]);
    if (time == null || layer == null || layer == StoryboardLayer.fail) return;
    final volume = p.length > 4 ? (double.tryParse(p[4].trim()) ?? 100) : 100;
    final path = Storyboard.normalizePath(p[3]);
    if (path.isEmpty) return;
    samples.add(StoryboardSample(time, path, volume.round().clamp(0, 100)));
  }

  void _command(List<String> p, _Commands out) {
    final type = p[0].trim();
    if (p.length < 5) return;
    final easing = int.tryParse(p[1].trim()) ?? 0;
    final start = double.tryParse(p[2].trim());
    if (start == null) return;
    final end = double.tryParse(p[3].trim()) ?? start;
    if (type == 'P') {
      final param = switch (p[4].trim()) {
        'H' => StoryboardParameter.flipH,
        'V' => StoryboardParameter.flipV,
        'A' => StoryboardParameter.additive,
        _ => null,
      };
      if (param != null) out.params.add(StoryboardParameterCommand(param, start, end));
      return;
    }
    final values = _values..clear();
    for (var i = 4; i < p.length; i++) {
      final v = double.tryParse(p[i].trim());
      if (v == null) return;
      values.add(v);
    }
    switch (type) {
      case 'F':
        _chain(out.opacity, easing, start, end, values, 1);
      case 'S':
        _chain(out.scale, easing, start, end, values, 1);
      case 'R':
        _chain(out.rotation, easing, start, end, values, 1);
      case 'MX':
        _chain(out.xs, easing, start, end, values, 1);
      case 'MY':
        _chain(out.ys, easing, start, end, values, 1);
      case 'M':
        _chain(out.xs, easing, start, end, values, 2);
        _chain(out.ys, easing, start, end, values, 2, 1);
      case 'V':
        _chain(out.vector, easing, start, end, values, 2);
      case 'C':
        _chain(out.colour, easing, start, end, values, 3);
    }
  }

  /// Values come in groups of [group]: one group = a constant; more groups =
  /// successive commands of the same duration (osu! shorthand). [offset]
  /// picks the component within a group (M's y).
  static void _chain(_TimelineBuilder t, int easing, double start, double end, List<double> values, int group,
      [int offset = 0]) {
    final groups = values.length ~/ group;
    if (groups == 0) return;
    if (groups == 1) {
      t.add(easing, start, end, values, offset, offset);
      return;
    }
    final dur = end - start;
    for (var i = 0; i + 1 < groups; i++) {
      t.add(easing, start + dur * i, end + dur * i, values, i * group + offset, (i + 1) * group + offset);
    }
  }

  void flush() {
    _endGroup();
    final layer = _layer;
    if (layer != null) {
      final c = _cmds;
      final (start, end) = c.span;
      sprites.add(StoryboardSprite._(
        layer,
        _origin,
        _path,
        _x,
        _y,
        c.opacity.build(),
        c.xs.build(),
        c.ys.build(),
        c.scale.build(),
        c.rotation.build(),
        c.vector.build(),
        c.colour.build(),
        c.params.isEmpty ? const [] : List.unmodifiable(c.params),
        start,
        end,
        frameCount: _frameCount,
        frameDelay: _frameDelay,
        loopOnce: _loopOnce,
        isAnimation: _animation,
      ));
    }
    _layer = null;
    _cmds.clear();
  }

  static StoryboardLayer? _parseLayer(String s) {
    final t = s.trim();
    final n = int.tryParse(t);
    if (n != null) return n >= 0 && n < StoryboardLayer.values.length ? StoryboardLayer.values[n] : null;
    for (final l in StoryboardLayer.values) {
      if (l.name.toLowerCase() == t.toLowerCase()) return l;
    }
    return null;
  }

  static StoryboardOrigin _parseOrigin(String s) {
    final t = s.trim();
    final n = int.tryParse(t);
    if (n != null) return n >= 0 && n < StoryboardOrigin.values.length ? StoryboardOrigin.values[n] : StoryboardOrigin.topLeft;
    for (final o in StoryboardOrigin.values) {
      if (o.name.toLowerCase() == t.toLowerCase()) return o;
    }
    return StoryboardOrigin.topLeft;
  }
}
