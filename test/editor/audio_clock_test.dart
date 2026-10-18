import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/editor/audio_clock.dart';

import '../support/fake_audio.dart';

void main() {
  late double wall;
  late FakeTrack track;
  late AudioClock clock;

  setUp(() {
    wall = 0;
    track = FakeTrack(() => wall);
    clock = AudioClock(track, now: () => wall);
  });

  /// Advances fake wall time frame by frame, reading the clock each frame
  /// like the editor's ticker. Returns the readings.
  List<double> run(double ms, {double frame = 16.7}) {
    final out = <double>[];
    for (var t = 0.0; t < ms; t += frame) {
      wall += frame;
      out.add(clock.currentTime);
    }
    return out;
  }

  test('tracks the true audio position within a few ms despite coarse updates', () {
    clock.seek(1000);
    clock.play();
    final readings = run(3000);
    // Monotonic.
    for (var i = 1; i < readings.length; i++) {
      expect(readings[i], greaterThanOrEqualTo(readings[i - 1]));
    }
    // After settling, close to the exact position.
    final exact = 1000 + wall;
    expect((clock.currentTime - exact).abs(), lessThan(25));
  });

  test('pause freezes time and parks the engine there', () {
    clock.seek(0);
    clock.play();
    run(1000);
    clock.pause();
    final t = clock.currentTime;
    wall += 500;
    expect(clock.currentTime, t);
    expect(track.position, closeTo(t, 0.001));
    clock.play();
    run(200);
    expect(clock.currentTime, greaterThan(t));
  });

  test('seek while playing jumps immediately', () {
    clock.seek(0);
    clock.play();
    run(500);
    clock.seek(5000);
    expect(clock.currentTime, closeTo(5000, 0.001));
    run(500);
    expect(clock.currentTime, closeTo(5500, 30));
  });

  test('rate scales time', () {
    clock.seek(0);
    clock.rate = 0.5;
    clock.play();
    run(2000);
    expect(clock.currentTime, closeTo(1000, 30));
  });

  test('a new clock resets a track left at another speed', () {
    track.speed = 0.5;
    clock = AudioClock(track, now: () => wall);
    clock.seek(0);
    clock.play();
    run(1000);
    expect(clock.currentTime, closeTo(1000, 30));
  });

  test('holds the playhead while a lagging track catches up, then follows it', () {
    // 0.5x with a 120 ms (output time) filter delay: the engine reports
    // 60 ms of music behind the seek target right after play.
    track = FakeTrack(() => wall, quantum: 23, latency: 120);
    clock = AudioClock(track, now: () => wall);
    clock.rate = 0.5;
    clock.seek(2000);
    clock.play();
    final readings = run(1500);
    for (var i = 1; i < readings.length; i++) {
      expect(readings[i], greaterThanOrEqualTo(readings[i - 1]));
    }
    // Held near the target during the silent part instead of running ahead.
    expect(readings[3], lessThan(2005));
    // Then tracks the audible position: 2000 + (1500 − 120) × 0.5.
    expect(clock.currentTime, closeTo(2000 + (1500 - 120) * 0.5, 15));
  });

  test('negative time pre-rolls, then starts the track at 0', () {
    clock.seek(-500);
    clock.play();
    expect(track.isPlaying, isFalse);
    run(300);
    expect(track.isPlaying, isFalse);
    expect(clock.currentTime, closeTo(-200, 20));
    run(1000);
    expect(track.isPlaying, isTrue);
    expect(clock.currentTime, closeTo(800, 30));
  });

  test('offset shifts displayed time but not audio time', () {
    clock.offset = 40;
    clock.seek(1000);
    expect(clock.currentTime, closeTo(1000, 0.001));
    expect(clock.audioTime, closeTo(1040, 0.001));
    expect(track.position, closeTo(1040, 0.001));
  });

  test('stops at the end of the track', () {
    clock.seek(9800);
    clock.play();
    run(1000);
    expect(clock.isPlaying, isFalse);
    expect(clock.currentTime, closeTo(10000, 0.001));
    clock.play(); // at end: no-op
    expect(clock.isPlaying, isFalse);
  });
}
