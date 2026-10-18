import 'dart:ui' as ui;

import 'beatmap_library.dart';

/// Decodes the set's background image [fileName], downscaled to at most
/// [maxWidth] px wide (a phone never needs a 4K background, and the decoded
/// bitmap is 4 bytes per pixel). Null if the file is missing or not an
/// image.
Future<ui.Image?> loadBackgroundImage(String setPath, String fileName, {int maxWidth = 1600}) async {
  final file = BeatmapLibrary.resolveFile(setPath, fileName);
  if (file == null) return null;
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(await file.readAsBytes());
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    codec = await descriptor.instantiateCodec(
      // Only the width is given, so the aspect ratio is kept.
      targetWidth: descriptor.width > maxWidth ? maxWidth : null,
    );
    return (await codec.getNextFrame()).image;
  } catch (_) {
    return null;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}
