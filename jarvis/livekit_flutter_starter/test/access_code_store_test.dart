import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/support/access_code_store.dart';

/// The access code is only useful if the stored copy is known-good.
///
/// These checks pin the ordering that matters: the server is asked first, and
/// storage is written only after it says yes.
void main() {
  group('access code lifecycle', () {
    late String? stored;
    late List<String> events;

    setUp(() {
      stored = null;
      events = <String>[];
    });

    AccessCodeStore storeWith(AccessCodeStatus Function(String code) verdict) => AccessCodeStore(
          verify: (code) async {
            events.add('verify');
            return verdict(code);
          },
          read: () async => stored,
          save: (code) async {
            events.add('save');
            stored = code;
          },
          clear: () async {
            events.add('clear');
            stored = null;
          },
        );

    test('a rejected code is never persisted', () async {
      final store = storeWith((_) => AccessCodeStatus.rejected);

      final status = await store.approve('wrong-code');

      expect(status, AccessCodeStatus.rejected);
      expect(events, ['verify']);
      expect(stored, isNull);
    });

    test('a verified code is persisted, and only after the check', () async {
      final store = storeWith((_) => AccessCodeStatus.verified);

      final status = await store.approve('correct-code');

      expect(status, AccessCodeStatus.verified);
      expect(events, ['verify', 'save']);
      expect(stored, 'correct-code');
    });

    test('a failed check does not overwrite the previously saved code', () async {
      stored = 'known-good';
      final store = storeWith((_) => AccessCodeStatus.rejected);

      await store.approve('typo');

      expect(stored, 'known-good');
      expect(events, isNot(contains('save')));
    });

    test('an unreachable check does not overwrite the previously saved code', () async {
      stored = 'known-good';
      final store = storeWith((_) => AccessCodeStatus.unreachable);

      final status = await store.approve('candidate');

      expect(status, AccessCodeStatus.unreachable);
      expect(stored, 'known-good');
      expect(events, isNot(contains('save')));
    });

    test('a check that cannot run is treated as unreachable and saves nothing', () async {
      stored = 'known-good';
      final store = AccessCodeStore(
        verify: (_) async => throw StateError('socket closed'),
        read: () async => stored,
        save: (code) async {
          events.add('save');
          stored = code;
        },
        clear: () async {
          events.add('clear');
          stored = null;
        },
      );

      final status = await store.approve('candidate');

      expect(status, AccessCodeStatus.unreachable);
      expect(stored, 'known-good');
      expect(events, isNot(contains('save')));
    });

    test('a rejected saved code is cleared from storage', () async {
      stored = 'revoked-code';
      final store = storeWith((_) => AccessCodeStatus.verified);

      await store.forgetRejected();

      expect(stored, isNull);
      expect(events, ['clear']);
    });

    test('a code saved at launch is restored without asking again', () async {
      final first = storeWith((_) => AccessCodeStatus.verified);
      await first.approve('correct-code');

      // A later launch builds a fresh store over the same storage.
      final restored = await storeWith((_) => AccessCodeStatus.verified).restore();

      expect(restored, 'correct-code');
    });

    test('nothing is restored when no code was ever saved', () async {
      final restored = await storeWith((_) => AccessCodeStatus.verified).restore();

      expect(restored, isNull);
    });
  });

  group('token endpoint status handling', () {
    test('401 and 403 reject the code', () {
      expect(statusForHttpResponse(401), AccessCodeStatus.rejected);
      expect(statusForHttpResponse(403), AccessCodeStatus.rejected);
    });

    test('other statuses are treated as unreachable, not as a verdict', () {
      expect(statusForHttpResponse(400), AccessCodeStatus.unreachable);
      expect(statusForHttpResponse(429), AccessCodeStatus.unreachable);
      expect(statusForHttpResponse(500), AccessCodeStatus.unreachable);
      expect(statusForHttpResponse(503), AccessCodeStatus.unreachable);
    });
  });

  group('access code submission', () {
    test('a duplicate submission while a check runs is ignored', () async {
      final submission = AccessCodeSubmission();
      final gate = Completer<void>();
      var checks = 0;

      final first = submission.run(() async {
        checks++;
        await gate.future;
        return AccessCodeStatus.verified;
      });

      expect(submission.isRunning, isTrue);

      final duplicate = await submission.run(() async {
        checks++;
        return AccessCodeStatus.rejected;
      });

      expect(duplicate, isNull);
      expect(checks, 1);
      expect(submission.isRunning, isTrue);

      gate.complete();
      expect(await first, AccessCodeStatus.verified);
      expect(checks, 1);
      expect(submission.isRunning, isFalse);
    });

    test('a later submission is accepted once the first one finishes', () async {
      final submission = AccessCodeSubmission();

      await submission.run(() async => AccessCodeStatus.rejected);
      final second = await submission.run(() async => AccessCodeStatus.verified);

      expect(second, AccessCodeStatus.verified);
      expect(submission.isRunning, isFalse);
    });

    test('a corrected code can authenticate after a rejection', () async {
      var stored = <String>[];
      final store = AccessCodeStore(
        verify: (code) async => code == 'correct-code' ? AccessCodeStatus.verified : AccessCodeStatus.rejected,
        read: () async => stored.isEmpty ? null : stored.first,
        save: (code) async => stored = [code],
        clear: () async => stored = [],
      );
      final submission = AccessCodeSubmission();

      expect(await submission.run(() => store.approve('wrong-code')), AccessCodeStatus.rejected);
      expect(stored, isEmpty);

      expect(await submission.run(() => store.approve('correct-code')), AccessCodeStatus.verified);
      expect(stored, ['correct-code']);
    });

    test('a throwing check reports unreachable and releases the gate', () async {
      final submission = AccessCodeSubmission();

      final status = await submission.run(() async => throw StateError('socket closed'));

      expect(status, AccessCodeStatus.unreachable);
      expect(submission.isRunning, isFalse);
      expect(await submission.run(() async => AccessCodeStatus.verified), AccessCodeStatus.verified);
    });
  });
}
