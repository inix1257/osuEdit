// Desktop background check: in-app toasts (replace the snack bars) show at
// the bottom centre over the editor, carry an action, and fade away.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/toast_test.dart -d windows
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/toast.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('toast shows, runs its action, and disappears', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');

    AppToast.show('Saved Snaps.osu');
    await settle(tester, const Duration(milliseconds: 400));
    expect(find.text('Saved Snaps.osu'), findsOneWidget);
    await shot(tester, 'toast_plain');

    var undone = false;
    AppToast.show('Copied hitsounds to 2 difficulties',
        actionLabel: 'Undo', onAction: () => undone = true, duration: const Duration(seconds: 8));
    await settle(tester, const Duration(milliseconds: 400));
    expect(find.text('Saved Snaps.osu'), findsNothing); // replaced
    await shot(tester, 'toast_action');
    await tester.tap(find.text('Undo'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(undone, isTrue);
    expect(find.text('Copied hitsounds to 2 difficulties'), findsNothing);

    AppToast.show('Gone soon');
    await settle(tester, const Duration(milliseconds: 3600));
    expect(find.text('Gone soon'), findsNothing);
  });
}
