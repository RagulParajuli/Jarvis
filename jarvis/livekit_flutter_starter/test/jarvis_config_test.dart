import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jarvis/support/device_auth.dart';
import 'package:jarvis/support/device_bridge.dart';
import 'package:jarvis/support/device_token_source.dart';
import 'package:jarvis/support/jarvis_config.dart';
import 'package:livekit_client/livekit_client.dart' as sdk;

/// There is one backend base URL. The token endpoint and every device route are
/// derived from it, so they cannot drift onto different hosts. These checks use
/// the pure resolver so both the built-in default and the build-time override
/// are covered without recompiling.
void main() {
  const canonicalBase = 'https://jarvis-ai-beta-teal.vercel.app';
  const tokenPath = '/api/token';

  const deviceId = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
  const nonce = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef';
  const signature = 'MEQCIA==';
  const issuedAtMs = 1700000000123;
  const expiresAt = '2030-01-01T00:02:00.000Z';
  const pairingCode = '0123456789abcdef-ABCDEF_ghijklmn';

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

  http.Response jsonResponse(int status, Object body) => http.Response(
        jsonEncode(body),
        status,
        headers: const {'content-type': 'application/json'},
      );

  group('canonical JARVIS_API_BASE_URL', () {
    test('defaults to the permanent hosted backend in a normal build', () {
      expect(defaultJarvisApiBaseUrl, canonicalBase);
      expect(resolveJarvisApiBaseUrl(null).toString(), canonicalBase);
      expect(resolveJarvisApiBaseUrl('').toString(), canonicalBase);
      expect(resolveJarvisApiBaseUrl('   ').toString(), canonicalBase);

      // In a build without an override the public getters use that default too.
      if (const String.fromEnvironment('JARVIS_API_BASE_URL').isEmpty) {
        expect(jarvisApiBaseUrl, Uri.parse(canonicalBase));
        expect(jarvisApiBaseUrlString, canonicalBase);
        expect(jarvisTokenEndpoint, Uri.parse('$canonicalBase$tokenPath'));
      }
    });

    test('derives the token endpoint from the base URL', () {
      final base = resolveJarvisApiBaseUrl(null);
      expect(base.resolve(tokenPath), Uri.parse('$canonicalBase$tokenPath'));
      expect(jarvisTokenEndpoint.path, tokenPath);
      expect(jarvisTokenEndpoint.origin, jarvisApiBaseUrl.origin);
    });

    test('an explicit build-time override is honored and normalized', () {
      final base = resolveJarvisApiBaseUrl('https://staging.jarvis.test/');
      expect(base.toString(), 'https://staging.jarvis.test');
      expect(base.resolve(tokenPath), Uri.parse('https://staging.jarvis.test$tokenPath'));

      // A full token URL is also accepted as the override: its path is dropped
      // and the token endpoint is derived again from the same origin.
      final fromTokenUrl = resolveJarvisApiBaseUrl('https://next.jarvis.test/api/token?x=1#f');
      expect(fromTokenUrl.toString(), 'https://next.jarvis.test');
      expect(fromTokenUrl.resolve(tokenPath), Uri.parse('https://next.jarvis.test$tokenPath'));

      // Non-default ports are preserved as part of the origin.
      expect(
        resolveJarvisApiBaseUrl('http://localhost:3000/api/token').toString(),
        'http://localhost:3000',
      );
    });

    test('blank, malformed or credential-bearing overrides fall back safely', () {
      for (final bad in <String>[
        'not a url',
        'ftp://jarvis.test',
        'https://',
        'https://user:password@jarvis.test',
      ]) {
        expect(resolveJarvisApiBaseUrl(bad), Uri.parse(canonicalBase), reason: bad);
      }
    });
  });

  test('device routes and the token request share one backend origin', () async {
    const override = 'https://staging.jarvis.test';
    final base = resolveJarvisApiBaseUrl(override);
    final recorded = <Uri>[];

    final deviceClient = DeviceAuthClient(
      baseUrl: base.toString(),
      client: MockClient((request) async {
        recorded.add(request.url);
        switch (request.url.path) {
          case '/api/device/challenge':
            return jsonResponse(200, <String, String>{
              'challenge': nonce,
              'audience': deviceAssertionAudience,
              'expires_at': expiresAt,
            });
          case '/api/device/pairing':
            return jsonResponse(200, <String, String>{
              'code': pairingCode,
              'expires_at': expiresAt,
            });
          default:
            return jsonResponse(404, <String, String>{'error': 'unknown'});
        }
      }),
    );

    final tokenSource = DeviceTokenSource(
      tokenEndpoint: base.resolve(tokenPath),
      deviceClient: deviceClient,
      httpClient: MockClient((request) async {
        recorded.add(request.url);
        return jsonResponse(200, <String, String>{
          'server_url': 'wss://staging.jarvis.test/livekit',
          'participant_token': 'a-participant-jwt',
          'participant_name': 'user',
          'room_name': 'jarvis_room',
        });
      }),
      readIdentity: () async => identity,
      signAssertion: (_) async => signature,
      nowMs: () => issuedAtMs,
    );

    await deviceClient.issuePairingCode('a-secret-access-code');
    await tokenSource.fetch(options);

    expect(
      recorded.map((uri) => uri.path).toList(),
      <String>['/api/device/pairing', '/api/device/challenge', tokenPath],
    );
    for (final uri in recorded) {
      expect(uri.origin, base.origin, reason: uri.toString());
    }
  });
}
