import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

void main() {
  group('SkinIni', () {
    test('reads names, colours, fonts and flags', () {
      final ini = SkinIni.parse('''
// a comment
[General]
Name: My Skin // trailing comment
Author:someone
Version: latest
AllowSliderBallTint: 1
HitCircleOverlayAboveNumer: 0
AnimationFramerate: 12

[Colours]
Combo3 : 0,0,255
Combo1: 255,0,0,128
Combo2: 0,255,0
Combo9: 1,2,3
SliderBorder: 300,10,10
SliderTrackOverride: 1,2
SliderBall: 4,5,6

[Fonts]
HitCirclePrefix: fonts\\hit
HitCircleOverlap: 3
''');
      expect(ini.name, 'My Skin');
      expect(ini.author, 'someone');
      expect(ini.version, SkinIni.latestVersion);
      expect(ini.allowSliderBallTint, isTrue);
      expect(ini.hitCircleOverlayAboveNumber, isFalse, reason: 'the old typo still counts');
      expect(ini.animationFramerate, 12);
      // Ordered by number, out-of-range numbers ignored, alpha ignored.
      expect(ini.comboColours, const [RgbColour(255, 0, 0), RgbColour(0, 255, 0), RgbColour(0, 0, 255)]);
      expect(ini.sliderBorder, const RgbColour(255, 10, 10));
      expect(ini.sliderTrackOverride, isNull, reason: 'malformed');
      expect(ini.sliderBall, const RgbColour(4, 5, 6));
      expect(ini.hitCirclePrefix, 'fonts/hit');
      expect(ini.hitCircleOverlap, 3);
    });

    test('defaults', () {
      final ini = SkinIni.parse('[General]\r\nName:\r\n');
      expect(ini.name, isNull);
      expect(ini.version, 1.0, reason: 'a skin.ini without Version is 1.0');
      expect(ini.comboColours, isEmpty);
      expect(ini.hitCirclePrefix, 'default');
      expect(ini.hitCircleOverlap, -2);
      expect(ini.hitCircleOverlayAboveNumber, isTrue);
      expect(SkinIni.none.version, SkinIni.latestVersion, reason: 'no skin.ini at all');
    });
  });

  group('SkinPackage', () {
    List<int> zip(Map<String, String> files) {
      final a = Archive();
      for (final e in files.entries) {
        a.add(ArchiveFile.bytes(e.key, utf8.encode(e.value)));
      }
      return ZipEncoder().encodeBytes(a);
    }

    test('unwraps a skin zipped inside its folder', () {
      final pkg = SkinPackage.decode(zip({
        'Cool Skin/skin.ini': '﻿[General]\nName: Cool',
        'Cool Skin/hitcircle.png': 'x',
        'Cool Skin/numbers/default-1.png': 'x',
      }));
      expect(pkg.ini.name, 'Cool', reason: 'BOM dropped');
      expect([for (final e in pkg.entries) e.path]..sort(), ['hitcircle.png', 'numbers/default-1.png', 'skin.ini']);
    });

    test('keeps folders when files sit at the top', () {
      final pkg = SkinPackage.decode(zip({'skin.ini': '', 'a/hitcircle.png': 'x'}));
      expect([for (final e in pkg.entries) e.path]..sort(), ['a/hitcircle.png', 'skin.ini']);
    });

    test('images only (no skin.ini) is still a skin', () {
      final pkg = SkinPackage.decode(zip({'hitcircle.png': 'x'}));
      expect(pkg.ini.name, isNull);
    });

    test('rejects beatmap sets, unrelated archives and non-zips', () {
      expect(() => SkinPackage.decode(zip({'a.osu': 'osu file format v14', 'skin.ini': ''})),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('beatmap'))));
      expect(() => SkinPackage.decode(zip({'readme.txt': 'hi'})), throwsFormatException);
      expect(() => SkinPackage.decode(utf8.encode('not a zip')), throwsFormatException);
    });

    test('looksLikeSkin', () {
      expect(SkinPackage.looksLikeSkin(OszCodec.decode(zip({'S/skin.ini': ''}))), isTrue);
      expect(SkinPackage.looksLikeSkin(OszCodec.decode(zip({'a.osu': '', 'skin.ini': ''}))), isFalse);
      expect(SkinPackage.looksLikeSkin(OszCodec.decode(zip({'bg.png': ''}))), isFalse);
    });
  });
}
