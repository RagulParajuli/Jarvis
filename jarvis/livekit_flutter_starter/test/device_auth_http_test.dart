import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jarvis/support/device_auth.dart';
import 'package:jarvis/support/device_bridge.dart';

/// The HTTP contract is security-sensitive: a stray access-code header on a
/// challenge would leak a credential, and an accepted server audience would
/// let a signature be replayed elsewhere. These tests pin the exact requests
/// and the typed mapping of every refusal.
void main() {
  const baseUrl = 'https://jarvis.test';
  const accessCode = 'super-secret-access-code';
  const pairingCode = '0123456789abcdef-ABCDEF_ghijklmn';
  const challengeNonce = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef';
  const expiresAt = '2030-01-01T00:02:00.000Z';
  const label = 'Jarvis Phone';

  const identity = DeviceIdentity(
    deviceId: '3f2504e0-4f89-41d3-9a0c-0305e82c3301',
    publicKey: 'AQIDBA==',
    fingerprint: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  );

  final requests = <http.Request>[];

  MockClient mock(http.Response Function(http.Request request) respond) => MockClient((request) async {
        requests.add(request);
        return respond(request);
      });

  DeviceAuthClient clientFor(http.Client client, {Duration? timeout}) => DeviceAuthClient(
        baseUrl: baseUrl,
        client: client,
        timeout: timeout ?? const Duration(seconds: 5),
      );

  http.Response jsonResponse(int status, Object body) => http.Response(
        jsonEncode(body),
        status,
        headers: const {'content-type': 'application/json'},
      );

  Matcher failureIs(DeviceAuthFailure failure) =>
      isA<DeviceAuthException>().having((error) => error.failure, 'failure', failure);

  setUp(() => requests.clear());

  group('pairing code issuance', () {
    test('sends only the access-code header and parses the one-time code', () async {
      final api = clientFor(mock((request) => jsonResponse(200, {'code': pairingCode, 'expires_at': expiresAt})));

      final issued = await api.issuePairingCode(accessCode);

      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), '$baseUrl/api/device/pairing');
      expect(request.headers['x-jarvis-access-code'], accessCode);
      expect(request.headers['content-type'], 'application/json');
      expect(jsonDecode(request.body), isEmpty);
      expect(issued.code, pairingCode);
      expect(issued.expiresAt.toUtc().toIso8601String(), expiresAt);
    });

    test('rejects malformed success bodies', () async {
      for (final body in <Object>[
        {'code': 'short', 'expires_at': expiresAt},
        {'code': pairingCode, 'expires_at': 'tomorrow'},
        {'code': pairingCode, 'expires_at': '2020-01-01T00:00:00.000Z'},
        {'code': pairingCode},
        {'code': 42, 'expires_at': expiresAt},
      ]) {
        final api = clientFor(mock((request) => jsonResponse(200, body)));
        await expectLater(
          api.issuePairingCode(accessCode),
          throwsA(failureIs(DeviceAuthFailure.malformedResponse)),
        );
      }

      final nonJson = clientFor(mock((request) => http.Response('not json', 200)));
      await expectLater(
        nonJson.issuePairingCode(accessCode),
        throwsA(failureIs(DeviceAuthFailure.malformedResponse)),
      );
    });

    test('maps refusals to typed failures without leaking the access code', () async {
      for (final entry in <int, DeviceAuthFailure>{
        401: DeviceAuthFailure.unauthorized,
        403: DeviceAuthFailure.unauthorized,
        429: DeviceAuthFailure.rateLimited,
        500: DeviceAuthFailure.serverUnavailable,
        400: DeviceAuthFailure.malformedResponse,
        404: DeviceAuthFailure.endpointUnavailable,
      }.entries) {
        final api = clientFor(mock((request) => jsonResponse(entry.key, {'error': accessCode})));
        try {
          await api.issuePairingCode(accessCode);
          fail('expected a typed failure for status ${entry.key}');
        } on DeviceAuthException catch (error) {
          expect(error.failure, entry.value);
          expect(error.toString().contains(accessCode), isFalse);
        }
      }
    });

    test('maps transport failure and timeout to networkFailure', () async {
      final failing = clientFor(mock((request) => throw http.ClientException('detail $accessCode')));
      await expectLater(
        failing.issuePairingCode(accessCode),
        throwsA(failureIs(DeviceAuthFailure.networkFailure)),
      );

      final slow = clientFor(
        MockClient((request) => Completer<http.Response>().future),
        timeout: const Duration(milliseconds: 5),
      );
      await expectLater(
        slow.issuePairingCode(accessCode),
        throwsA(failureIs(DeviceAuthFailure.networkFailure)),
      );
    });
  });

  group('pairing redemption', () {
    test('sends exactly the six required fields and checks the paired device id', () async {
      final api = clientFor(
        mock((request) => jsonResponse(200, {'status': 'paired', 'device_id': identity.deviceId})),
      );

      final paired = await api.redeemPairingCode(code: pairingCode, identity: identity, label: label);

      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), '$baseUrl/api/device/pairing/redeem');
      expect(request.headers.containsKey('x-jarvis-access-code'), isFalse);
      expect(jsonDecode(request.body), <String, Object?>{
        'code': pairingCode,
        'device_id': identity.deviceId,
        'public_key': identity.publicKey,
        'fingerprint': identity.fingerprint,
        'platform': 'android',
        'label': label,
      });
      expect(paired.deviceId, identity.deviceId);
    });

    test('a wrong or mismatched paired response is malformed', () async {
      for (final body in <Object>[
        {'status': 'paired', 'device_id': '11111111-1111-4111-8111-111111111111'},
        {'status': 'used', 'device_id': identity.deviceId},
        {'status': 'paired'},
        {'device_id': identity.deviceId},
      ]) {
        final api = clientFor(mock((request) => jsonResponse(200, body)));
        await expectLater(
          api.redeemPairingCode(code: pairingCode, identity: identity, label: label),
          throwsA(failureIs(DeviceAuthFailure.malformedResponse)),
        );
      }
    });

    test('maps conflict, invalid code, rate limit and outage, with no retry', () async {
      for (final entry in <int, DeviceAuthFailure>{
        401: DeviceAuthFailure.invalidCode,
        409: DeviceAuthFailure.conflict,
        429: DeviceAuthFailure.rateLimited,
        503: DeviceAuthFailure.serverUnavailable,
        404: DeviceAuthFailure.endpointUnavailable,
      }.entries) {
        requests.clear();
        final api = clientFor(mock((request) => jsonResponse(entry.key, {'error': pairingCode})));
        try {
          await api.redeemPairingCode(code: pairingCode, identity: identity, label: label);
          fail('expected a typed failure for status ${entry.key}');
        } on DeviceAuthException catch (error) {
          expect(error.failure, entry.value);
          expect(error.toString().contains(pairingCode), isFalse);
        }
        expect(requests, hasLength(1));
      }
    });
  });

  group('challenge issuance', () {
    MockClient successClient() => mock((request) => jsonResponse(200, {
          'challenge': challengeNonce,
          'audience': deviceAssertionAudience,
          'expires_at': expiresAt,
        }));

    test('sends only device_id, with no access-code header', () async {
      final api = clientFor(successClient());

      final challenge = await api.requestChallenge(identity.deviceId);

      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), '$baseUrl/api/device/challenge');
      expect(request.headers.keys.map((key) => key.toLowerCase()), isNot(contains('x-jarvis-access-code')));
      expect(jsonDecode(request.body), <String, Object?>{'device_id': identity.deviceId});
      expect(challenge.challenge, challengeNonce);
      expect(challenge.audience, 'jarvis-token-api-v1');
      expect(challenge.expiresAt.toUtc().toIso8601String(), expiresAt);
    });

    test('honours a base URL with a path prefix', () async {
      final api = DeviceAuthClient(
        baseUrl: 'https://jarvis.test/app/',
        client: successClient(),
      );

      await api.requestChallenge(identity.deviceId);

      expect(requests.single.url.toString(), 'https://jarvis.test/app/api/device/challenge');
    });

    test('refuses any server-provided audience other than the fixed one', () async {
      for (final audience in <String>['jarvis-token-api-v2', 'JARVIS-TOKEN-API-V1', 'jarvis-token-api-v1\n', '']) {
        final api = clientFor(mock((request) => jsonResponse(200, {
              'challenge': challengeNonce,
              'audience': audience,
              'expires_at': expiresAt,
            })));
        await expectLater(
          api.requestChallenge(identity.deviceId),
          throwsA(failureIs(DeviceAuthFailure.malformedResponse)),
        );
      }
    });

    test('rejects malformed challenges and expiry', () async {
      for (final body in <Object>[
        {'challenge': 'short', 'audience': deviceAssertionAudience, 'expires_at': expiresAt},
        {'challenge': challengeNonce, 'audience': deviceAssertionAudience, 'expires_at': 'soon'},
        {'challenge': challengeNonce, 'audience': deviceAssertionAudience, 'expires_at': '2020-01-01T00:00:00Z'},
        {'challenge': challengeNonce, 'audience': deviceAssertionAudience},
        {'challenge': 42, 'audience': deviceAssertionAudience, 'expires_at': expiresAt},
      ]) {
        final api = clientFor(mock((request) => jsonResponse(200, body)));
        await expectLater(
          api.requestChallenge(identity.deviceId),
          throwsA(failureIs(DeviceAuthFailure.malformedResponse)),
        );
      }
    });

    test('maps refusal, rate limit and outage, with no retry', () async {
      for (final entry in <int, DeviceAuthFailure>{
        400: DeviceAuthFailure.deviceRejected,
        429: DeviceAuthFailure.rateLimited,
        502: DeviceAuthFailure.serverUnavailable,
        404: DeviceAuthFailure.endpointUnavailable,
      }.entries) {
        requests.clear();
        final api = clientFor(mock((request) => jsonResponse(entry.key, {'error': challengeNonce})));
        try {
          await api.requestChallenge(identity.deviceId);
          fail('expected a typed failure for status ${entry.key}');
        } on DeviceAuthException catch (error) {
          expect(error.failure, entry.value);
          expect(error.toString().contains(challengeNonce), isFalse);
        }
        expect(requests, hasLength(1));
      }
    });

    test('an invalid local device id is rejected before any request', () async {
      final api = clientFor(successClient());

      await expectLater(api.requestChallenge('not-a-uuid'), throwsA(isA<ArgumentError>()));
      expect(requests, isEmpty);
    });

    test('a network failure never exposes the challenge', () async {
      final api = clientFor(mock((request) => throw http.ClientException('detail $challengeNonce')));

      await expectLater(
        api.requestChallenge(identity.deviceId),
        throwsA(failureIs(DeviceAuthFailure.networkFailure)),
      );
    });
  });

  test('a missing route records its stage and is not a malformed response', () async {
    const cases = <String, DeviceAuthStage>{
      '/api/device/pairing': DeviceAuthStage.issue,
      '/api/device/pairing/redeem': DeviceAuthStage.redeem,
      '/api/device/challenge': DeviceAuthStage.challenge,
    };
    for (final entry in cases.entries) {
      requests.clear();
      final api = clientFor(mock((request) => jsonResponse(404, {'error': 'NOT_FOUND'})));
      try {
        switch (entry.key) {
          case '/api/device/pairing':
            await api.issuePairingCode(accessCode);
          case '/api/device/pairing/redeem':
            await api.redeemPairingCode(code: pairingCode, identity: identity, label: label);
          case '/api/device/challenge':
            await api.requestChallenge(identity.deviceId);
        }
        fail('expected a typed failure for ${entry.key}');
      } on DeviceAuthException catch (error) {
        expect(error.failure, DeviceAuthFailure.endpointUnavailable, reason: entry.key);
        expect(error.stage, entry.value, reason: entry.key);
        expect(error.message, isNot('The service returned an unexpected response.'));
        expect(error.toString(), isNot(contains(accessCode)));
        expect(error.toString(), isNot(contains(pairingCode)));
      }
      expect(requests, hasLength(1));
    }
  });
}
