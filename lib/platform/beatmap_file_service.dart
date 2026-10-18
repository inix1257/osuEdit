import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import '../core/core.dart';

/// Where an open beatmap came from, so "Save" knows where to go.
class BeatmapDocument {
  final String fileName;

  /// Local path we can write back to: a library difficulty, or a file
  /// opened directly on desktop. Null for assets / new maps / mobile picker
  /// copies.
  final String? path;

  /// The set folder when the difficulty lives in the library; other files
  /// the map references (audio, background, samples) are resolved here.
  final String? setPath;

  /// Byte encoding of the source file, so saving reproduces it.
  final OsuTextEncoding encoding;

  const BeatmapDocument({
    required this.fileName,
    this.path,
    this.setPath,
    this.encoding = OsuTextEncoding.utf8,
  });

  bool get isInLibrary => setPath != null;
}

class LoadedBeatmapFile {
  final BeatmapDocument document;
  final String text;
  const LoadedBeatmapFile(this.document, this.text);
}

/// A picked `.osz`.
class PickedArchive {
  final String name;
  final Uint8List bytes;
  const PickedArchive(this.name, this.bytes);
}

/// A picked `.osu`: [loaded] to open it as is, [bytes] / [folder] to import it.
class PickedOsu {
  final LoadedBeatmapFile loaded;
  final Uint8List bytes;

  /// Where it was picked from, when known.
  final String? folder;
  const PickedOsu(this.loaded, this.bytes, this.folder);
}

/// A picked file to copy into a set (audio, background). [name] includes
/// the extension.
class PickedFile {
  final String name;
  final Uint8List bytes;
  const PickedFile(this.name, this.bytes);
}

/// File access boundary. Everything platform-specific about reading and
/// writing files outside the library (pickers, save dialogs) lives here.
class BeatmapFileService {
  const BeatmapFileService();

  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  /// Mobile pickers don't know the .osu / .osz MIME types; filter after
  /// picking instead.
  Future<PlatformFile?> _pick(String ext) => _pickAny([ext]);

  Future<PlatformFile?> _pickAny(List<String> exts) async {
    final file = await FilePicker.pickFile(
      type: _isMobile ? FileType.any : FileType.custom,
      allowedExtensions: _isMobile ? null : exts,
    );
    if (file == null) return null;
    if (!exts.contains(file.extension?.toLowerCase())) {
      throw FormatException('Please pick a ${exts.map((e) => '.$e').join(' / ')} file');
    }
    return file;
  }

  static const audioExtensions = ['mp3', 'ogg', 'wav'];
  static const imageExtensions = ['jpg', 'jpeg', 'png'];

  Future<PickedFile?> pickAudioFile() => _pickFile(audioExtensions);
  Future<PickedFile?> pickImageFile() => _pickFile(imageExtensions);

  Future<PickedFile?> _pickFile(List<String> exts) async {
    final file = await _pickAny(exts);
    if (file == null) return null;
    return PickedFile(file.name, await file.readAsBytes());
  }

  Future<LoadedBeatmapFile?> pickOsuFile() async => (await pickOsu())?.loaded;

  /// A `.osu` file: opened, plus its bytes and folder (for importing it
  /// with the files beside it).
  Future<PickedOsu?> pickOsu() async {
    final file = await _pick('osu');
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    final (text, encoding) = OsuTextCodec.decode(bytes);
    final path = file.path;
    return PickedOsu(
      LoadedBeatmapFile(
        BeatmapDocument(
          fileName: file.name,
          // Mobile pickers hand out temporary copies; writing there would
          // silently lose the save, so treat them as path-less.
          path: _isMobile ? null : path,
          encoding: encoding,
        ),
        text,
      ),
      bytes,
      // Mobile: a cache folder without the map's other files.
      path == null ? null : File(path).parent.path,
    );
  }

  /// An `.osk` skin archive.
  Future<PickedArchive?> pickOskFile() async {
    final file = await _pick('osk');
    if (file == null) return null;
    final name = file.name;
    final dot = name.lastIndexOf('.');
    return PickedArchive(dot > 0 ? name.substring(0, dot) : name, await file.readAsBytes());
  }

  Future<PickedArchive?> pickOszFile() async {
    final file = await _pick('osz');
    if (file == null) return null;
    final name = file.name;
    final dot = name.lastIndexOf('.');
    return PickedArchive(dot > 0 ? name.substring(0, dot) : name, await file.readAsBytes());
  }

  /// Opens a difficulty from the library.
  Future<LoadedBeatmapFile> openLibraryFile(String path, String setPath) async {
    final (text, encoding) = OsuTextCodec.decode(await File(path).readAsBytes());
    return LoadedBeatmapFile(
      BeatmapDocument(
        fileName: path.substring(path.lastIndexOf(Platform.pathSeparator) + 1),
        path: path,
        setPath: setPath,
        encoding: encoding,
      ),
      text,
    );
  }

  Future<LoadedBeatmapFile> loadAsset(String assetPath) async {
    final text = await rootBundle.loadString(assetPath);
    return LoadedBeatmapFile(
      BeatmapDocument(fileName: assetPath.split('/').last),
      text,
    );
  }

  /// Saves [text]. Returns the document it was saved as, or null if the
  /// user cancelled.
  Future<BeatmapDocument?> save(BeatmapDocument doc, String text) async {
    final bytes = OsuTextCodec.encode(text, doc.encoding);
    final path = doc.path;
    if (path != null) {
      await writeFileAtomic(File(path), bytes);
      return doc;
    }
    final uri = await FilePicker.saveFile(
      fileName: doc.fileName,
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: const ['osu'],
    );
    // The plugin writes the bytes itself on every platform.
    if (uri == null) return null;
    return BeatmapDocument(
      fileName: uri.pathSegments.isNotEmpty ? uri.pathSegments.last : doc.fileName,
      path: !_isMobile && uri.scheme == 'file' ? uri.toFilePath() : null,
      encoding: doc.encoding,
    );
  }

  /// Lets the user choose where to put an exported `.osz` (SAF on Android,
  /// document picker on iOS). Returns false if cancelled.
  Future<bool> saveOsz(String fileName, Uint8List bytes) async {
    final uri = await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: const ['osz'],
    );
    return uri != null;
  }

  /// Writes via a temp file + rename so a crash mid-write can't truncate the
  /// user's map.
  static Future<void> writeFileAtomic(File target, List<int> bytes) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
  }
}
