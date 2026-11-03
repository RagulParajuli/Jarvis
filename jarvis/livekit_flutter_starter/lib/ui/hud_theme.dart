import 'package:flutter/material.dart';

/// Palette lifted from the web frontend's `styles/globals.css` (`--hud-*`).
abstract final class HudColors {
  static const bg = Color(0xFF06090D);
  static const surface = Color(0xFF0B1119);
  static const cyan = Color(0xFF00E5FF);
  static const cyanDim = Color(0x2600E5FF);
  static const cyanGlow = Color(0x5900E5FF);
  static const amber = Color(0xFFFFB300);
  static const red = Color(0xFFFF3B3B);
  static const border = Color(0x3800E5FF);
  static const text = Color(0xFFB0E4F0);
  static const textDim = Color(0x73B0E4F0);

  static const fontFamily = 'CommitMono';

  /// `text-shadow: 0 0 8px var(--hud-cyan-glow), 0 0 20px rgba(0,229,255,.15)`
  static const glowShadows = <Shadow>[
    Shadow(color: cyanGlow, blurRadius: 8),
    Shadow(color: Color(0x2600E5FF), blurRadius: 20),
  ];
}

/// Text styles mirroring the `.hud-label`, `.hud-glow` and monospace helpers.
abstract final class HudText {
  /// Small uppercase tracking label (`.hud-label`).
  static const label = TextStyle(
    fontFamily: HudColors.fontFamily,
    fontSize: 10,
    height: 1.2,
    letterSpacing: 1.8,
    color: HudColors.textDim,
  );

  static const mono = TextStyle(
    fontFamily: HudColors.fontFamily,
    fontSize: 12,
    height: 1.4,
    color: HudColors.textDim,
  );

  static const monoSmall = TextStyle(
    fontFamily: HudColors.fontFamily,
    fontSize: 11,
    height: 1.4,
    color: HudColors.textDim,
  );

  /// Cyan emissive heading (`.hud-glow`).
  static const glow = TextStyle(
    fontFamily: HudColors.fontFamily,
    fontWeight: FontWeight.w700,
    color: HudColors.cyan,
    shadows: HudColors.glowShadows,
  );
}

/// `background-image: linear-gradient(...)` grid, 40px cells (`.hud-grid-bg`).
class HudGridBackground extends StatelessWidget {
  const HudGridBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: HudColors.bg,
        child: CustomPaint(
          painter: const _HudGridPainter(),
          child: child,
        ),
      );
}

class _HudGridPainter extends CustomPainter {
  const _HudGridPainter();

  static const _cell = 40.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = HudColors.border
      ..strokeWidth = 1;

    for (var x = 0.0; x <= size.width; x += _cell) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y <= size.height; y += _cell) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _HudGridPainter oldDelegate) => false;
}

/// 45° chamfered rectangle used by `.hud-panel` and the HUD buttons.
class HudChamferClipper extends CustomClipper<Path> {
  const HudChamferClipper({this.cut = 12});

  final double cut;

  @override
  Path getClip(Size size) => chamferPath(size, cut);

  @override
  bool shouldReclip(covariant HudChamferClipper oldClipper) => oldClipper.cut != cut;
}

Path chamferPath(Size size, double cut) => Path()
  ..moveTo(cut, 0)
  ..lineTo(size.width - cut, 0)
  ..lineTo(size.width, cut)
  ..lineTo(size.width, size.height - cut)
  ..lineTo(size.width - cut, size.height)
  ..lineTo(cut, size.height)
  ..lineTo(0, size.height - cut)
  ..lineTo(0, cut)
  ..close();

/// Hairline chamfered panel with corner brackets (`.hud-panel`).
class HudPanel extends StatelessWidget {
  const HudPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.fill = HudColors.surface,
    this.borderColor = HudColors.border,
    this.cut = 12,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color fill;
  final Color borderColor;
  final double cut;

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _HudPanelPainter(
          fill: fill,
          borderColor: borderColor,
          cut: cut,
        ),
        child: Padding(padding: padding, child: child),
      );
}

class _HudPanelPainter extends CustomPainter {
  const _HudPanelPainter({
    required this.fill,
    required this.borderColor,
    required this.cut,
  });

  final Color fill;
  final Color borderColor;
  final double cut;

  @override
  void paint(Canvas canvas, Size size) {
    final path = chamferPath(size, cut);
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    // `.hud-panel::before` / `::after` brackets.
    final bracket = Paint()
      ..color = HudColors.cyan.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    const inset = 4.0;
    const arm = 10.0;

    canvas.drawPath(
      Path()
        ..moveTo(inset, inset + arm)
        ..lineTo(inset, inset)
        ..lineTo(inset + arm, inset),
      bracket,
    );
    canvas.drawPath(
      Path()
        ..moveTo(size.width - inset - arm, size.height - inset)
        ..lineTo(size.width - inset, size.height - inset)
        ..lineTo(size.width - inset, size.height - inset - arm),
      bracket,
    );
  }

  @override
  bool shouldRepaint(covariant _HudPanelPainter oldDelegate) =>
      oldDelegate.fill != fill || oldDelegate.borderColor != borderColor || oldDelegate.cut != cut;
}

/// Four-corner HUD bracket decoration.
class HudCornerBrackets extends StatelessWidget {
  const HudCornerBrackets({
    super.key,
    this.inset = 8,
    this.arm = 12,
    this.color = HudColors.cyan,
  });

  final double inset;
  final double arm;
  final Color color;

  @override
  Widget build(BuildContext context) => Positioned.fill(
        child: IgnorePointer(
          child: CustomPaint(
            painter: _HudBracketsPainter(inset: inset, arm: arm, color: color),
          ),
        ),
      );
}

class _HudBracketsPainter extends CustomPainter {
  const _HudBracketsPainter({
    required this.inset,
    required this.arm,
    required this.color,
  });

  final double inset;
  final double arm;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final right = size.width - inset;
    final bottom = size.height - inset;

    canvas.drawPath(
      Path()
        ..moveTo(inset, inset + arm)
        ..lineTo(inset, inset)
        ..lineTo(inset + arm, inset),
      paint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(right - arm, inset)
        ..lineTo(right, inset)
        ..lineTo(right, inset + arm),
      paint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(inset, bottom - arm)
        ..lineTo(inset, bottom)
        ..lineTo(inset + arm, bottom),
      paint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(right - arm, bottom)
        ..lineTo(right, bottom)
        ..lineTo(right, bottom - arm),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _HudBracketsPainter oldDelegate) =>
      oldDelegate.inset != inset || oldDelegate.arm != arm || oldDelegate.color != color;
}

/// Uppercase, letter-spaced HUD label.
class HudLabel extends StatelessWidget {
  const HudLabel(
    this.text, {
    super.key,
    this.color = HudColors.textDim,
    this.glow = false,
    this.style,
    this.textAlign,
  });

  final String text;
  final Color color;
  final bool glow;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        textAlign: textAlign,
        style: (style ?? HudText.label).copyWith(
          color: color,
          shadows: glow
              ? [Shadow(color: color.withValues(alpha: 0.45), blurRadius: 12)]
              : null,
        ),
      );
}

/// Chamfered HUD button with an optional filled state.
class HudButton extends StatelessWidget {
  const HudButton({
    super.key,
    required this.label,
    this.onPressed,
    this.filled = false,
    this.color = HudColors.cyan,
    this.cut = 8,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool filled;
  final Color color;
  final double cut;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final foreground = filled ? HudColors.bg : color;

    return Opacity(
      opacity: enabled ? 1 : 0.3,
      child: GestureDetector(
        onTap: onPressed,
        child: ClipPath(
          clipper: HudChamferClipper(cut: cut),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
            decoration: BoxDecoration(
              color: filled ? color : Colors.transparent,
              border: Border.all(color: color),
              boxShadow: filled
                  ? [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 20)]
                  : null,
            ),
            child: Text(
              label.toUpperCase(),
              style: HudText.label.copyWith(
                color: foreground,
                fontWeight: FontWeight.w700,
                letterSpacing: 4.8,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Thin HUD-style square icon button used by the session control bar.
class HudIconButton extends StatelessWidget {
  const HudIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.active = false,
    this.color = HudColors.cyan,
    this.size = 44,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final bool active;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onPressed,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: active ? color.withValues(alpha: 0.15) : HudColors.surface,
            border: Border.all(color: active ? color : HudColors.border),
          ),
          child: Icon(icon, size: size * 0.45, color: active ? color : HudColors.textDim),
        ),
      );
}
