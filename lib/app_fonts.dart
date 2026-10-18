import 'package:flutter/painting.dart';

/// UI font (Exo 2, osu!'s former UI font; variable font bundled in assets/fonts/, SIL OFL). Set as the theme font in main.dart;
/// canvas painters that build their own TextStyle must pass it explicitly.
const kUiFont = 'Exo 2';

/// Monospace font for timestamps and numeric readouts (bundled, SIL OFL).
const kMonoFont = 'JetBrains Mono';

/// Fixed-width numbers: times, values next to sliders, BPM labels.
const monoNumbers = TextStyle(fontFamily: kMonoFont);
