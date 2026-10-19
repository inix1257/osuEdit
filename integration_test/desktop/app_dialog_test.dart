// Desktop background check: the in-app dialog (replaces AlertDialog), here
// the delete confirmation's look, with a toast showing over the top.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/app_dialog_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/app_dialog.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/toast.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('delete confirmation uses the in-app dialog', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final ctx = tester.element(find.byType(EditorScreen));
    showDialog<bool>(
      context: ctx,
      builder: (ctx) => AppDialog(
        title: const Text('Delete "Snaps"?'),
        content: const Text("The file Snaps.osu is deleted from the set. This can't be undone."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    await settle(tester, const Duration(milliseconds: 500));
    AppToast.show('Toast over a dialog');
    await settle(tester, const Duration(milliseconds: 400));
    expect(find.byType(AppDialog), findsOneWidget);
    await shot(tester, 'app_dialog_delete');
    await tester.tap(find.text('Cancel'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(find.byType(AppDialog), findsNothing);
  });
}
