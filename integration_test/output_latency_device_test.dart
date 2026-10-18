// On-device: the output latency measurement (AudioSession.measureOutputLatency)
// repeated, to see how stable it is on this device.
//
// Run without wiping the app's library (`flutter test -d` uninstalls it):
//   flutter build apk --debug -t integration_test/output_latency_device_test.dart
//   adb install -r build/app/outputs/flutter-apk/app-debug.apk
//   adb shell am start -n com.osuedit.osu_edit/.MainActivity
//   adb logcat -s flutter | grep LATENCY
// then reinstall the release build.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:osu_edit/platform/audio_session.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('output latency', (tester) async {
    await tester.runAsync(() async {
      final values = <double?>[];
      for (var i = 0; i < 6; i++) {
        values.add(await AudioSession.instance.measureOutputLatency());
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      // ignore: avoid_print
      print('[LATENCY] ${values.map((v) => v?.toStringAsFixed(1)).join(' ')} ms');
    });
  });
}
