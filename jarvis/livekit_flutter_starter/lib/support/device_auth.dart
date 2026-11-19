import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'device_bridge.dart';

/// The only audience a device assertion may be signed for.
///
/// Mirrors the server's `TOKEN_API_AUDIENCE`. A challenge response may echo an
/// audience, but the builder never trusts it: anything other than this constant
/// is rejected before a payload is produced.
const String deviceAssertionAudience = 'jarvis-token-api-v1';

const String _payloadVersion = 'jarvis-device-assertion-v1';

/// Server UUID pattern, case-insensitive; the payload lowercases the id.
final RegExp _deviceIdPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// Server nonce pattern: 24 random bytes as 32 base64url characters.
final RegExp _noncePattern = RegExp(r'^[A-Za-z0-9_-]{32}$');

/// Mirrors JavaScript's `Number.MAX_SAFE_INTEGER`, so a timestamp on Dart's
/// arbitrary-precision `int` cannot become a different number on the server.
const int _maxSafeInteger = 9007199254740991;

/// Raised when assertion input is unsafe to sign.
class DeviceAssertionValidationException implements Exception {
  const DeviceAssertionValidationException(this.message);

  final String message;

  @override
  String toString() => 'DeviceAssertionValidationException: $message';
}

/// The exact payload bytes signed by the device's non-exportable key.
class DeviceAssertionPayload {
  const DeviceAssertionPayload(this._text);

  final String _text;

  /// UTF-8 payload text, suitable for `DeviceBridge.signDeviceAssertion`.
  String get text => _text;

  /// UTF-8 bytes, for byte-for-byte compatibility with the server builder.
  List<int> get bytes => utf8.encode(_text);
}

/// Builds the newline-delimited assertion the server verifies.
///
/// Layout, with newline separators and no trailing newline:
///
///     jarvis-device-assertion-v1
///     <device_id lowercased>
///     <nonce>
///     <issued_at_ms as decimal string>
///     jarvis-token-api-v1
///
/// No HTTP happens here: the caller signs [DeviceAssertionPayload.text] and
/// sends the result through the existing token flow.
DeviceAssertionPayload buildDeviceAssertionPayload({
  required String deviceId,
  required String nonce,
  required int issuedAtMs,
  required String audience,
}) {
  if (!_deviceIdPattern.hasMatch(deviceId)) {
    throw const DeviceAssertionValidationException('Invalid device id.');
  }
  if (!_noncePattern.hasMatch(nonce)) {
    throw const DeviceAssertionValidationException('Invalid assertion nonce.');
  }
  if (issuedAtMs < 0 || issuedAtMs > _maxSafeInteger) {
    throw const DeviceAssertionValidationException('Invalid assertion timestamp.');
  }
  if (audience != deviceAssertionAudience) {
    throw const DeviceAssertionValidationException('Unknown assertion audience.');
  }

  final payload = [
    _payloadVersion,
    deviceId.toLowerCase(),
    nonce,
    issuedAtMs.toString(),
    // Always the server-owned constant, never the caller-provided string.
    deviceAssertionAudience,
  ].join('\n');

  return DeviceAssertionPayload(payload);
}

/// Which device-auth request failed.
///
/// Diagnostic only: a stage is never accompanied by a code, key, signature,
/// challenge, token or response body.
enum DeviceAuthStage {
  /// `POST /api/device/pairing`.
  issue,

  /// `POST /api/device/pairing/redeem`.
  redeem,

  /// `POST /api/device/challenge`.
  challenge,
}

/// Why a device-auth request was refused.
///
/// Kept deliberately coarse: the server's generic errors must not be turned
/// into a device-id oracle on the client either.
enum DeviceAuthFailure {
  /// Pairing-code issuance: the access code was missing or incorrect.
  unauthorized,

  /// Redemption: the pairing code was invalid, used or expired.
  invalidCode,

  /// Redemption: this device or credential is already registered.
  conflict,

  /// Too many attempts; the server applies a shared rate limit.
  rateLimited,

  /// A generic refusal, for example a device that is not trusted.
  deviceRejected,

  /// The server returned 5xx.
  serverUnavailable,

  /// A 2xx reply did not have the exact shape this client expects.
  malformedResponse,

  /// HTTP 404: the deployed backend has no device route yet.
  endpointUnavailable,

  /// The request timed out or the transport failed.
  networkFailure,
}

/// Typed failure for a device-auth request.
///
/// [message] is always a fixed string: no access code, pairing code, challenge,
/// response body or transport error text is ever copied into it or logged.
class DeviceAuthException implements Exception {
  const DeviceAuthException(this.failure, {this.stage});

  final DeviceAuthFailure failure;

  /// The request that failed, when known. Safe to report: a stage name only.
  final DeviceAuthStage? stage;

  String get message => switch (failure) {
        DeviceAuthFailure.unauthorized => 'The access code was rejected.',
        DeviceAuthFailure.invalidCode => 'The pairing code is invalid or expired.',
        DeviceAuthFailure.conflict => 'This device is already paired.',
        DeviceAuthFailure.rateLimited => 'Too many attempts. Try again later.',
        DeviceAuthFailure.deviceRejected => 'This device cannot be used for authentication.',
        DeviceAuthFailure.serverUnavailable => 'The service is temporarily unavailable.',
        DeviceAuthFailure.malformedResponse => 'The service returned an unexpected response.',
        DeviceAuthFailure.endpointUnavailable => 'This service does not support device pairing yet.',
        DeviceAuthFailure.networkFailure => 'Could not reach the service.',
      };

  @override
  String toString() {
    final where = stage == null ? '' : ' at ${stage!.name}';
    return 'DeviceAuthException.${failure.name}$where: $message';
  }
}

/// One-time pairing code returned by the server, shown to the user.
class IssuedPairingCode {
  const IssuedPairingCode({required this.code, required this.expiresAt});

  final String code;
  final DateTime expiresAt;
}

/// Confirmation that a device is now registered.
class PairedDevice {
  const PairedDevice({required this.deviceId});

  final String deviceId;
}

/// Short-lived, one-time challenge to be signed with the device key.
class DeviceChallenge {
  const DeviceChallenge({
    required this.challenge,
    required this.audience,
    required this.expiresAt,
  });

  final String challenge;

  /// Always [deviceAssertionAudience]; a server echo is validated, not trusted.
  final String audience;
  final DateTime expiresAt;
}

/// HTTP client for device pairing and challenge issuance.
///
/// Both the [http.Client] and the API base URL are injected so tests can inspect
/// the exact requests. Every method performs a single POST: redemption and
/// challenge issuance are never retried, because a retry could consume a different
/// one-time secret or look like a brute-force attempt to the rate limiter.
class DeviceAuthClient {
  DeviceAuthClient({
    required String baseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  })  : _base = Uri.parse(baseUrl.replaceAll(RegExp(r'/+$'), '')),
        _client = client ?? http.Client();

  final Uri _base;
  final http.Client _client;

  /// Per-request timeout; a timeout maps to [DeviceAuthFailure.networkFailure].
  final Duration timeout;

  static const _pairingPath = '/api/device/pairing';
  static const _redeemPath = '/api/device/pairing/redeem';
  static const _challengePath = '/api/device/challenge';

  /// Server timestamps are ISO-8601 UTC, optionally with milliseconds.
  static final RegExp _isoUtcPattern = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$');

  /// Issues a one-time pairing code. Requires the access code.
  Future<IssuedPairingCode> issuePairingCode(String accessCode) async {
    const stage = DeviceAuthStage.issue;
    final response = await _post(
      _pairingPath,
      const <String, Object?>{},
      accessCode: accessCode,
      stage: stage,
    );
    _checkStatus(
      response,
      const {
        401: DeviceAuthFailure.unauthorized,
        403: DeviceAuthFailure.unauthorized,
        429: DeviceAuthFailure.rateLimited,
      },
      stage: stage,
    );

    final json = _jsonObject(response, stage: stage);
    final code = _string(json, 'code');
    if (code == null || !_noncePattern.hasMatch(code)) {
      throw const DeviceAuthException(DeviceAuthFailure.malformedResponse, stage: stage);
    }
    final expiresAt = _expiry(json['expires_at']);
    if (expiresAt == null) {
      throw const DeviceAuthException(DeviceAuthFailure.malformedResponse, stage: stage);
    }

    return IssuedPairingCode(code: code, expiresAt: expiresAt);
  }

  /// Redeems [code] and registers the already-validated [identity].
  ///
  /// The platform is pinned to `android`: this client only runs where the
  /// non-exportable key behind [DeviceIdentity] exists.
  Future<PairedDevice> redeemPairingCode({
    required String code,
    required DeviceIdentity identity,
    required String label,
  }) async {
    const stage = DeviceAuthStage.redeem;
    final response = await _post(
        _redeemPath,
        <String, Object?>{
          'code': code,
          'device_id': identity.deviceId,
          'public_key': identity.publicKey,
          'fingerprint': identity.fingerprint,
          'platform': 'android',
          'label': label,
        },
        stage: stage);
    _checkStatus(
      response,
      const {
        401: DeviceAuthFailure.invalidCode,
        409: DeviceAuthFailure.conflict,
        429: DeviceAuthFailure.rateLimited,
      },
      stage: stage,
    );

    final json = _jsonObject(response, stage: stage);
    if (_string(json, 'status') != 'paired') {
      throw const DeviceAuthException(DeviceAuthFailure.malformedResponse, stage: stage);
    }
    final deviceId = _string(json, 'device_id');
    if (deviceId == null ||
        !_deviceIdPattern.hasMatch(deviceId) ||
        deviceId.toLowerCase() != identity.deviceId.toLowerCase()) {
      throw const DeviceAuthException(DeviceAuthFailure.malformedResponse, stage: stage);
    }

    return PairedDevice(deviceId: deviceId);
  }

  /// Requests a challenge for a trusted [deviceId].
  ///
  /// The body holds only `device_id`: no access code is sent, and the audience
  /// echoed by the server is validated against the fixed constant before use.
  Future<DeviceChallenge> requestChallenge(String deviceId) async {
    if (!_deviceIdPattern.hasMatch(deviceId)) {
      // Generic: never echo the supplied id back into an exception.
      throw ArgumentError('Invalid device id.');
    }

    const stage = DeviceAuthStage.challenge;
    final response = await _post(
      _challengePath,
      <String, Object?>{'device_id': deviceId},
      stage: stage,
    );
    _checkStatus(
      response,
      const {
        400: DeviceAuthFailure.deviceRejected,
        429: DeviceAuthFailure.rateLimited,
      },
      stage: stage,
    );

    final json = _jsonObject(response, stage: stage);
    final challenge = _string(json, 'challenge');
    final audience = _string(json, 'audience');
    final expiresAt = _expiry(json['expires_at']);
    if (challenge == null ||
        !_noncePattern.hasMatch(challenge) ||
        audience == null ||
        audience != deviceAssertionAudience ||
        expiresAt == null) {
      throw const DeviceAuthException(DeviceAuthFailure.malformedResponse, stage: stage);
    }

    return DeviceChallenge(challenge: challenge, audience: audience, expiresAt: expiresAt);
  }

  Uri _uri(String path) => Uri.parse('$_base$path');

  Future<http.Response> _post(
    String path,
    Map<String, Object?> body, {
    String? accessCode,
    required DeviceAuthStage stage,
  }) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (accessCode != null) headers['X-Jarvis-Access-Code'] = accessCode;

    try {
      return await _client.post(_uri(path), headers: headers, body: jsonEncode(body)).timeout(timeout);
    } on TimeoutException {
      throw DeviceAuthException(DeviceAuthFailure.networkFailure, stage: stage);
    } on http.ClientException {
      throw DeviceAuthException(DeviceAuthFailure.networkFailure, stage: stage);
    }
  }

  void _checkStatus(
    http.Response response,
    Map<int, DeviceAuthFailure> byStatus, {
    required DeviceAuthStage stage,
  }) {
    final status = response.statusCode;
    final mapped = byStatus[status];
    if (mapped != null) throw DeviceAuthException(mapped, stage: stage);
    if (status == 404) {
      // A missing route means the deployed backend is older than this app. It
      // is not a malformed 2xx body and not a retryable network problem.
      throw DeviceAuthException(DeviceAuthFailure.endpointUnavailable, stage: stage);
    }
    if (status >= 500) {
      throw DeviceAuthException(DeviceAuthFailure.serverUnavailable, stage: stage);
    }
    if (status < 200 || status >= 300) {
      throw DeviceAuthException(DeviceAuthFailure.malformedResponse, stage: stage);
    }
  }

  Map<String, dynamic> _jsonObject(http.Response response, {required DeviceAuthStage stage}) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // Fall through to the same generic failure.
    }
    throw DeviceAuthException(DeviceAuthFailure.malformedResponse, stage: stage);
  }

  String? _string(Map<String, dynamic> json, String key) {
    final value = json[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  DateTime? _expiry(Object? value) {
    if (value is! String || !_isoUtcPattern.hasMatch(value)) return null;
    final parsed = DateTime.tryParse(value)?.toUtc();
    // A success response must not hand back a secret that is already dead.
    if (parsed == null || !parsed.isAfter(DateTime.now().toUtc())) return null;
    return parsed;
  }
}
