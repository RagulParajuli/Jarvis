import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as sdk;
import 'package:provider/provider.dart';

import '../controllers/app_ctrl.dart' as ctrl;
import '../ui/hud_theme.dart';

const _bootLines = <String>[
  'JARVIS v4.2.1 - INITIALIZING...',
  'Neural link: STANDBY',
  'Voice recognition: READY',
  'Wake word: "JARVIS"',
  'Browser interface: ACTIVE',
  'Search engine: DUCKDUCKGO',
  'Local PC access: READY',
  'All systems nominal.',
  '> Awaiting your voice...',
];

bool _isHighlighted(String line) =>
    line.startsWith('>') || line.contains('READY') || line.contains('ACTIVE') || line.contains('nominal');

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _spin;
  Timer? _bootTimer;
  int _visibleLines = 0;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();
    _bootTimer = Timer.periodic(const Duration(milliseconds: 220), (timer) {
      if (!mounted) return;
      setState(() => _visibleLines++);
      if (_visibleLines >= _bootLines.length) {
        timer.cancel();
        Future<void>.delayed(const Duration(milliseconds: 300), () {
          if (mounted) setState(() => _ready = true);
        });
      }
    });
  }

  @override
  void dispose() {
    _bootTimer?.cancel();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext ctx) => Consumer2<ctrl.AppCtrl, sdk.Session>(
        builder: (ctx, appCtrl, session, _) {
          final isConnecting = appCtrl.isSessionStarting || session.connectionState != sdk.ConnectionState.disconnected;

          return HudGridBackground(
            child: LayoutBuilder(
              builder: (ctx, constraints) {
                // Phone-height windows need a smaller ring and tighter spacing;
                // the decoration strip only fits when there is room for it.
                final compact = constraints.maxHeight < 700;
                final ringSize = compact ? 156.0 : 200.0;
                final gap = compact ? 20.0 : 36.0;
                final showDecoration = constraints.maxHeight >= 560 && constraints.maxWidth >= 360;

                return Stack(
                  children: [
                    Center(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(24, 24, 24, showDecoration ? 72 : 24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildRing(ringSize),
                            SizedBox(height: gap),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: math.min(420, constraints.maxWidth - 48),
                              ),
                              child: _buildBootLog(compact: compact),
                            ),
                            SizedBox(height: gap * 0.8),
                            HudLabel(
                              _ready ? 'Say "JARVIS" to activate - no button needed' : 'Initializing...',
                              textAlign: TextAlign.center,
                              glow: _ready,
                              color: _ready ? HudColors.cyan : HudColors.textDim,
                            ),
                            const SizedBox(height: 20),
                            HudButton(
                              label: !_ready
                                  ? 'Initializing...'
                                  : isConnecting
                                      ? 'Connecting'
                                      : 'Activate Jarvis',
                              filled: _ready && !isConnecting,
                              onPressed: _ready && !isConnecting ? appCtrl.connect : null,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (showDecoration) ...[
                      const Positioned(
                        left: 24,
                        bottom: 24,
                        child: HudLabel('LAT 13.0827° N  |  LON 80.2707° E'),
                      ),
                      const Positioned(
                        right: 24,
                        bottom: 24,
                        child: HudLabel('SYS STATUS: NOMINAL'),
                      ),
                    ],
                  ],
                );
              },
            ),
          );
        },
      );

  Widget _buildRing(double outer) {
    final mid = outer * 0.73;
    final inner = outer * 0.5;
    final showSubtitle = outer >= 180;

    return SizedBox(
      width: outer,
      height: outer,
      child: Stack(
        alignment: Alignment.center,
        children: [
          _ring(outer, 0.20),
          _ring(mid, 0.40),
          AnimatedBuilder(
            animation: _spin,
            builder: (ctx, child) => Transform.rotate(
              angle: _spin.value * 2 * math.pi,
              child: child,
            ),
            child: Container(
              width: inner,
              height: inner,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border(
                  top: BorderSide(color: HudColors.cyan),
                  right: BorderSide(color: HudColors.cyan),
                  bottom: BorderSide(color: Colors.transparent),
                  left: BorderSide(color: Colors.transparent),
                ),
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'JARVIS',
                style: HudText.glow.copyWith(
                  fontSize: outer * 0.14,
                  letterSpacing: outer * 0.048,
                ),
              ),
              if (showSubtitle) const HudLabel('Personal AI System'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _ring(double size, double opacity) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: HudColors.cyan.withValues(alpha: opacity)),
        ),
      );

  Widget _buildBootLog({bool compact = false}) => HudPanel(
        padding: EdgeInsets.fromLTRB(compact ? 16 : 24, 16, compact ? 16 : 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const HudLabel('System Boot Log'),
            const SizedBox(height: 8),
            const Divider(height: 1, thickness: 1, color: HudColors.border),
            const SizedBox(height: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in _bootLines.take(_visibleLines))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      line,
                      style: HudText.monoSmall.copyWith(
                        color: _isHighlighted(line) ? HudColors.cyan : HudColors.textDim,
                      ),
                    ),
                  ),
                if (_visibleLines < _bootLines.length)
                  AnimatedBuilder(
                    animation: _spin,
                    builder: (ctx, _) => Opacity(
                      opacity: (_spin.value * 3) % 1 < 0.5 ? 1 : 0,
                      child: Container(width: 6, height: 12, color: HudColors.cyan),
                    ),
                  ),
              ],
            ),
          ],
        ),
      );
}
