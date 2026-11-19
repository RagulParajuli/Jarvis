/// Decides whether, and how soon, an automatic reconnect may be attempted.
///
/// Automatic retries are bounded on purpose: a network that stays down must
/// not turn into an endless request loop. Backoff grows with every failure so
/// a recovering link is not hammered.
///
/// A rejected credential is deliberately not handled here. The caller must
/// never schedule a retry for one, because every retry would get the same
/// answer.
class ReconnectPolicy {
  ReconnectPolicy({
    this.maxAttempts = 3,
    this.baseDelay = const Duration(seconds: 2),
    this.maxDelay = const Duration(seconds: 30),
  });

  /// Consecutive automatic retries allowed before the caller gives up.
  final int maxAttempts;

  /// Wait before the first retry. Each later retry doubles it.
  final Duration baseDelay;

  /// Upper bound for a single wait, so growth stays predictable.
  final Duration maxDelay;

  int _attempts = 0;

  /// Automatic retries used since the last [reset].
  int get attempts => _attempts;

  /// True when no further automatic retry may be scheduled.
  bool get exhausted => _attempts >= maxAttempts;

  /// Reserves the next retry and returns how long to wait.
  ///
  /// Returns `null` once the budget is spent, which is the caller's signal to
  /// stop retrying on its own.
  Duration? takeAttempt() {
    if (exhausted) return null;

    _attempts++;
    final millis = baseDelay.inMilliseconds * (1 << (_attempts - 1));
    return Duration(milliseconds: millis < maxDelay.inMilliseconds ? millis : maxDelay.inMilliseconds);
  }

  /// Restores the full budget, called after a connection succeeds.
  void reset() => _attempts = 0;

  /// Ends automatic retries immediately, called when the server rejects the
  /// access code.
  void stop() => _attempts = maxAttempts;
}
