# Third-party notices

osuEdit is licensed under the Apache License 2.0 (see `LICENSE`). It includes
or is derived from the following third-party code, which keeps its own license.

## osu! (osu!lazer)

<https://github.com/ppy/osu> — MIT License

Parts of `lib/core/` are ports of, or closely follow, osu!lazer code:

- `lib/core/difficulty/star_rating.dart` — the osu! standard difficulty
  calculator (skills, evaluators and star rating formula).
- `lib/core/geometry/lazer_path.dart`, `lib/core/geometry/slider_path.dart` —
  slider path behaviour (lazer path format, path length and positions).
- `lib/core/rules/object_visuals.dart`, `lib/editor/render/playfield_painter.dart` —
  object fade/hit animation timings of the classic (legacy) skin. No skin
  assets are included; the visuals are drawn in code.
- Various editor behaviours referenced in comments (e.g. merge, polygon,
  follow points).

```
Copyright (c) 2025 ppy Pty Ltd <contact@ppy.sh>.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

## osu-framework

<https://github.com/ppy/osu-framework> — MIT License

- `lib/core/geometry/path_approximator.dart` — curve approximation
  (bezier, catmull, circular arc, B-spline) following osu-framework's
  `PathApproximator`.

```
Copyright (c) 2024 ppy Pty Ltd <contact@ppy.sh>.

(Same MIT permission notice as above.)
```

## flutter_soloud

<https://github.com/alnitak/flutter_soloud> — MIT License

Vendored in `packages/flutter_soloud/` with a resampler fix
(`packages/flutter_soloud/OSUEDIT_PATCH.md`). Its license and the licenses of
the libraries it bundles (SoLoud, miniaudio, dr_libs, Xiph libraries, …) are
kept in that directory (`packages/flutter_soloud/LICENSE` and the source tree).

## Dart / Flutter packages

Other dependencies are fetched from pub.dev under their own licenses
(see `pubspec.yaml` and `pubspec.lock`).

## Trademark

"osu!" is a trademark of ppy Pty Ltd. osuEdit is an unofficial, fan-made
editor and is not affiliated with or endorsed by ppy.
