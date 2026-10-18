import 'package:flutter/material.dart';

import '../platform/app_updater.dart';

/// A small "TEST BUILD" tag, shown only in the development app
/// (`OSUEDIT_DEV=1`, version name `x.y.z-dev`); nothing in the release app.
class DevBadge extends StatefulWidget {
  const DevBadge({super.key});

  @override
  State<DevBadge> createState() => _DevBadgeState();
}

class _DevBadgeState extends State<DevBadge> {
  bool _dev = false;

  @override
  void initState() {
    super.initState();
    AppUpdater.currentVersion().then((v) {
      if (mounted && AppUpdater.isDevVersion(v)) setState(() => _dev = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_dev) return const SizedBox.shrink();
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: const Color(0xCCB3261E),
          borderRadius: BorderRadius.circular(3),
        ),
        child: const Text(
          'TEST BUILD',
          style: TextStyle(fontSize: 8, fontWeight: FontWeight.w700, color: Colors.white, letterSpacing: 0.5),
        ),
      ),
    );
  }
}
