import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

void main() {
  const withColours = 'osu file format v14\r\n'
      '\r\n'
      '[General]\r\n'
      'Mode: 0\r\n'
      '\r\n'
      '[TimingPoints]\r\n'
      '0,500,4,2,0,60,1,0\r\n'
      '\r\n'
      '\r\n'
      '[Colours]\r\n'
      'Combo1 : 255,0,0\r\n'
      'Combo2 : 0,255,0\r\n'
      'SliderBorder : 10,20,30\r\n'
      '\r\n'
      '[HitObjects]\r\n'
      '256,192,1000,1,0,0:0:0:0:\r\n';

  const without = 'osu file format v14\r\n'
      '\r\n'
      '[General]\r\n'
      'Mode: 0\r\n'
      '\r\n'
      '[HitObjects]\r\n'
      '256,192,1000,1,0,0:0:0:0:\r\n';

  test('reads combo colours in file order', () {
    final b = OsuParser.parse(withColours);
    expect(ComboColours.of(b), const [RgbColour(255, 0, 0), RgbColour(0, 255, 0)]);
    expect(ComboColours.of(OsuParser.parse(without)), isEmpty);
  });

  test('hex', () {
    expect(const RgbColour(255, 192, 0).hex, '#FFC000');
    expect(RgbColour.parseHex('ffc000'), const RgbColour(255, 192, 0));
    expect(RgbColour.parseHex('#12345'), isNull);
  });

  test('replacing keeps other lines and their place; revert is byte-exact', () {
    final b = OsuParser.parse(withColours);
    final cmd = SetComboColoursCommand(const [RgbColour(1, 2, 3), RgbColour(4, 5, 6), RgbColour(7, 8, 9)]);
    cmd.apply(b);
    final out = OsuWriter.write(b);
    expect(out, contains('[Colours]\r\nCombo1 : 1,2,3\r\nCombo2 : 4,5,6\r\nCombo3 : 7,8,9\r\nSliderBorder : 10,20,30\r\n'));
    expect(ComboColours.of(b), hasLength(3));
    cmd.revert(b);
    expect(OsuWriter.write(b), withColours);
  });

  test('creates [Colours] before [HitObjects] when missing; revert removes it', () {
    final b = OsuParser.parse(without);
    final cmd = SetComboColoursCommand(const [RgbColour(255, 255, 255)]);
    cmd.apply(b);
    expect(OsuWriter.write(b), contains('[Colours]\r\nCombo1 : 255,255,255\r\n'));
    expect(OsuWriter.write(b).indexOf('[Colours]'), lessThan(OsuWriter.write(b).indexOf('[HitObjects]')));
    cmd.revert(b);
    expect(OsuWriter.write(b), without);
  });

  test('an empty list removes the combo colours (defaults apply)', () {
    final b = OsuParser.parse(withColours);
    SetComboColoursCommand(const []).apply(b);
    expect(ComboColours.of(b), isEmpty);
    expect(OsuWriter.write(b), contains('SliderBorder : 10,20,30'));
  });

  test('slider track / border: read, set in place, add after combos, remove; revert exact', () {
    final b = OsuParser.parse(withColours);
    expect(ComboColours.colourOf(b, ComboColours.sliderBorder), const RgbColour(10, 20, 30));
    expect(ComboColours.colourOf(b, ComboColours.sliderTrack), isNull);

    final border = SetColourKeyCommand(ComboColours.sliderBorder, const RgbColour(1, 1, 1))..apply(b);
    expect(OsuWriter.write(b), contains('Combo2 : 0,255,0\r\nSliderBorder : 1,1,1\r\n'));
    final track = SetColourKeyCommand(ComboColours.sliderTrack, const RgbColour(9, 8, 7))..apply(b);
    expect(OsuWriter.write(b), contains('Combo2 : 0,255,0\r\nSliderTrackOverride : 9,8,7\r\nSliderBorder : 1,1,1\r\n'));
    final remove = SetColourKeyCommand(ComboColours.sliderBorder, null)..apply(b);
    expect(ComboColours.colourOf(b, ComboColours.sliderBorder), isNull);
    remove.revert(b);
    track.revert(b);
    border.revert(b);
    expect(OsuWriter.write(b), withColours);

    final none = OsuParser.parse(without);
    final add = SetColourKeyCommand(ComboColours.sliderTrack, const RgbColour(5, 5, 5))..apply(none);
    expect(OsuWriter.write(none), contains('[Colours]\r\nSliderTrackOverride : 5,5,5\r\n'));
    add.revert(none);
    expect(OsuWriter.write(none), without);
  });

  test('at most eight', () {
    final b = OsuParser.parse(without);
    SetComboColoursCommand([for (var i = 0; i < 10; i++) RgbColour(i, i, i)]).apply(b);
    expect(ComboColours.of(b), hasLength(8));
  });
}
