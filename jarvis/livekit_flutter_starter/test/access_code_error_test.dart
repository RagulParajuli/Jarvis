import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/ui/hud_theme.dart';
import 'package:jarvis/widgets/access_code_error.dart';

/// A rejected code is only useful if the user can see that it was rejected.
void main() {
  Widget host(String? message) => MaterialApp(
        home: Scaffold(body: AccessCodeError(message: message)),
      );

  testWidgets('a rejected-code message is shown prominently', (tester) async {
    const message = 'That access code was rejected. Check it and try again.';

    await tester.pumpWidget(host(message));

    final text = tester.widget<Text>(find.text(message));
    expect(text.textAlign, TextAlign.center);
    expect(text.style?.color, HudColors.red);
  });

  testWidgets('shows nothing when there is no message', (tester) async {
    await tester.pumpWidget(host(null));

    expect(find.byType(Text), findsNothing);
  });

  testWidgets('shows nothing for an empty message', (tester) async {
    await tester.pumpWidget(host(''));

    expect(find.byType(Text), findsNothing);
  });
}
