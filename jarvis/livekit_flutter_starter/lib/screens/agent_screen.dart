import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as sdk;
import 'package:livekit_components/livekit_components.dart' as components;
import 'package:provider/provider.dart';

import '../controllers/app_ctrl.dart';
import '../ui/hud_theme.dart';
import '../widgets/hud_audio_visualizer.dart';
import '../widgets/message_bar.dart';

/// HUD session view, ported from the web frontend's `hud-session-view.tsx`:
/// a radial voice visualizer in the middle, system readouts in the corners and
/// a chamfered control bar along the bottom.
class AgentScreen extends StatefulWidget {
  const AgentScreen({super.key});

  @override
  State<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends State<AgentScreen> {
  bool _showTranscript = false;

  @override
  Widget build(BuildContext ctx) => Material(
        color: HudColors.bg,
        child: SafeArea(
          child: HudGridBackground(
            child: LayoutBuilder(
              builder: (ctx, constraints) {
                // Phones get wider gutters and a smaller visualizer; desktop
                // windows get the roomier `md:` insets from the web HUD.
                final narrow = constraints.maxWidth < 380;
                final horizontalInset = constraints.maxWidth >= 720 ? 48.0 : 12.0;
                final vizSize = math.min(constraints.maxWidth - 48, constraints.maxHeight - 260).clamp(140.0, 340.0);

                return Stack(
                  children: [
                    if (!_showTranscript) Positioned.fill(child: _buildVisualizer(ctx, vizSize)),
                    if (_showTranscript)
                      Positioned(
                        top: narrow ? 46 : 56,
                        left: horizontalInset,
                        right: horizontalInset,
                        bottom: 88,
                        child: _buildTranscript(ctx),
                      ),
                    Positioned(
                      top: 16,
                      left: 16,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const HudLabel('JARVIS v4.2.1'),
                          if (!narrow) const HudLabel('STARK INDUSTRIES'),
                        ],
                      ),
                    ),
                    Positioned(
                      top: 16,
                      right: 16,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const HudLabel('NEURAL LINK ACTIVE'),
                          if (!narrow) const HudLabel('ARC REACTOR: STABLE'),
                        ],
                      ),
                    ),
                    if (!_showTranscript)
                      Positioned(
                        top: narrow ? 50 : 60,
                        right: horizontalInset,
                        child: _buildCameraPreview(ctx, narrow ? 116.0 : 164.0),
                      ),
                    Positioned(
                      left: horizontalInset,
                      right: horizontalInset,
                      bottom: 0,
                      child: _buildControlBar(ctx),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );

  Widget _buildVisualizer(BuildContext ctx, double size) => Consumer<sdk.Session>(
        builder: (ctx, session, _) {
          final status = _status(session);
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              HudLabel(
                status.text,
                color: status.color,
                glow: status.glow,
              ),
              const SizedBox(height: 24),
              Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: size + 40,
                    height: size + 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: HudColors.cyan.withValues(alpha: 0.10)),
                    ),
                  ),
                  HudAudioVisualizer(
                    session.agent,
                    size: size,
                    // 110/280 in the web HUD, kept proportional to the ring.
                    radius: size * 0.393,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Text(
                'JARVIS',
                style: HudText.glow.copyWith(fontSize: 18, letterSpacing: 7.2),
              ),
            ],
          );
        },
      );

  /// Live feed of the local camera, and the answer to "is my camera on?".
  ///
  /// The panel only exists while a camera track is published, so its absence is
  /// itself the readout. The caption names the lens that is currently feeding it.
  Widget _buildCameraPreview(BuildContext ctx, double width) => components.MediaDeviceContextBuilder(
        builder: (ctx, roomCtx, deviceCtx) {
          final publications = roomCtx.localParticipant?.videoTrackPublications;
          final track = publications == null || publications.isEmpty ? null : publications.first.track;

          if (!deviceCtx.cameraOpened || track == null) return const SizedBox.shrink();

          final rear = deviceCtx.currentPosition == sdk.CameraPosition.back;
          return HudPanel(
            padding: const EdgeInsets.all(6),
            fill: HudColors.bg,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: width,
                  height: width * 9 / 16,
                  child: sdk.VideoTrackRenderer(track, fit: sdk.VideoViewFit.cover),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 6, height: 6, color: HudColors.red),
                    const SizedBox(width: 6),
                    HudLabel(
                      'CAM LIVE - ${rear ? 'REAR' : 'FRONT'}',
                      color: HudColors.cyan,
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );

  Widget _buildTranscript(BuildContext ctx) => Container(
        decoration: BoxDecoration(
          color: HudColors.bg.withValues(alpha: 0.92),
          border: const Border(
            top: BorderSide(color: HudColors.cyan, width: 2),
            left: BorderSide(color: HudColors.border),
            right: BorderSide(color: HudColors.border),
            bottom: BorderSide(color: HudColors.border),
          ),
        ),
        child: Consumer<sdk.Session>(
          builder: (ctx, session, _) => Column(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => ctx.read<AppCtrl>().messageFocusNode.unfocus(),
                  child: components.ChatScrollView(
                    session: session,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                    physics: const BouncingScrollPhysics(),
                    messageBuilder: (ctx, message) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _MessageBubble(message: message),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Selector<AppCtrl, bool>(
                  selector: (ctx, appCtrl) => appCtrl.isSendButtonEnabled,
                  builder: (ctx, isSendEnabled, _) => MessageBar(
                    focusNode: ctx.read<AppCtrl>().messageFocusNode,
                    isSendEnabled: isSendEnabled,
                    controller: ctx.read<AppCtrl>().messageCtrl,
                    onSendTap: () => ctx.read<AppCtrl>().sendMessage(),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _buildControlBar(BuildContext ctx) => Column(
        children: [
          Consumer<AppCtrl>(
            builder: (ctx, appCtrl, _) => appCtrl.isAudioBlocked
                ? const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: HudLabel(
                      'TAP ANYWHERE TO ENABLE AUDIO',
                      color: HudColors.amber,
                      glow: true,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          Container(height: 1, color: HudColors.border),
          const SizedBox(height: 8),
          components.MediaDeviceContextBuilder(
            builder: (ctx, roomCtx, deviceCtx) => Row(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 8,
              children: [
                HudIconButton(
                  icon: deviceCtx.microphoneOpened ? Icons.mic : Icons.mic_off,
                  active: deviceCtx.microphoneOpened,
                  onPressed: () =>
                      deviceCtx.microphoneOpened ? deviceCtx.disableMicrophone() : deviceCtx.enableMicrophone(),
                ),
                HudIconButton(
                  icon: deviceCtx.cameraOpened ? Icons.videocam : Icons.videocam_off,
                  active: deviceCtx.cameraOpened,
                  onPressed: () => deviceCtx.cameraOpened ? deviceCtx.disableCamera() : deviceCtx.enableCamera(),
                ),
                // Only offered once there is a camera track to flip, and the icon
                // shows which lens is live so the button doubles as an indicator.
                if (deviceCtx.cameraOpened)
                  HudIconButton(
                    icon: deviceCtx.currentPosition == sdk.CameraPosition.back
                        ? Icons.video_camera_back
                        : Icons.video_camera_front,
                    active: true,
                    onPressed: () => deviceCtx.toggleCameraPosition(),
                  ),
                HudIconButton(
                  icon: Icons.subject,
                  active: _showTranscript,
                  onPressed: () => setState(() => _showTranscript = !_showTranscript),
                ),
                HudIconButton(
                  icon: Icons.call_end,
                  color: HudColors.red,
                  onPressed: () => unawaited(ctx.read<AppCtrl>().disconnect()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
      );

  /// Mirrors the frontend's status label above the visualizer.
  ({String text, Color color, bool glow}) _status(sdk.Session session) {
    // The SDK gives up on the agent 20 s after joining. That almost always means
    // no worker is dispatching the agent, which is worth saying out loud.
    if (session.agent.error == sdk.AgentFailure.timeout) {
      return (
        text: 'Agent not reachable - is the worker running?',
        color: HudColors.amber,
        glow: false,
      );
    }

    final agent = session.agent;
    if (!agent.isConnected) {
      return (text: 'Establishing neural link...', color: HudColors.textDim, glow: false);
    }

    final state = agent.agentState;
    final active = state == sdk.AgentState.thinking || state == sdk.AgentState.speaking;
    return (
      text: session.messages.isEmpty ? 'Jarvis is listening' : (state?.name ?? 'listening'),
      color: active ? HudColors.cyan : HudColors.textDim,
      glow: active,
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final sdk.ReceivedMessage message;

  bool get _isUserMessage => message.content is sdk.UserInput || message.content is sdk.UserTranscript;

  @override
  Widget build(BuildContext context) {
    final text = message.content.text.trim();
    if (text.isEmpty) {
      return const SizedBox.shrink();
    }

    final isUser = _isUserMessage;
    final accent = isUser ? HudColors.cyan : HudColors.border;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: HudColors.surface,
            border: Border.all(color: accent),
          ),
          child: Text(
            text,
            style: HudText.monoSmall.copyWith(
              color: isUser ? HudColors.cyan : HudColors.text,
            ),
          ),
        ),
      ),
    );
  }
}
