import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jarvis/support/device_auth.dart';
import 'package:jarvis/support/device_auth_flow.dart';
import 'package:jarvis/support/device_bridge.dart';
import 'package:jarvis/support/device_token_source.dart';
import 'package:livekit_client/livekit_client.dart' as sdk;

/// Pairing is the only place the access code is allowed to appear, and a
/// rejected device assertion must never turn back into an access-code login.
/// These tests pin that ordering through the state machine AppCtrl uses.
void main() {
  const baseUrl = 'https://jarvis.test';
  const accessCode = 'super-secret-access-code';
  const pairingCode = '0123456789abcdef-ABCDEF_ghijklmn';
  const expiresAt = '2030-01-01T00:02:00.000Z';

  const identity = DeviceIdentity(
    deviceId: '3f2504e0-4f89-41d3-9a0c-0305e82c3301',
    publicKey: 'AQIDBA==',
    fingerprint: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  );

  final requests = <http.Request>[];
  final trustWrites = <bool>[];

  http.Response jsonResponse(int status, Object body) => http.Response(
        jsonEncode(body),
        status,
        headers: const {'content-type': 'application/json'},
      );

  http.Response pairingSuccess(http.Request request) {
    switch (request.url.path) {
      case '/api/device/pairing':
        return jsonResponse(200, {'code': pairingCode, 'expires_at': expiresAt});
      case '/api/device/pairing/redeem':
        return jsonResponse(200, {'status': 'paired', 'device_id': identity.deviceId});
      default:
        return jsonResponse(404, {'error': 'unknown'});
    }
  }

  DeviceAuthFlow flowFor({
    required http.Response Function(http.Request) respond,
    bool trusted = false,
    DeviceIdentity? deviceIdentity,
    DeviceIdentityReader? readIdentity,
    bool saveTrust = true,
  }) =>
      DeviceAuthFlow(
        deviceClient: DeviceAuthClient(
          baseUrl: baseUrl,
          client: MockClient((request) async {
            requests.add(request);
            return respond(request);
          }),
        ),
        isTrusted: () async => trusted,
        setTrusted: (value) async {
          trustWrites.add(value);
          return saveTrust;
        },
        readIdentity: readIdentity ?? (() async => deviceIdentity ?? identity),
      );

  setUp(() {
    requests.clear();
    trustWrites.clear();
  });

  test('first pairing issues, redeems, then marks the device trusted', () async {
    final flow = flowFor(respond: pairingSuccess);

    await flow.prepare();

    expect(flow.mode, DeviceAuthMode.needsPairing);
    expect(flow.showAccessCodePrompt, isTrue);
    expect(flow.isTrusted, isFalse);

    expect(await flow.pair(accessCode), isTrue);

    expect(flow.mode, DeviceAuthMode.trusted);
    expect(flow.showAccessCodePrompt, isFalse);
    expect(flow.isTrusted, isTrue);
    expect(trustWrites, <bool>[true]);
    expect(requests.map((request) => request.url.path), <String>[
      '/api/device/pairing',
      '/api/device/pairing/redeem',
    ]);
    expect(requests.first.headers['x-jarvis-access-code'], accessCode);
    expect(requests.last.headers.containsKey('x-jarvis-access-code'), isFalse);
    expect(jsonDecode(requests.last.body), <String, Object?>{
      'code': pairingCode,
      'device_id': identity.deviceId,
      'public_key': identity.publicKey,
      'fingerprint': identity.fingerprint,
      'platform': 'android',
      'label': 'Jarvis Android',
    });
  });

  test('trusted startup needs no access-code prompt or pairing request', () async {
    final flow = flowFor(
      trusted: true,
      respond: (request) => fail('a trusted launch must not contact pairing endpoints'),
    );

    await flow.prepare();

    expect(flow.mode, DeviceAuthMode.trusted);
    expect(flow.isTrusted, isTrue);
    expect(flow.showAccessCodePrompt, isFalse);
    expect(flow.isBusy, isFalse);
    expect(requests, isEmpty);
    expect(trustWrites, isEmpty);
  });

  test('pairing failure never marks the device trusted', () async {
    final refused = flowFor(
      respond: (request) => jsonResponse(401, {'error': accessCode}),
    );
    await refused.prepare();

    expect(await refused.pair(accessCode), isFalse);
    expect(refused.mode, DeviceAuthMode.needsPairing);
    expect(trustWrites, isEmpty);
    expect(refused.message, isNotNull);
    expect(refused.message!.contains(accessCode), isFalse);
    expect(requests, hasLength(1));

    requests.clear();
    trustWrites.clear();
    final noKey = flowFor(
      respond: pairingSuccess,
      readIdentity: () async => null,
    );
    await noKey.prepare();

    expect(await noKey.pair(accessCode), isFalse);
    expect(noKey.isTrusted, isFalse);
    expect(trustWrites, isEmpty);
    expect(requests.map((request) => request.url.path), <String>['/api/device/pairing']);

    requests.clear();
    final conflicted = flowFor(
      respond: (request) => request.url.path == '/api/device/pairing'
          ? pairingSuccess(request)
          : jsonResponse(409, {'error': 'already paired'}),
    );
    await conflicted.prepare();

    expect(await conflicted.pair(accessCode), isFalse);
    expect(trustWrites, isEmpty);
    expect(conflicted.isTrusted, isFalse);
  });

  test('a trusted authentication failure requires an explicit re-pairing step', () async {
    final flow = flowFor(respond: pairingSuccess, trusted: true);
    await flow.prepare();

    await flow.reportTrustedFailure(
      const DeviceTokenException(DeviceTokenFailure.rejected),
    );

    expect(flow.mode, DeviceAuthMode.rePairRequired);
    expect(flow.showAccessCodePrompt, isTrue);
    expect(flow.isTrusted, isFalse);
    expect(trustWrites, <bool>[false]);
    expect(flow.message, isNotNull);
    expect(flow.message!.toLowerCase(), contains('access code'));

    // Entering the code again pairs explicitly; it never resumes the rejected
    // assertion path on its own.
    expect(await flow.pair(accessCode), isTrue);
    expect(flow.mode, DeviceAuthMode.trusted);
    expect(trustWrites, <bool>[false, true]);
  });

  test('revoked, missing-key and unsigned devices are terminal failures', () {
    const terminal = <DeviceTokenException>[
      DeviceTokenException(DeviceTokenFailure.noIdentity),
      DeviceTokenException(DeviceTokenFailure.signFailed),
      DeviceTokenException(DeviceTokenFailure.invalidAssertion),
      DeviceTokenException(DeviceTokenFailure.rejected),
      DeviceTokenException(
        DeviceTokenFailure.challengeFailed,
        authFailure: DeviceAuthFailure.deviceRejected,
      ),
    ];
    for (final failure in terminal) {
      expect(DeviceAuthFlow.isTerminalFailure(failure), isTrue, reason: '${failure.failure}');
      final wrapped = DeviceAuthFlow.deviceFailureFrom(sdk.SessionError.connection(failure));
      expect(wrapped, same(failure));
      expect(DeviceAuthFlow.isTerminalFailure(wrapped!), isTrue);
    }
  });

  test('no silent fallback: transient failures stay trusted and unpaired failures stay unpaired', () async {
    final transient = <DeviceTokenException>[
      const DeviceTokenException(DeviceTokenFailure.networkFailure),
      const DeviceTokenException(DeviceTokenFailure.serverUnavailable),
      const DeviceTokenException(DeviceTokenFailure.rateLimited),
      const DeviceTokenException(DeviceTokenFailure.malformedResponse),
      const DeviceTokenException(
        DeviceTokenFailure.challengeFailed,
        authFailure: DeviceAuthFailure.rateLimited,
      ),
    ];

    final flow = flowFor(trusted: true, respond: (_) => fail('no pairing should happen'));
    await flow.prepare();
    for (final failure in transient) {
      expect(DeviceAuthFlow.isTerminalFailure(failure), isFalse, reason: '${failure.failure}');
      await flow.reportTrustedFailure(failure);
      expect(flow.mode, DeviceAuthMode.trusted);
      expect(flow.showAccessCodePrompt, isFalse);
    }
    expect(trustWrites, isEmpty);
    expect(flow.message, isNull);
    expect(requests, isEmpty);

    final unpaired = flowFor(
      respond: (request) => jsonResponse(401, {'error': accessCode}),
    );
    await unpaired.prepare();
    await unpaired.reportTrustedFailure(
      const DeviceTokenException(DeviceTokenFailure.rejected),
    );
    expect(await unpaired.pair(accessCode), isFalse);
    expect(unpaired.isTrusted, isFalse);
    expect(unpaired.showAccessCodePrompt, isTrue);
    // Only the explicit re-pairing verdict cleared the flag; the failed pairing
    // never writes `true`, so there is no silent fallback to an access-code login.
    expect(trustWrites, <bool>[false]);
  });

  test('a missing deployed route is reported by stage, not as a malformed response', () async {
    final flow = flowFor(respond: (request) => jsonResponse(404, {'error': 'NOT_FOUND'}));
    await flow.prepare();

    expect(await flow.pair(accessCode), isFalse);
    expect(flow.mode, DeviceAuthMode.needsPairing);
    expect(flow.isTrusted, isFalse);
    expect(trustWrites, isEmpty);
    expect(requests.map((request) => request.url.path), <String>['/api/device/pairing']);
    expect(flow.message, "This service can't pair devices yet. Try again after it has been updated.");
    expect(flow.message, isNot('Pairing could not be completed. Try again.'));
    expect(flow.message!.contains(accessCode), isFalse);
    expect(flow.lastDiagnostic?.stage, DeviceAuthStage.issue);
    expect(flow.lastDiagnostic?.failure, DeviceAuthFailure.endpointUnavailable);
    expect(flow.lastDiagnostic.toString(), isNot(contains(accessCode)));

    requests.clear();
    final redeemFlow = flowFor(
      respond: (request) => request.url.path == '/api/device/pairing'
          ? pairingSuccess(request)
          : jsonResponse(404, {'error': 'NOT_FOUND'}),
    );
    await redeemFlow.prepare();

    expect(await redeemFlow.pair(accessCode), isFalse);
    expect(redeemFlow.lastDiagnostic?.stage, DeviceAuthStage.redeem);
    expect(redeemFlow.lastDiagnostic?.failure, DeviceAuthFailure.endpointUnavailable);
    expect(redeemFlow.isTrusted, isFalse);
    expect(trustWrites, isEmpty);
  });
}
