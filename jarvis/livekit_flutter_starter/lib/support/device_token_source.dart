import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as sdk;

import 'device_auth.dart';
import 'device_bridge.dart';

/// Reads this installation's already-validated public identity.
typedef DeviceIdentityReader = Future<DeviceIdentity?> Function();

/// Signs an assertion payload, returning base64 DER or null on failure.
typedef DeviceAssertionSigner = Future<String?> Function(String payload);

/// Current time in milliseconds since the epoch, injectable for tests.
typedef DeviceClockMs = int Function();

/// Why a trusted-device token request could not be completed.
enum DeviceTokenFailure {
  /// No saved identity: this installation has not been paired.
  noIdentity,

  /// The challenge endpoint refused the device.
  challengeFailed,

  /// The assertion could not be built from a challenge/identity.
  invalidAssertion,

  /// The device key could not sign the payload.
  signFailed,

  /// The token endpoint rate limited the request.
  rateLimited,

  /// The token endpoint rejected the assertion.
  rejected,

  /// The token endpoint returned 5xx.
  serverUnavailable,

  /// A 2xx reply did not have the expected credential shape.
  malformedResponse,

  /// The request timed out or the transport failed.
  networkFailure,
}

/// Typed failure for a trusted-device token request.
///
/// Messages are fixed strings: no identity, challenge, payload, signature,
/// access code or response body ever reaches an exception or a log.
class DeviceTokenException implements Exception {
  const DeviceTokenException(this.failure, {this.authFailure});

  final DeviceTokenFailure failure;

  /// The underlying challenge failure, when the challenge was refused.
  final DeviceAuthFailure? authFailure;

  String get message => switch (failure) {
        DeviceTokenFailure.noIdentity => 'This device has no registered identity.',
        DeviceTokenFailure.challengeFailed => 'This device could not obtain a challenge.',
        DeviceTokenFailure.invalidAssertion => 'The device assertion could not be built.',
        DeviceTokenFailure.signFailed => 'This device could not sign the assertion.',
        DeviceTokenFailure.rateLimited => 'Too many attempts. Try again later.',
        DeviceTokenFailure.rejected => 'This device was not accepted for this connection.',
        DeviceTokenFailure.serverUnavailable => 'The service is temporarily unavailable.',
        DeviceTokenFailure.malformedResponse => 'The service returned an unexpected response.',
        DeviceTokenFailure.networkFailure => 'Could not reach the service.',
      };

  @override
  String toString() => 'DeviceTokenException.${failure.name}: $message';
}

/// Token source that authenticates with a signed device assertion.
///
/// It implements the same [sdk.TokenSourceConfigurable] interface as the
/// existing endpoint source, so swapping it in never changes the connection
/// lifecycle. Access-code authentication is deliberately absent: a rejected
/// assertion is a terminal failure, never a signal to retry with a code.
class DeviceTokenSource implements sdk.TokenSourceConfigurable {
  DeviceTokenSource({
    required this.tokenEndpoint,
    required this.deviceClient,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 10),
    DeviceIdentityReader? readIdentity,
    DeviceAssertionSigner? signAssertion,
    DeviceClockMs? nowMs,
  })  : _http = httpClient ?? http.Client(),
        _readIdentity = readIdentity ?? DeviceBridge.readDeviceIdentity,
        _signAssertion = signAssertion ?? DeviceBridge.signDeviceAssertion,
        _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Full URL of the deployed `/api/token` endpoint.
  final Uri tokenEndpoint;

  /// Client used to obtain the short-lived challenge for this device.
  final DeviceAuthClient deviceClient;

  /// Per-request timeout; a timeout maps to [DeviceTokenFailure.networkFailure].
  final Duration timeout;

  final http.Client _http;
  final DeviceIdentityReader _readIdentity;
  final DeviceAssertionSigner _signAssertion;
  final DeviceClockMs _nowMs;

  @override
  Future<sdk.TokenSourceResponse> fetch(sdk.TokenRequestOptions options) async {
    final identity = await _readIdentity();
    if (identity == null) throw const DeviceTokenException(DeviceTokenFailure.noIdentity);

    final DeviceChallenge challenge;
    try {
      challenge = await deviceClient.requestChallenge(identity.deviceId);
    } on DeviceAuthException catch (error) {
      throw DeviceTokenException(DeviceTokenFailure.challengeFailed, authFailure: error.failure);
    }

    final issuedAtMs = _nowMs();
    final DeviceAssertionPayload payload;
    try {
      payload = buildDeviceAssertionPayload(
        deviceId: identity.deviceId,
        nonce: challenge.challenge,
        issuedAtMs: issuedAtMs,
        // The payload builder validates this against the fixed server audience.
        audience: challenge.audience,
      );
    } on DeviceAssertionValidationException {
      throw const DeviceTokenException(DeviceTokenFailure.invalidAssertion);
    }

    final signature = await _signAssertion(payload.text);
    if (signature == null || signature.isEmpty) {
      throw const DeviceTokenException(DeviceTokenFailure.signFailed);
    }

    // Same wire format as the existing EndpointTokenSource, plus the assertion.
    final body = options.toRequest().toJson();
    body['device_assertion'] = <String, Object?>{
      'device_id': identity.deviceId,
      'nonce': challenge.challenge,
      'issued_at_ms': issuedAtMs,
      'signature': signature,
    };

    return _parseResponse(await _post(body));
  }

  Future<http.Response> _post(Map<String, dynamic> body) async {
    try {
      return await _http
          .post(
            tokenEndpoint,
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const DeviceTokenException(DeviceTokenFailure.networkFailure);
    } on http.ClientException {
      throw const DeviceTokenException(DeviceTokenFailure.networkFailure);
    }
  }

  sdk.TokenSourceResponse _parseResponse(http.Response response) {
    final status = response.statusCode;
    if (status == 429) throw const DeviceTokenException(DeviceTokenFailure.rateLimited);
    if (status == 400 || status == 401) throw const DeviceTokenException(DeviceTokenFailure.rejected);
    if (status >= 500) throw const DeviceTokenException(DeviceTokenFailure.serverUnavailable);
    if (status < 200 || status >= 300) throw const DeviceTokenException(DeviceTokenFailure.rejected);

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const DeviceTokenException(DeviceTokenFailure.malformedResponse);
    }
    if (decoded is! Map<String, dynamic>) {
      throw const DeviceTokenException(DeviceTokenFailure.malformedResponse);
    }

    final serverUrl = decoded['server_url'];
    final participantToken = decoded['participant_token'];
    if (serverUrl is! String || serverUrl.isEmpty || participantToken is! String || participantToken.isEmpty) {
      throw const DeviceTokenException(DeviceTokenFailure.malformedResponse);
    }
    for (final key in const <String>['participant_name', 'room_name']) {
      final value = decoded[key];
      if (value != null && value is! String) {
        throw const DeviceTokenException(DeviceTokenFailure.malformedResponse);
      }
    }

    return sdk.TokenSourceResponse.fromJson(decoded);
  }
}
