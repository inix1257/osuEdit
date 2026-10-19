import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_fonts.dart';
import 'home/home_screen.dart';
import 'platform/frame_stats.dart';
import 'toast.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The editor is landscape-only and uses the whole screen: system bars
  // stay hidden and only reappear transiently on an edge swipe.
  SystemChrome.setPreferredOrientations(const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  FrameStats.install();
  runApp(const OsuEditApp());
}

class OsuEditApp extends StatelessWidget {
  /// The start screen (desktop integration tests inject one with a temp library).
  final Widget home;

  const OsuEditApp({super.key, this.home = const HomeScreen()});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'osu!Edit',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFFFF66AA),
        useMaterial3: true,
        fontFamily: kUiFont,
      ),
      theme: ThemeData(colorSchemeSeed: const Color(0xFFFF66AA), useMaterial3: true, fontFamily: kUiFont),
      builder: (context, child) => ToastHost(child: child),
      home: home,
    );
  }
}
