import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jarvis/support/device_auth.dart';
import 'package:jarvis/support/device_bridge.dart';
import 'package:jarvis/support/device_token_source.dart';
import 'package:livekit_client/livekit_client.dart' as sdk;

/// The token source must add a signed assertion to the existing request shape,
/// without ever reaching for the access code. These tests pin the flow and the
/// typed, secret-free failures.
void main() {
  const baseUrl = 'https://jarvis.test';
  const deviceId = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
  const nonce = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef';
  const signature = 'MEQCIA==';
  const issuedAtMs = 1700000000123;
  const expiresAt = '2030-01-01T00:02:00.000Z';
  const serverUrl = 'wss://jarvis.test/livekit';
  const participantToken = 'a-participant-jwt';

  const identity = DeviceIdentity(
    deviceId: deviceId,
    publicKey: 'AQIDBA==',
    fingerprint: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  );

  const options = sdk.TokenRequestOptions(
    roomName: 'jarvis_room',
    participantName: 'user',
    participantIdentity: 'jarvis_user',
    agentName: 'my-agent',
  );

  const credentials = <String, String>{
    'server_url': serverUrl,
    'participant_token': participantToken,
    'participant_name': 'user',
    'room_name': 'jarvis_room',
  };

  final challengeRequests = <http.Request>[];
  final tokenRequests = <http.Request>[];

  http.Response jsonResponse(int status, Object body) => http.Response(
        jsonEncode(body),
        status,
        headers: const {'content-type': 'application/json'},
      );

  DeviceAuthClient authClient({int status = 200, Object? body}) => DeviceAuthClient(
        baseUrl: baseUrl,
        client: MockClient((request) async {
          challengeRequests.add(request);
          return jsonResponse(
            status,
            body ??
                <String, String>{
                  'challenge': nonce,
                  'audience': deviceAssertionAudience,
                  'expires_at': expiresAt,
                },
          );
        }),
      );

  DeviceTokenSource sourceWith(
    http.Client tokenClient, {
    DeviceAuthClient? auth,
    DeviceIdentityReader? reader,
    DeviceAssertionSigner? signer,
    DeviceClockMs? clock,
  }) =>
      DeviceTokenSource(
        tokenEndpoint: Uri.parse('$baseUrl/api/token'),
        deviceClient: auth ?? authClient(),
        httpClient: tokenClient,
        readIdentity: reader ?? () async => identity,
        signAssertion: signer ?? (_) async => signature,
        nowMs: clock ?? () => issuedAtMs,
      );

  MockClient tokenClient({int status = 200, Object? body}) => MockClient((request) async {
        tokenRequests.add(request);
        return jsonResponse(status, body ?? credentials);
      });

  Matcher failureIs(DeviceTokenFailure failure) =>
      isA<DeviceTokenException>().having((error) => error.failure, 'failure', failure);

  setUp(() {
    challengeRequests.clear();
    tokenRequests.clear();
  });

  test('signs the exact payload and submits one assertion-only token request', () async {
    String? signedPayload;
    final source = sourceWith(
      tokenClient(),
      signer: (payload) async {
        signedPayload = payload;
        return signature;
      },
    );

    final result = await source.fetch(options);

    expect(challengeRequests, hasLength(1));
    expect(challengeRequests.single.url.path, '/api/device/challenge');
    expect(
      signedPayload,
      'jarvis-device-assertion-v1\n$deviceId\n$nonce\n$issuedAtMs\n$deviceAssertionAudience',
    );

    expect(tokenRequests, hasLength(1));
    final request = tokenRequests.single;
    expect(request.method, 'POST');
    expect(request.url.toString(), '$baseUrl/api/token');
    expect(
      request.headers.keys.map((key) => key.toLowerCase()),
      isNot(contains('x-jarvis-access-code')),
    );
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    expect(body['device_assertion'], <String, Object?>{
      'device_id': deviceId,
      'nonce': nonce,
      'issued_at_ms': issuedAtMs,
      'signature': signature,
    });
    expect(body.containsKey('access_code'), isFalse);

    expect(result.serverUrl, serverUrl);
    expect(result.participantToken, participantToken);
    expect(result.roomName, 'jarvis_room');
  });

  test('keeps the standard token request fields and adds only the assertion', () async {
    final source = sourceWith(tokenClient());

    await source.fetch(options);

    final body = jsonDecode(tokenRequests.single.body) as Map<String, dynamic>;
    expect(body['room_name'], 'jarvis_room');
    expect(body['participant_name'], 'user');
    expect(body['participant_identity'], 'jarvis_user');
    expect(body['room_config'], <String, Object?>{
      'agents': [
        {'agent_name': 'my-agent'}
      ]
    });
    expect(
      body.keys.toSet(),
      <String>{'room_name', 'participant_name', 'participant_identity', 'room_config', 'device_assertion'},
    );
  });

  test('a signing failure stops before the token request', () async {
    final source = sourceWith(tokenClient(), signer: (_) async => null);

    try {
      await source.fetch(options);
      fail('expected a signing failure');
    } on DeviceTokenException catch (error) {
      expect(error.failure, DeviceTokenFailure.signFailed);
      expect(error.toString().contains(nonce), isFalse);
    }
    expect(tokenRequests, isEmpty);
  });

  test('a challenge failure is typed and stops before the token request', () async {
    final source = sourceWith(
      tokenClient(),
      auth: authClient(status: 400, body: {'error': nonce}),
    );

    try {
      await source.fetch(options);
      fail('expected a challenge failure');
    } on DeviceTokenException catch (error) {
      expect(error.failure, DeviceTokenFailure.challengeFailed);
      expect(error.authFailure, DeviceAuthFailure.deviceRejected);
      expect(error.toString().contains(nonce), isFalse);
    }
    expect(tokenRequests, isEmpty);
  });

  test('a rejected assertion never triggers an access-code fallback', () async {
    final source = sourceWith(
      tokenClient(status: 401, body: {'error': 'Access code is missing or incorrect.'}),
    );

    try {
      await source.fetch(options);
      fail('expected the assertion to be rejected');
    } on DeviceTokenException catch (error) {
      expect(error.failure, DeviceTokenFailure.rejected);
      expect(error.toString().contains(signature), isFalse);
      expect(error.toString().contains(participantToken), isFalse);
    }

    // Exactly one attempt: no second request carrying an access code.
    expect(tokenRequests, hasLength(1));
    expect(
      tokenRequests.single.headers.keys.map((key) => key.toLowerCase()),
      isNot(contains('x-jarvis-access-code')),
    );
    expect(jsonDecode(tokenRequests.single.body).containsKey('access_code'), isFalse);
  });

  test('missing identity and malformed token replies are typed', () async {
    final noIdentity = sourceWith(tokenClient(), reader: () async => null);
    await expectLater(noIdentity.fetch(options), throwsA(failureIs(DeviceTokenFailure.noIdentity)));
    expect(challengeRequests, isEmpty);
    expect(tokenRequests, isEmpty);

    for (final body in <Object>[
      {'server_url': serverUrl},
      {'participant_token': participantToken},
      {'server_url': '', 'participant_token': participantToken},
      {'server_url': serverUrl, 'participant_token': participantToken, 'room_name': 42},
    ]) {
      final source = sourceWith(tokenClient(body: body));
      await expectLater(
        source.fetch(options),
        throwsA(failureIs(DeviceTokenFailure.malformedResponse)),
      );
    }

    final nonJson = MockClient((request) async => http.Response('not json', 200));
    await expectLater(
      sourceWith(nonJson).fetch(options),
      throwsA(failureIs(DeviceTokenFailure.malformedResponse)),
    );
  });

  test('rate limit, outage and transport failures are typed without retry', () async {
    for (final entry in <int, DeviceTokenFailure>{
      429: DeviceTokenFailure.rateLimited,
      503: DeviceTokenFailure.serverUnavailable,
      400: DeviceTokenFailure.rejected,
    }.entries) {
      tokenRequests.clear();
      final source = sourceWith(tokenClient(status: entry.key, body: {'error': nonce}));
      try {
        await source.fetch(options);
        fail('expected a typed failure for status ${entry.key}');
      } on DeviceTokenException catch (error) {
        expect(error.failure, entry.value);
        expect(error.toString().contains(nonce), isFalse);
      }
      expect(tokenRequests, hasLength(1));
    }

    final failing = MockClient((request) async => throw http.ClientException('detail $nonce'));
    await expectLater(
      sourceWith(failing).fetch(options),
      throwsA(failureIs(DeviceTokenFailure.networkFailure)),
    );

    final slow = MockClient((request) => Completer<http.Response>().future);
    final timedOut = DeviceTokenSource(
      tokenEndpoint: Uri.parse('$baseUrl/api/token'),
      deviceClient: authClient(),
      httpClient: slow,
      timeout: const Duration(milliseconds: 5),
      readIdentity: () async => identity,
      signAssertion: (_) async => signature,
      nowMs: () => issuedAtMs,
    );
    await expectLater(
      timedOut.fetch(options),
      throwsA(failureIs(DeviceTokenFailure.networkFailure)),
    );
  });
}
