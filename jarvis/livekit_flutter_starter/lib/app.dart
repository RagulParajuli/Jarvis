import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_components/livekit_components.dart' as components;
import 'package:provider/provider.dart';

import 'controllers/app_ctrl.dart';
import 'screens/agent_screen.dart';
import 'screens/welcome_screen.dart';
import 'ui/hud_theme.dart';
import 'widgets/app_layout_switcher.dart';
import 'widgets/session_error_banner.dart';

final appCtrl = AppCtrl();

class VoiceAssistantApp extends StatelessWidget {
  const VoiceAssistantApp({super.key});

  /// The HUD is dark by design — both theme slots point at the same palette.
  ThemeData buildTheme() => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: HudColors.fontFamily,
        cardColor: HudColors.surface,
        scaffoldBackgroundColor: HudColors.bg,
        canvasColor: HudColors.bg,
        colorScheme: const ColorScheme.dark(
          primary: HudColors.cyan,
          onPrimary: HudColors.bg,
          secondary: HudColors.cyan,
          surface: HudColors.surface,
          onSurface: HudColors.text,
          error: HudColors.red,
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(
            fontSize: 15,
            height: 1.4,
            color: HudColors.text,
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          fillColor: HudColors.surface,
          hintStyle: TextStyle(
            color: HudColors.textDim,
            fontSize: 14,
          ),
        ),
      );

  @override
  Widget build(BuildContext ctx) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: appCtrl),
          ChangeNotifierProvider.value(value: appCtrl.session),
          ChangeNotifierProvider.value(value: appCtrl.roomContext),
        ],
        child: components.SessionContext(
          session: appCtrl.session,
          child: MaterialApp(
            title: 'Jarvis',
            theme: buildTheme(),
            darkTheme: buildTheme(),
            themeMode: ThemeMode.dark,
            home: Builder(
              builder: (ctx) => Container(
                color: HudColors.bg,
                child: Listener(
                  // Browsers only allow audio playback after a user gesture.
                  // Observing pointer events (instead of handling them) unlocks
                  // audio without stealing the gesture from whatever was pressed.
                  onPointerDown: (_) => unawaited(appCtrl.enableAudio()),
                  child: Stack(
                    children: [
                      Selector<AppCtrl, AppScreenState>(
                        selector: (ctx, appCtx) => appCtx.appScreenState,
                        builder: (ctx, screen, _) => AppLayoutSwitcher(
                          frontBuilder: (ctx) => const WelcomeScreen(),
                          backBuilder: (ctx) => const AgentScreen(),
                          isFront: screen == AppScreenState.welcome,
                        ),
                      ),
                      const SessionErrorBanner(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}
