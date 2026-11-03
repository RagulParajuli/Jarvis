import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as sdk;

import '../ui/hud_theme.dart';

/// Radial audio visualizer for the agent's voice, mirroring the web HUD's
/// `AgentAudioVisualizerRadial`.
///
/// Bars radiate outward from a ring: they follow the live audio samples while
/// the agent speaks, sweep around the ring while it thinks, and sit at rest
/// with a gentle pulse while it listens.
class HudAudioVisualizer extends StatefulWidget {
  const HudAudioVisualizer(
    this.agent, {
    super.key,
    this.barCount = 24,
    this.radius = 110,
    this.size = 280,
  });

  final sdk.Agent agent;

  /// The web analyser slices its 170 frequency bins into `barCount` chunks
  /// rounded up, and walks one chunk too far unless the two divide evenly.
  /// 24 bins it cleanly; 32 throws on every frame and the ring stays flat.
  final int barCount;
  final double radius;
  final double size;

  @override
  State<HudAudioVisualizer> createState() => _HudAudioVisualizerState();
}

class _HudAudioVisualizerState extends State<HudAudioVisualizer> with TickerProviderStateMixin {
  late final AnimationController _pulse;
  late final AnimationController _sweep;

  sdk.AudioVisualizer? _visualizer;
  sdk.EventsListener<sdk.AudioVisualizerEvent>? _visualizerListener;
  String? _trackSid;
  List<double> _samples = [];

  @override
  void initState() {
    super.initState();
    _samples = List<double>.filled(widget.barCount, 0);
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(reverse: true);
    _sweep = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();

    widget.agent.addListener(_handleAgentChanged);
    unawaited(_syncTrack());
  }

  @override
  void dispose() {
    widget.agent.removeListener(_handleAgentChanged);
    unawaited(_detachVisualizer());
    _pulse.dispose();
    _sweep.dispose();
    super.dispose();
  }

  void _handleAgentChanged() {
    if (!mounted) return;
    setState(() {});
    unawaited(_syncTrack());
  }

  /// (Re)attaches the SDK visualizer whenever the agent's audio track changes.
  Future<void> _syncTrack() async {
    final track = widget.agent.audioTrack;
    if (track?.sid == _trackSid) return;
    _trackSid = track?.sid;

    await _detachVisualizer();

    if (track == null) {
      if (mounted) setState(() => _samples = List<double>.filled(widget.barCount, 0));
      return;
    }

    final visualizer = sdk.createVisualizer(
      track,
      options: sdk.AudioVisualizerOptions(barCount: widget.barCount),
    );
    _visualizer = visualizer;
    _visualizerListener = visualizer.createListener();
    _visualizerListener?.on<sdk.AudioVisualizerEvent>((event) {
      if (!mounted) return;
      setState(() => _samples = event.event.map((value) => (value as num).toDouble()).toList());
    });

    await visualizer.start();
  }

  Future<void> _detachVisualizer() async {
    await _visualizer?.stop();
    await _visualizer?.dispose();
    _visualizer = null;
    await _visualizerListener?.dispose();
    _visualizerListener = null;
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: Listenable.merge([_pulse, _sweep]),
          builder: (ctx, _) => CustomPaint(
            painter: _RadialVisualizerPainter(
              samples: _samples,
              state: widget.agent.agentState,
              sweep: _sweep.value,
              pulse: _pulse.value,
              radius: widget.radius,
            ),
          ),
        ),
      );
}

class _RadialVisualizerPainter extends CustomPainter {
  const _RadialVisualizerPainter({
    required this.samples,
    required this.state,
    required this.sweep,
    required this.pulse,
    required this.radius,
  });

  final List<double> samples;
  final sdk.AgentState? state;
  final double sweep;
  final double pulse;
  final double radius;

  /// Bar lengths expressed as a fraction of [radius] (6/110 and 46/110 in the
  /// web HUD) so the ring keeps its proportions at any size.
  double get _minBar => radius * 0.055;
  double get _maxBar => radius * 0.42;

  @override
  void paint(Canvas canvas, Size size) {
    final count = samples.length;
    if (count == 0) return;

    final center = Offset(size.width / 2, size.height / 2);
    final step = (2 * math.pi) / count;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = (radius * 0.027).clamp(1.5, 3.0);

    for (var i = 0; i < count; i++) {
      final sample = samples[i].clamp(0.0, 1.0);
      final angle = -math.pi / 2 + i * step;
      final direction = Offset(math.cos(angle), math.sin(angle));

      final double length;
      final double alpha;

      if (state == sdk.AgentState.thinking) {
        final active = (sweep * count).floor() % count;
        final distance = (i - active).abs() % count;
        final strength = (1 - distance / (count / 4)).clamp(0.0, 1.0);
        length = _minBar + strength * (_maxBar - _minBar);
        alpha = 0.12 + strength * 0.88;
      } else if (state == sdk.AgentState.speaking) {
        length = _minBar + sample * (_maxBar - _minBar);
        alpha = 0.35 + sample * 0.65;
      } else {
        length = _minBar + pulse * 5;
        alpha = 0.16;
      }

      paint.color = HudColors.cyan.withValues(alpha: alpha);
      canvas.drawLine(
        center + direction * radius,
        center + direction * (radius + length),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RadialVisualizerPainter oldDelegate) => true;
}
