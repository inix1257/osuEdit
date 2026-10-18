"""Builds the osuEdit device test set. Difficulties:

* [Snaps] (P0-3 sync test): a ~29 s map at 180 BPM whose sections
exercise every editor snap (1/1, 1/2, 1/4, 1/3, 1/6, 1/8, switching between
1/4 and 1/3), sliders with many repeats under an SV change, hitsounds
(whistle / clap / finish, a drum-sampleset section), kiai and a spinner;
plus a click track: an accented click on every beat and a quiet tick on the
grid of whatever snap the current section uses, so hitsounds and objects can
be checked against the music by ear.
* [Shapes] (P1-1 slider editing): every curve type (linear, perfect circle,
  bezier with red anchors, catmull), repeats, sliders under SV 0.5 / 2.0, a
  spinner, and an empty stretch at the end for drawing new objects.

Both use the same audio and background image (bg.jpg).

Usage (from the repo root; ffmpeg must be on PATH for the MP3 / JPG):
    python tool/make_click_test_osz.py [out_dir]
    python tool/make_click_test_osz.py --long [out_dir]
    python tool/make_click_test_osz.py --storyboard [out_dir]
    python tool/make_click_test_osz.py --lazer [out_dir]
    python tool/make_click_test_osz.py --skin [out_dir]

--skin builds "osuEdit test skin.osk" (no fixtures, no ffmpeg), zipped
inside an "osuEdit Test Skin/" folder: a tinted hitcircle with a grey band
under a black-ring overlay, yellow seven-segment digits from a sub-folder
prefix (numbers\num, overlap 6), a dashed approach circle, a 2-frame slider
ball with a direction triangle (tinted), an orange dashed follow circle, a
magenta reverse arrow, cyan diamond ticks, green 2-frame follow points, an
old-style spinner, purple / teal / orange / lime combo colours, a red slider
border and a short high normal-hitnormal.wav.

--lazer builds "osuEdit lazer test.osz" (no fixtures, reuses audio.mp3 and
bg.jpg): one [Lazer] difficulty in lazer's own format (`osu file format
v128`) with sliders only lazer can read (linear + half circle, bezier +
catmull, a degree-4 B-spline, two arcs in one slider) and two that stable
can express (a plain bezier, bezier segments with lazer's explicit `B|`
anchor), then empty bars for drawing.

--storyboard instead builds "osuEdit storyboard test.osz" (no fixtures,
reuses out_dir/audio.mp3 and bg.jpg from a normal run): one [Storyboard]
difficulty with circles at the playfield centre and corners, a .osb with the
background as a sprite (replaces bg.jpg), a box moving/rotating/squashing,
TopLeft/TopRight/BottomLeft/BottomRight markers on the 640x480 corners and
markers at the widescreen edges (x -107 / 747), a crosshair around the centre
circles (storyboard (320,248) = osu!px (256,192)), a Fail-layer red X that must
NOT show, a progress bar defined in the .osu's own [Events], and two 4-frame
animations from 1 s (500 ms per frame: red, green, blue, white with 1..4
bars), LoopForever at (560,120) and LoopOnce at (560,360) (white from 2.5 s).
Also C / P / L / Sample: a box at (80,120) tinted red -> green (4 s) -> blue
(7 s); a blue square at (200,120) under an additive red one (overlap turns
magenta); the green 2-bar frame at (80,360) flipped H during 2-4 s (bars on
the right) and V during 4-6 s; the white frame at (200,360) blinking every
0.5 s from a loop; a beep (sb/beep.wav) at 2, 4 and 6 s (the Fail-layer one
at 3 s must stay silent).

--long instead builds "osuEdit long test.osz" (no fixtures): a 6-minute
180 BPM click track (long_audio.mp3, made by ffmpeg) and one dense [Long]
difficulty (~2000 objects: 1/2 streams, sliders with ticks and repeats,
stacks, a kiai every 32 bars) for long-song memory and drawing / profiling
checks on devices.

Writes the fixtures test/fixtures/sync_test_v14.osu and
test/fixtures/slider_shapes_v14.osu (CRLF; checked by
test/core/sync_test_map_test.dart and test/core/slider_shapes_map_test.dart)
and, in out_dir (default tool/test_set, kept between runs so the same files
are reused for device tests), audio.mp3, bg.jpg and "osuEdit test set.osz".
"""
import io
import math
import os
import struct
import subprocess
import sys
import wave
import zipfile
import zlib
from fractions import Fraction as F

BPM = 180
OFFSET = 1000.0
BEAT = 60000.0 / BPM
SLIDER_MULTIPLIER = 1.4
SR = 44100
DURATION_S = 30.0

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURE = os.path.join(REPO, 'test', 'fixtures', 'sync_test_v14.osu')
SHAPES_FIXTURE = os.path.join(REPO, 'test', 'fixtures', 'slider_shapes_v14.osu')

# Hit sound flags / sample sets.
WHISTLE, FINISH, CLAP = 2, 4, 8
SOFT, DRUM = 2, 3


def ms(beat):
    return OFFSET + float(beat) * BEAT


def t_int(beat):
    return int(math.floor(ms(beat) + 0.5))


class Map:
    def __init__(self):
        self.objects = []   # (beat, line-without-time-builder)
        self.greens = []    # (beat, sv, sampleset, volume, kiai)
        self.grids = []     # (start_beat, end_beat, divisor) for audio ticks
        self.bookmarks = []
        self.nc_next = True
        self.sv = 1.0

    def section(self, beat, divisor_grid=None, end=None):
        self.bookmarks.append(beat)
        self.nc_next = True
        if divisor_grid:
            self.grids.append((F(beat), F(end), divisor_grid))

    def _type(self, base):
        t = base | (4 if self.nc_next else 0)
        self.nc_next = False
        return t

    def circle(self, beat, x, y, hs=0):
        self.objects.append((F(beat), lambda t, x=x, y=y, ty=self._type(1), hs=hs: f'{x},{y},{t},{ty},{hs},0:0:0:0:'))

    def slider(self, beat, x, y, angle_deg, span_beats, slides, sv, hs=0, edges=None):
        length = SLIDER_MULTIPLIER * 100 * sv * float(span_beats)
        ex = round(x + math.cos(math.radians(angle_deg)) * length)
        ey = round(y + math.sin(math.radians(angle_deg)) * length)
        assert 0 <= ex <= 512 and 0 <= ey <= 384, (beat, ex, ey)
        edge_sounds = '|'.join(str(e) for e in (edges or [0] * (slides + 1)))
        edge_sets = '|'.join(['0:0'] * (slides + 1))
        ty = self._type(2)
        self.objects.append((F(beat), lambda t, ty=ty: (
            f'{x},{y},{t},{ty},{hs},L|{ex}:{ey},{slides},{length:g},{edge_sounds},{edge_sets},0:0:0:0:')))
        return F(beat) + F(span_beats) * slides

    def curve(self, beat, x, y, curve, slides, span_beats, sv=1.0):
        """Slider with an explicit curve (`B|x:y|...`); its length is a whole
        number of beat snaps (the path must be at least that long)."""
        length = SLIDER_MULTIPLIER * 100 * sv * float(span_beats)
        edges = '|'.join(['0'] * (slides + 1))
        sets = '|'.join(['0:0'] * (slides + 1))
        ty = self._type(2)
        self.objects.append((F(beat), lambda t, ty=ty: (
            f'{x},{y},{t},{ty},0,{curve},{slides},{length:g},{edges},{sets},0:0:0:0:')))
        return F(beat) + F(span_beats) * slides

    def spinner(self, beat, end_beat, hs=0):
        ty = self._type(8)
        self.objects.append((F(beat), lambda t, ty=ty, e=t_int(end_beat), hs=hs: f'256,192,{t},{ty},{hs},{e},0:0:0:0:'))

    def green(self, beat, sv=1.0, sampleset=SOFT, volume=60, kiai=False):
        self.greens.append((F(beat), sv, sampleset, volume, kiai))


def ring(n, cx=256, cy=192, r=120, start=-90):
    return [(round(cx + r * math.cos(math.radians(start + 360 * i / n))),
             round(cy + r * math.sin(math.radians(start + 360 * i / n)))) for i in range(n)]


def line(n, x0, y0, x1, y1):
    return [(round(x0 + (x1 - x0) * i / max(1, n - 1)), round(y0 + (y1 - y0) * i / max(1, n - 1))) for i in range(n)]


def build():
    m = Map()

    # M0–M1 (beats 0–7): 1/1, claps on 2 and 4 in the second measure.
    m.section(0, 1, 8)
    for i, (x, y) in enumerate(ring(8)):
        m.circle(i, x, y, CLAP if i >= 4 and i % 2 == 1 else 0)

    # M2–M3 (8–15): 1/2 jumps, whistle on the off-beats.
    m.section(8, 2, 16)
    pts = [(96, 96), (416, 96), (416, 288), (96, 288)]
    for i in range(16):
        x, y = pts[i % 4]
        m.circle(8 + F(i, 2), x, y, WHISTLE if i % 2 == 1 else 0)

    # M4–M5 (16–23): 1/4 bursts, then a 16-note stream.
    m.section(16, 4, 24)
    for b, (x0, y0, x1, y1) in [(16, (100, 100, 190, 100)), (18, (412, 100, 322, 100))]:
        for i, (x, y) in enumerate(line(5, x0, y0, x1, y1)):
            m.circle(b + F(i, 4), x, y)
        m.circle(b + F(3, 2), 256, 300)
    for i, (x, y) in enumerate(ring(16, r=110)):
        m.circle(20 + F(i, 4), x, y, FINISH if i == 0 else 0)

    # M6–M7 (24–31): many-repeat sliders under SV 2.0.
    m.section(24, 4, 28)
    m.green(24, sv=2.0)
    end = m.slider(24, 160, 192, 0, F(1, 4), 8, 2.0, edges=[CLAP] + [0] * 7 + [WHISTLE])  # 24 → 26
    assert end == 26
    m.circle(F(53, 2), 352, 96)
    m.circle(27, 352, 288)
    m.section(28, 2, 32)
    end = m.slider(28, 120, 120, 30, F(1, 2), 6, 2.0, edges=[FINISH] + [WHISTLE] * 6)  # 28 → 31
    assert end == 31
    m.circle(F(63, 2), 400, 300)
    m.green(32, sv=1.0)

    # M8–M9 (32–39): 1/3 triplets, a 2/3 slider, a triplet stream.
    m.section(32, 3, 40)
    for i, (x, y) in enumerate(line(4, 100, 280, 220, 280)):
        m.circle(32 + F(i, 3), x, y)
    m.circle(34, 400, 120)
    m.slider(35, 300, 200, 180, F(2, 3), 1, 1.0)  # ends at 35 2/3
    m.circle(36, 120, 120, CLAP)
    for i, (x, y) in enumerate(ring(10, r=100, start=180)[1:]):
        m.circle(36 + F(i + 1, 3), x, y)

    # M10 (40–43): 1/6 bursts.
    m.section(40, 6, 44)
    for b, x0 in [(40, 100), (42, 300)]:
        for i, (x, y) in enumerate(line(5, x0, 192, x0 + 100, 192)):
            m.circle(b + F(i, 6), x, y)
        m.circle(b + 1, x0 + 50, 320)

    # M11 (44–47): 1/8 burst, then 1/1.
    m.section(44, 8, 48)
    for i, (x, y) in enumerate(line(5, 150, 100, 250, 100)):
        m.circle(44 + F(i, 8), x, y)
    for i, (x, y) in enumerate([(380, 192), (256, 300), (130, 192)]):
        m.circle(45 + i, x, y, WHISTLE)

    # M12–M15 (48–63): kiai; sliders + circles with hitsounds; drum set from 56.
    m.section(48, 2, 56)
    m.green(48, kiai=True, volume=70)
    for k, b in enumerate(range(48, 56, 2)):
        x = 100 + 100 * k
        m.slider(b, x, 100, 90, 1, 1, 1.0, edges=[FINISH if b % 4 == 0 else CLAP, WHISTLE])
    m.section(56, 4, 64)
    m.green(56, sampleset=DRUM, volume=70, kiai=True)
    for b in range(56, 64, 2):
        m.circle(b, 120 if b % 4 == 0 else 392, 280, FINISH if b % 4 == 0 else 0)
        for i in range(1, 4):
            m.circle(b + 1 + F(i - 1, 4), 160 + 64 * i, 120, CLAP if i == 3 else 0)
    m.green(64, volume=60)

    # M16–M17 (64–71): snap switching, alternating 1/4 and 1/3 every beat.
    m.section(64)
    for k, b in enumerate(range(64, 72)):
        d = 4 if k % 2 == 0 else 3
        m.grids.append((F(b), F(b + 1), d))
        xs = line(d, 100 + 40 * (k % 4), 140 + 40 * (k // 4), 240 + 40 * (k % 4), 140 + 40 * (k // 4))
        for i, (x, y) in enumerate(xs):
            m.circle(b + F(i, d), x, y)

    # M18–M20 (72–83): spinner, then 1/1 to the end with a finish.
    m.section(72, 1, 84)
    m.spinner(72, 76, FINISH)
    for i, (x, y) in enumerate(ring(7, r=90)):
        m.circle(77 + i, x, y, FINISH if i == 6 else 0)
    return m


def build_shapes():
    m = Map()
    # Beats 0–15: one of each curve type, each 1 beat long, 2 beats apart.
    m.section(0)
    m.curve(0, 64, 96, 'L|224:96', 1, 1)                                   # linear
    m.curve(2, 256, 64, 'P|352:128|256:192', 1, 1)                          # perfect circle
    m.curve(4, 64, 192, 'B|128:128|192:256|192:256|256:192|320:256', 1, F(3, 2))  # bezier + red anchor
    m.curve(6, 384, 192, 'C|448:224|416:288|480:320', 1, 1)                 # catmull
    m.curve(8, 96, 320, 'B|160:256|224:352|288:288', 1, 1)                  # plain bezier
    m.curve(10, 320, 320, 'L|448:320', 3, F(1, 2))                          # 2 repeats
    m.curve(12, 128, 64, 'B|256:32|384:96|384:96|448:160', 1, F(3, 2))      # trimmed path
    # Beats 16–23: the same linear slider shape under SV 0.5 and 2.0.
    m.section(16)
    m.green(16, sv=0.5)
    m.curve(16, 96, 192, 'L|416:192', 1, 2, sv=0.5)
    m.green(20, sv=2.0)
    m.curve(20, 96, 288, 'L|416:288', 1, 1, sv=2.0)
    m.green(22, sv=1.0)
    # Beats 24–31: spinner. Beats 32–63: empty, for drawing new objects.
    m.section(24)
    m.spinner(24, 30)
    m.section(32)
    return m


def osu_text(m, version='Snaps', tags='test sync snap', preview=9000):
    objs = sorted(m.objects, key=lambda o: o[0])
    lines = [
        'osu file format v14', '',
        '[General]', 'AudioFilename: audio.mp3', 'AudioLeadIn: 0', f'PreviewTime: {preview}', 'Countdown: 0',
        'SampleSet: Soft', 'StackLeniency: 0.7', 'Mode: 0', 'LetterboxInBreaks: 0', 'WidescreenStoryboard: 1', '',
        '[Editor]', 'Bookmarks: ' + ','.join(str(t_int(b)) for b in m.bookmarks),
        'DistanceSpacing: 1', 'BeatDivisor: 4', 'GridSize: 32', 'TimelineZoom: 1', '',
        '[Metadata]', 'Title:Sync Test', 'TitleUnicode:Sync Test', 'Artist:osuEdit', 'ArtistUnicode:osuEdit',
        'Creator:osuEdit', f'Version:{version}', 'Source:', f'Tags:{tags}', 'BeatmapID:0', 'BeatmapSetID:-1', '',
        '[Difficulty]', 'HPDrainRate:5', 'CircleSize:4', 'OverallDifficulty:8', 'ApproachRate:9',
        f'SliderMultiplier:{SLIDER_MULTIPLIER}', 'SliderTickRate:1', '',
        '[Events]', '//Background and Video events', '0,0,"bg.jpg",0,0', '//Break Periods', '//Storyboard Layer 0 (Background)',
        '//Storyboard Layer 1 (Fail)', '//Storyboard Layer 2 (Pass)', '//Storyboard Layer 3 (Foreground)',
        '//Storyboard Sound Samples', '',
        '[TimingPoints]', f'{OFFSET:g},{BEAT!r},4,{SOFT},0,60,1,0',
    ]
    for beat, sv, ss, vol, kiai in m.greens:
        lines.append(f'{t_int(beat)},{-100 / sv:g},4,{ss},0,{vol},0,{1 if kiai else 0}')
    lines += ['', '', '[HitObjects]']
    lines += [build_line(t_int(b)) for b, build_line in objs]
    return '\r\n'.join(lines) + '\r\n'


def click_track(m, path):
    n = int(SR * DURATION_S)
    buf = [0.0] * n

    def blip(at_ms, freq, amp, decay):
        s = int(at_ms / 1000 * SR)
        for i in range(int(0.03 * SR)):
            if 0 <= s + i < n:
                buf[s + i] += amp * math.sin(2 * math.pi * freq * i / SR) * math.exp(-i / SR * decay)

    total_beats = int((DURATION_S * 1000 - OFFSET) / BEAT)
    for k in range(total_beats):
        blip(ms(k), 1500.0 if k % 4 == 0 else 1000.0, 0.6, 120)
    for start, end, d in m.grids:
        tick = start
        while tick < end:
            if tick.denominator != 1:  # beats already have a click
                blip(ms(tick), 2600.0, 0.25, 260)
            tick += F(1, d)
    with wave.open(path, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b''.join(struct.pack('<hh', *(2 * [int(max(-1, min(1, v)) * 32767)])) for v in buf))


LONG_S = 360


def build_long():
    """Dense 6-minute map: per 4-bar phrase a 1/2 stream on a ring (every
    4th note stacked on the previous one), two sliders (one repeating) and
    a pause; a kiai section every 32 bars."""
    m = Map()
    beats = int((LONG_S * 1000 - OFFSET - 2000) / BEAT)
    phrase = 16
    for p0 in range(0, beats - phrase, phrase):
        m.nc_next = True
        if p0 % 128 == 0:
            m.bookmarks.append(p0)
            m.green(p0, kiai=(p0 // 128) % 2 == 1)
        pts = ring(8, r=90 + (p0 // phrase) % 4 * 20, start=(p0 * 7) % 360)
        for k in range(16):  # 8 beats of 1/2
            x, y = pts[k % 8] if k % 4 != 3 else pts[(k - 1) % 8]
            m.circle(F(p0) + F(k, 2), x, y, hs=WHISTLE if k % 8 == 0 else 0)
        m.nc_next = True
        m.slider(p0 + 8, 96, 96, 20, 2, 1, 1.0, hs=CLAP)
        m.slider(p0 + 11, 400, 288, 200, 1, 2, 1.0)
    return m


def main_long(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    mp3_path = os.path.join(out_dir, 'long_audio.mp3')
    beat_s = BEAT / 1000
    click = (f"0.5*sin(2*PI*1000*t)*exp(-120*mod(t-{OFFSET / 1000:g},{beat_s!r}))*gte(t,{OFFSET / 1000:g})"
             f"+0.08*sin(2*PI*220*t)")
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i',
                    f"aevalsrc='{click}|{click}':s={SR}:d={LONG_S}", '-b:a', '192k', mp3_path], check=True)
    bg_path = os.path.join(out_dir, 'bg.jpg')
    if not os.path.exists(bg_path):
        subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc=size=1366x768',
                        '-frames:v', '1', '-q:v', '4', bg_path], check=True)
    m = build_long()
    text = osu_text(m, version='Long', tags='test long', preview=60000)
    text = text.replace('Title:Sync Test', 'Title:Long Test').replace('TitleUnicode:Sync Test', 'TitleUnicode:Long Test')
    text = text.replace('AudioFilename: audio.mp3', 'AudioFilename: long_audio.mp3')
    with zipfile.ZipFile(os.path.join(out_dir, 'osuEdit long test.osz'), 'w') as z:
        z.writestr('osuEdit - Long Test (osuEdit) [Long].osu', text.encode('utf-8'))
        z.write(mp3_path, 'long_audio.mp3')
        z.write(bg_path, 'bg.jpg')
    print(f'{len(m.objects)} objects over {LONG_S} s -> {out_dir}')


def png_rgba(w, h, pixel):
    """A PNG from pixel(x, y) -> (r, g, b, a)."""
    raw = b''.join(b'\x00' + b''.join(bytes(pixel(x, y)) for x in range(w)) for y in range(h))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)

    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def storyboard_images():
    def box(x, y):
        edge = x < 4 or y < 4 or x >= 60 or y >= 60
        return (255, 255, 255, 255) if edge else (40, 120, 255, 220)

    def corner(x, y):
        return (255, 220, 0, 255) if x < 6 or y < 6 or x >= 26 or y >= 26 else (0, 0, 0, 0)

    def cross(x, y):  # arms and ring outside the hit circle (radius ~36 at CS4)
        d = math.hypot(x - 79.5, y - 79.5)
        if (abs(x - 79.5) < 1.5 or abs(y - 79.5) < 1.5) and d > 44 or abs(d - 70) < 1.5:
            return (255, 40, 40, 255)
        return (0, 0, 0, 0)

    def fail(x, y):
        return (255, 0, 0, 255) if abs(x - y) < 8 or abs(x + y - 199) < 8 else (0, 0, 0, 0)

    return {
        'sb/box.png': png_rgba(64, 64, box),
        'sb/corner.png': png_rgba(32, 32, corner),
        'sb/cross.png': png_rgba(160, 160, cross),
        'sb/fail.png': png_rgba(200, 200, fail),
        'sb/bar.png': png_rgba(8, 8, lambda x, y: (60, 220, 90, 255)),
        # Animation frames: red / green / blue / white, with 1..4 black bars.
        **{f'sb/anim{i}.png': png_rgba(48, 48, anim_frame(i)) for i in range(4)},
    }


def anim_frame(i):
    colour = [(230, 50, 50, 255), (50, 210, 70, 255), (60, 110, 255, 255), (240, 240, 240, 255)][i]

    def pixel(x, y):
        bar = 6 <= y < 42 and any(8 + k * 9 <= x < 13 + k * 9 for k in range(i + 1))
        return (0, 0, 0, 255) if bar else colour

    return pixel


STORYBOARD_OSB = '''[Events]
//Background and Video events
//Storyboard Layer 0 (Background)
Sprite,Background,Centre,"bg.jpg",320,240
 S,0,0,,0.625
 F,0,0,2000,0,1
 F,0,20000,24000,1,0.3
Sprite,Background,Centre,"sb/box.png",320,240
 M,17,1000,5000,-40,240,680,240,-40,240
 R,0,1000,9000,0,12.566
 F,0,1000,,0.9
//Storyboard Layer 1 (Fail)
Sprite,Fail,Centre,"sb/fail.png",320,240
 F,0,0,30000,1
//Storyboard Layer 2 (Pass)
//Storyboard Layer 3 (Foreground)
Sprite,Foreground,TopLeft,"sb/corner.png",0,0
 F,0,0,30000,1
Sprite,Foreground,TopRight,"sb/corner.png",640,0
 F,0,0,30000,1
Sprite,Foreground,BottomLeft,"sb/corner.png",0,480
 F,0,0,30000,1
Sprite,Foreground,BottomRight,"sb/corner.png",640,480
 F,0,0,30000,1
Sprite,Foreground,CentreLeft,"sb/corner.png",-107,240
 F,0,0,30000,1
Sprite,Foreground,CentreRight,"sb/corner.png",747,240
 F,0,0,30000,1
Sprite,Foreground,Centre,"sb/cross.png",320,248
 F,0,0,30000,1
Sprite,Foreground,Centre,"sb/box.png",120,420
 V,1,1000,1667,1,1,2,0.5,1,1,0.5,2,1,1
 F,0,1000,,1
Animation,Foreground,Centre,"sb/anim.png",560,120,4,500,LoopForever
 F,0,1000,30000,1
Animation,Foreground,Centre,"sb/anim.png",560,360,4,500,LoopOnce
 F,0,1000,30000,1
Sprite,Foreground,Centre,"sb/box.png",80,120
 F,0,1000,30000,1
 C,0,1000,4000,255,0,0,0,255,0,0,0,255
Sprite,Foreground,Centre,"sb/anim2.png",200,120
 F,0,1000,30000,1
Sprite,Foreground,Centre,"sb/anim0.png",224,144
 F,0,1000,30000,1
 P,0,0,0,A
Sprite,Foreground,Centre,"sb/anim1.png",80,360
 F,0,1000,30000,1
 P,0,2000,4000,H
 P,0,4000,6000,V
Sprite,Foreground,Centre,"sb/anim3.png",200,360
 F,0,1000,30000,1
 L,1000,40
  F,0,0,250,1,0
  F,0,250,500,0,1
//Storyboard Layer 4 (Overlay)
//Storyboard Sound Samples
Sample,2000,0,"sb/beep.wav",80
Sample,4000,3,"sb/beep.wav",80
Sample,6000,0,"sb/beep.wav",80
Sample,3000,1,"sb/beep.wav",100
'''.replace('\n', '\r\n')


def beep_wav():
    """A 0.15 s 880 Hz beep (storyboard Sample events)."""
    n = int(SR * 0.15)
    frames = b''.join(struct.pack('<h', int(0.5 * 32767 * math.sin(2 * math.pi * 880 * i / SR) * (1 - i / n)))
                      for i in range(n))
    buf = io.BytesIO()
    with wave.open(buf, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(frames)
    return buf.getvalue()


def main_storyboard(out_dir):
    audio = os.path.join(out_dir, 'audio.mp3')
    bg_path = os.path.join(out_dir, 'bg.jpg')
    if not (os.path.exists(audio) and os.path.exists(bg_path)):
        sys.exit('Run without --storyboard first (needs audio.mp3 and bg.jpg).')
    m = Map()
    for k in range(0, 80, 2):
        m.circle(k, 256, 192)
        m.circle(k + 1, 0 if k % 4 == 0 else 512, 0 if k % 4 == 0 else 384)
    text = osu_text(m, version='Storyboard', tags='test storyboard', preview=1000)
    text = text.replace('Title:Sync Test', 'Title:Storyboard Test').replace('TitleUnicode:Sync Test', 'TitleUnicode:Storyboard Test')
    # A difficulty-specific sprite: a progress bar near the bottom (the editor
    # crops about 28 px off the storyboard's top and bottom).
    text = text.replace('//Storyboard Layer 3 (Foreground)\r\n', '//Storyboard Layer 3 (Foreground)\r\n'
                        'Sprite,Foreground,BottomLeft,"sb/bar.png",0,440\r\n _V,0,1000,29000,0,2,80,2\r\n')
    with zipfile.ZipFile(os.path.join(out_dir, 'osuEdit storyboard test.osz'), 'w') as z:
        z.writestr('osuEdit - Storyboard Test (osuEdit) [Storyboard].osu', text.encode('utf-8'))
        z.writestr('osuEdit - Storyboard Test (osuEdit).osb', STORYBOARD_OSB.encode('utf-8'))
        for name, data in storyboard_images().items():
            z.writestr(name, data)
        z.writestr('sb/beep.wav', beep_wav())
        z.write(audio, 'audio.mp3')
        z.write(bg_path, 'bg.jpg')
    print(f'{len(m.objects)} objects -> {out_dir}')


def build_lazer():
    """Sliders in osu!lazer's own syntax (several curve types in one path,
    a B-spline), plus two stable-expressible ones for comparison."""
    m = Map()
    m.section(0)
    m.curve(0, 64, 96, 'L|P|192:96|256:32|320:96', 1, 2)                         # linear, then a half circle
    m.curve(4, 64, 224, 'B|128:160|192:224|C|256:288|320:224|384:288', 1, 2)    # bezier, then catmull
    m.curve(8, 64, 352, 'B4|128:256|192:352|256:256|320:352|384:256', 1, 2)     # B-spline (degree 4)
    m.curve(12, 96, 192, 'P|160:128|P|224:192|288:256|352:192', 1, 2)           # two arcs
    m.curve(16, 128, 64, 'B|256:32|384:96', 1, 1)                               # plain bezier (stable)
    m.curve(18, 128, 160, 'B|192:96|B|256:160|320:96', 1, 1)                    # lazer red anchor (stable can express)
    # Beats 24-63: empty, for drawing new objects.
    m.section(24)
    return m


def main_lazer(out_dir):
    audio = os.path.join(out_dir, 'audio.mp3')
    bg_path = os.path.join(out_dir, 'bg.jpg')
    if not (os.path.exists(audio) and os.path.exists(bg_path)):
        sys.exit('Run without --lazer first (needs audio.mp3 and bg.jpg).')
    m = build_lazer()
    text = osu_text(m, version='Lazer', tags='test lazer sliders', preview=1000)
    text = (text.replace('osu file format v14', 'osu file format v128')
            .replace('Title:Sync Test', 'Title:Lazer Test').replace('TitleUnicode:Sync Test', 'TitleUnicode:Lazer Test'))
    with zipfile.ZipFile(os.path.join(out_dir, 'osuEdit lazer test.osz'), 'w') as z:
        z.writestr('osuEdit - Lazer Test (osuEdit) [Lazer].osu', text.encode('utf-8'))
        z.write(audio, 'audio.mp3')
        z.write(bg_path, 'bg.jpg')
    print(f'{len(m.objects)} objects -> {out_dir}')


# --- Test skin (--skin) ------------------------------------------------------

SKIN_INI = """[General]
Name: osuEdit Test Skin
Author: osuEdit
Version: 2.5
AllowSliderBallTint: 1
AnimationFramerate: 4

[Colours]
Combo1: 170,60,255
Combo2: 0,200,190
Combo3: 255,140,0
Combo4: 120,220,40
SliderBorder: 255,60,60

[Fonts]
HitCirclePrefix: numbers\\num
HitCircleOverlap: 6
"""

# Seven-segment layout: a, b, c, d, e, f, g.
_SEGMENTS = {
    '0': 'abcdef', '1': 'bc', '2': 'abged', '3': 'abgcd', '4': 'fgbc',
    '5': 'afgcd', '6': 'afgedc', '7': 'abc', '8': 'abcdefg', '9': 'abcdfg',
}


def _digit_png(ch):
    """A yellow seven-segment digit with a black edge, 40 x 56 (SD)."""
    w, h, t = 40, 56, 7
    on = _SEGMENTS[ch]

    def seg(x, y):
        boxes = {
            'a': (6, 3, 34, 3 + t), 'g': (6, 25, 34, 25 + t), 'd': (6, 46, 34, 46 + t),
            'f': (3, 6, 3 + t, 28), 'b': (30, 6, 30 + t, 28),
            'e': (3, 28, 3 + t, 50), 'c': (30, 28, 30 + t, 50),
        }
        inside = edge = False
        for s in on:
            x0, y0, x1, y1 = boxes[s]
            if x0 <= x < x1 and y0 <= y < y1:
                inside = True
            if x0 - 2 <= x < x1 + 2 and y0 - 2 <= y < y1 + 2:
                edge = True
        if inside:
            return (255, 230, 40, 255)
        return (0, 0, 0, 255) if edge else (0, 0, 0, 0)

    return png_rgba(w, h, seg)


def _disc(size, fn):
    """pixel(x, y) from fn(r) with r = distance from the centre / radius."""
    c = (size - 1) / 2

    def px(x, y):
        return fn(math.hypot(x - c, y - c) / (size / 2), math.atan2(y - c, x - c))

    return png_rgba(size, size, px)


def skin_files():
    files = {'skin.ini': SKIN_INI.encode('utf-8')}
    # hitcircle@2x: white disc with a grey band (tinted by the combo colour).
    files['hitcircle@2x.png'] = _disc(256, lambda r, a: (0, 0, 0, 0) if r > 0.9 else
                                      (150, 150, 150, 255) if 0.45 < r < 0.6 else (255, 255, 255, 255))
    # Overlay: a thick black outer ring with a thin white line inside.
    files['hitcircleoverlay@2x.png'] = _disc(256, lambda r, a: (0, 0, 0, 0) if r > 0.92 else
                                             (0, 0, 0, 255) if r > 0.8 else
                                             (255, 255, 255, 255) if r > 0.76 else (0, 0, 0, 0))
    # Approach circle: a dashed ring.
    files['approachcircle.png'] = _disc(128, lambda r, a: (255, 255, 255, 255)
                                        if 0.86 < r < 0.98 and int((a + math.pi) / (math.pi / 8)) % 2 == 0
                                        else (0, 0, 0, 0))
    # Slider ball frames: a white disc with a black triangle pointing along
    # the path (frame 1: a smaller triangle).

    def ball(scale):
        def fn(r, a):
            if r > 0.7:
                return (0, 0, 0, 0)
            x, y = r * math.cos(a), r * math.sin(a)
            tri = x > -0.3 * scale and abs(y) < (0.45 * scale - x) * 0.9
            return (0, 0, 0, 255) if tri else (255, 255, 255, 255)
        return fn

    files['sliderb0.png'] = _disc(128, ball(1.0))
    files['sliderb1.png'] = _disc(128, ball(0.6))
    # Follow circle: an orange dashed ring.
    files['sliderfollowcircle.png'] = _disc(256, lambda r, a: (255, 150, 0, 255)
                                            if 0.85 < r < 0.97 and int((a + math.pi) / (math.pi / 12)) % 2 == 0
                                            else (0, 0, 0, 0))
    # Reverse arrow: a filled magenta triangle pointing right.
    files['reversearrow.png'] = png_rgba(128, 128, lambda x, y: (255, 0, 200, 255)
                                         if 34 <= x <= 96 and abs(y - 64) <= (96 - x) * 0.6 else (0, 0, 0, 0))
    # Slider tick: a cyan diamond.
    files['sliderscorepoint.png'] = png_rgba(32, 32, lambda x, y: (0, 230, 255, 255)
                                             if abs(x - 15.5) + abs(y - 15.5) <= 12 else (0, 0, 0, 0))
    # Follow point: a green bar with a head pointing right (two frames).
    files['followpoint-0.png'] = png_rgba(64, 24, lambda x, y: (60, 255, 60, 255)
                                          if (8 <= x <= 40 and 9 <= y <= 14) or (40 <= x <= 56 and abs(y - 11.5) <= (56 - x) * 0.6)
                                          else (0, 0, 0, 0))
    files['followpoint-1.png'] = png_rgba(64, 24, lambda x, y: (200, 255, 60, 255)
                                          if (8 <= x <= 40 and 9 <= y <= 14) or (40 <= x <= 56 and abs(y - 11.5) <= (56 - x) * 0.6)
                                          else (0, 0, 0, 0))
    # Old-style spinner: a spoked wheel and its shrinking approach ring.
    files['spinner-circle.png'] = _disc(400, lambda r, a: (0, 0, 0, 0) if r > 0.98 else
                                        (255, 255, 255, 230) if r > 0.92 or (r > 0.15 and int((a + math.pi) / (math.pi / 6)) % 2 == 0 and r < 0.9)
                                        else (40, 40, 80, 160))
    files['spinner-approachcircle.png'] = _disc(320, lambda r, a: (120, 200, 255, 255) if 0.9 < r < 0.98 else (0, 0, 0, 0))
    for ch in '0123456789':
        files[f'numbers/num-{ch}.png'] = _digit_png(ch)
    # A skin hitsound (a short high blip instead of the built-in hit).
    n = int(SR * 0.06)
    frames = b''.join(struct.pack('<h', int(0.4 * 32767 * math.sin(2 * math.pi * 1500 * i / SR) * (1 - i / n)))
                      for i in range(n))
    buf = io.BytesIO()
    with wave.open(buf, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(frames)
    files['normal-hitnormal.wav'] = buf.getvalue()
    return files


def main_skin(out_dir):
    """osuEdit test skin.osk, zipped inside its own folder (like many skins)."""
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, 'osuEdit test skin.osk')
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, data in skin_files().items():
            z.writestr('osuEdit Test Skin/' + name, data)
    print(f'-> {path}')


def main(out_dir):
    m = build()
    with open(FIXTURE, 'w', newline='', encoding='utf-8') as f:
        f.write(osu_text(m))
    shapes = build_shapes()
    with open(SHAPES_FIXTURE, 'w', newline='', encoding='utf-8') as f:
        f.write(osu_text(shapes, version='Shapes', tags='test slider shapes', preview=1000))
    os.makedirs(out_dir, exist_ok=True)
    wav_path = os.path.join(out_dir, 'click.wav')
    click_track(m, wav_path)
    mp3_path = os.path.join(out_dir, 'audio.mp3')
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', wav_path, '-b:a', '192k', mp3_path], check=True)
    os.remove(wav_path)
    bg_path = os.path.join(out_dir, 'bg.jpg')
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc=size=1366x768',
                    '-frames:v', '1', '-q:v', '4', bg_path], check=True)
    with zipfile.ZipFile(os.path.join(out_dir, 'osuEdit test set.osz'), 'w') as z:
        z.write(FIXTURE, 'osuEdit - Sync Test (osuEdit) [Snaps].osu')
        z.write(SHAPES_FIXTURE, 'osuEdit - Sync Test (osuEdit) [Shapes].osu')
        z.write(mp3_path, 'audio.mp3')
        z.write(bg_path, 'bg.jpg')
    print(f'{len(m.objects)} objects, last at {t_int(max(b for b, _ in m.objects))} ms -> {FIXTURE}, {out_dir}')


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if a not in ('--long', '--storyboard', '--lazer', '--skin')]
    out = args[0] if args else os.path.join(REPO, 'tool', 'test_set')
    if '--long' in sys.argv:
        main_long(out)
    elif '--storyboard' in sys.argv:
        main_storyboard(out)
    elif '--lazer' in sys.argv:
        main_lazer(out)
    elif '--skin' in sys.argv:
        main_skin(out)
    else:
        main(out)
