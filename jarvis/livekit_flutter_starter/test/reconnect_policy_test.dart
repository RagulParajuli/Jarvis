import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/support/reconnect_policy.dart';

/// Automatic reconnection must be bounded and paced.
///
/// A link that stays down should not turn into an endless request loop, and a
/// link that comes back should restore the full budget so the next outage is
/// treated as a fresh one.
void main() {
  group('reconnect policy', () {
    test('allows exactly three automatic attempts, then gives up', () {
      final policy = ReconnectPolicy();

      expect(policy.takeAttempt(), isNotNull);
      expect(policy.takeAttempt(), isNotNull);
      expect(policy.takeAttempt(), isNotNull);

      expect(policy.exhausted, isTrue);
      expect(policy.attempts, 3);
      expect(policy.takeAttempt(), isNull);
    });

    test('waits longer after every failure', () {
      final policy = ReconnectPolicy();

      expect(policy.takeAttempt(), const Duration(seconds: 2));
      expect(policy.takeAttempt(), const Duration(seconds: 4));
      expect(policy.takeAttempt(), const Duration(seconds: 8));
    });

    test('a single wait never exceeds the cap', () {
      final policy = ReconnectPolicy(
          maxAttempts: 5, baseDelay: const Duration(seconds: 10), maxDelay: const Duration(seconds: 25));

      expect(policy.takeAttempt(), const Duration(seconds: 10));
      expect(policy.takeAttempt(), const Duration(seconds: 20));
      expect(policy.takeAttempt(), const Duration(seconds: 25));
      expect(policy.takeAttempt(), const Duration(seconds: 25));
      expect(policy.takeAttempt(), const Duration(seconds: 25));
      expect(policy.takeAttempt(), isNull);
    });

    test('a successful connection restores the whole budget', () {
      final policy = ReconnectPolicy();
      policy.takeAttempt();
      policy.takeAttempt();
      policy.takeAttempt();
      expect(policy.exhausted, isTrue);

      policy.reset();

      expect(policy.exhausted, isFalse);
      expect(policy.attempts, 0);
      expect(policy.takeAttempt(), const Duration(seconds: 2));
    });

    test('a rejected code stops retries immediately, even mid-budget', () {
      final policy = ReconnectPolicy();
      expect(policy.takeAttempt(), isNotNull);

      policy.stop();

      expect(policy.exhausted, isTrue);
      expect(policy.takeAttempt(), isNull);
    });

    test('stays exhausted once the budget is spent', () {
      final policy = ReconnectPolicy()..stop();

      expect(policy.takeAttempt(), isNull);
      expect(policy.takeAttempt(), isNull);
      expect(policy.exhausted, isTrue);
    });
  });
}
