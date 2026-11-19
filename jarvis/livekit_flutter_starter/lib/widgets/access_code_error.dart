import 'package:flutter/material.dart';

import '../ui/hud_theme.dart';

/// The reason the last access-code attempt did not start a session.
///
/// Kept as its own widget so the message the user is asked to act on can be
/// checked without building the whole welcome screen or a LiveKit session.
/// Rendering nothing when there is no message keeps the layout stable as the
/// message appears and is dismissed while the user types.
class AccessCodeError extends StatelessWidget {
  const AccessCodeError({super.key, this.message});

  /// Text to show, or `null`/empty when there is nothing wrong to report.
  final String? message;

  @override
  Widget build(BuildContext context) {
    final text = message;
    if (text == null || text.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: HudText.monoSmall.copyWith(color: HudColors.red),
        ),
      ),
    );
  }
}
