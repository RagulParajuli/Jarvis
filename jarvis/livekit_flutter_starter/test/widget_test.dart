import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/ui/hud_theme.dart';

void main() {
  testWidgets('HUD label uppercases and glows', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: HudLabel('jarvis online', glow: true)),
      ),
    );

    expect(find.text('JARVIS ONLINE'), findsOneWidget);
    final label = tester.widget<Text>(find.text('JARVIS ONLINE'));
    expect(label.style?.color, HudColors.textDim);
    expect(label.style?.shadows, isNotNull);
  });

  testWidgets('HUD button reports taps', (WidgetTester tester) async {
    var taps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HudButton(label: 'connect', onPressed: () => taps++),
        ),
      ),
    );

    await tester.tap(find.text('CONNECT'));
    expect(taps, 1);
  });

  testWidgets('HUD button is inert without a callback', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: HudButton(label: 'connect')),
      ),
    );

    await tester.tap(find.text('CONNECT'));
    final opacity = tester.widget<Opacity>(find.byType(Opacity).first);
    expect(opacity.opacity, lessThan(1));
  });
}
