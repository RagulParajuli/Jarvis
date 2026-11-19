/// Decides when the access code belongs on screen and when a signed device
/// assertion does.
///
/// The state machine lives here rather than in `AppCtrl` so the ordering that
/// matters — redeem before trusting, and never fall back after a rejected
/// assertion — can be tested without a LiveKit session.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:livekit_client/livekit_client.dart' as sdk;

import 'device_auth.dart';
import 'device_bridge.dart';
import 'device_token_source.dart';

/// What the app should do about authentication right now.
enum DeviceAuthMode {
  /// The startup trust check is still running. Do not show the code field yet.
  checking,

  /// Paired: authenticate with [DeviceTokenSource], never with an access code.
  trusted,

  /// Not paired: the access code is needed for the first-time pairing.
  needsPairing,

  /// An issue/redeem round trip is in flight.
  pairing,

  /// A trusted device was revoked, lost its key, or had an assertion rejected.
  /// The code field is shown only as an explicit re-pairing step.
  rePairRequired,
}

/// Secret-free record of the last pairing failure: which request failed and
/// which typed category it fell into. No code, key, signature, challenge,
/// token or response body is ever retained.
class DeviceAuthDiagnostic {
  const DeviceAuthDiagnostic(this.stage, this.failure);

  final DeviceAuthStage stage;
  final DeviceAuthFailure failure;

  @override
  String toString() => 'device auth failed at ${stage.name}: ${failure.name}';
}

/// Owns first-time pairing and the trusted-device auth state.
class DeviceAuthFlow {
  DeviceAuthFlow({
    required this.deviceClient,
    Future<bool?> Function()? isTrusted,
    Future<bool> Function(bool value)? setTrusted,
    DeviceIdentityReader? readIdentity,
    this.deviceLabel = 'Jarvis Android',
  })  : _isTrusted = isTrusted ?? DeviceBridge.isDeviceTrusted,
        _setTrusted = setTrusted ?? DeviceBridge.setDeviceTrusted,
        _readIdentity = readIdentity ?? DeviceBridge.readDeviceIdentity;

  /// Used only while pairing: one code is issued and redeemed, never retried.
  final DeviceAuthClient deviceClient;

  /// Human-readable name stored with this installation's public key.
  final String deviceLabel;

  final Future<bool?> Function() _isTrusted;
  final Future<bool> Function(bool value) _setTrusted;
  final DeviceIdentityReader _readIdentity;

  DeviceAuthMode _mode = DeviceAuthMode.checking;
  String? _message;

  DeviceAuthMode get mode => _mode;

  /// True only when tokens must come from the signed-assertion source.
  bool get isTrusted => _mode == DeviceAuthMode.trusted;

  /// True while a trust check or pairing request is in flight.
  bool get isBusy => _mode == DeviceAuthMode.checking || _mode == DeviceAuthMode.pairing;

  /// The access-code field is shown only for pairing, never for a trusted launch.
  bool get showAccessCodePrompt => _mode == DeviceAuthMode.needsPairing || _mode == DeviceAuthMode.rePairRequired;

  /// A fixed, secret-free message for the welcome screen, when there is one.
  String? get message => _message;

  /// Last failed request/category, for diagnostics. Never holds a secret.
  DeviceAuthDiagnostic? get lastDiagnostic => _lastDiagnostic;

  DeviceAuthDiagnostic? _lastDiagnostic;

  /// Reads the persisted flag once at startup.
  ///
  /// A missing flag (unsupported platform or native failure) is treated as
  /// untrusted, so the app asks for the code instead of trying to sign.
  Future<void> prepare() async {
    if (_mode != DeviceAuthMode.checking) return;
    bool? trusted;
    try {
      trusted = await _isTrusted();
    } catch (_) {
      trusted = null;
    }
    _mode = trusted == true ? DeviceAuthMode.trusted : DeviceAuthMode.needsPairing;
  }

  /// Issues a pairing code with [accessCode], registers this device, and only
  /// then records the local trusted flag.
  ///
  /// Returns false on every failure without ever writing the trusted flag, so a
  /// half-paired device can never look trusted on the next launch.
  Future<bool> pair(String accessCode) async {
    if (accessCode.isEmpty) return false;

    _mode = DeviceAuthMode.pairing;
    _message = null;
    _lastDiagnostic = null;
    try {
      final issued = await deviceClient.issuePairingCode(accessCode);
      final identity = await _readIdentity();
      if (identity == null) {
        // No key means no assertion can ever be produced. Treat it as a refusal.
        throw const DeviceAuthException(DeviceAuthFailure.deviceRejected);
      }
      await deviceClient.redeemPairingCode(
        code: issued.code,
        identity: identity,
        label: deviceLabel,
      );
      final saved = await _setTrusted(true);
      if (!saved) throw const DeviceAuthException(DeviceAuthFailure.deviceRejected);

      _mode = DeviceAuthMode.trusted;
      return true;
    } on DeviceAuthException catch (error) {
      _mode = DeviceAuthMode.needsPairing;
      if (error.stage != null) {
        _lastDiagnostic = DeviceAuthDiagnostic(error.stage!, error.failure);
        // Stage and category only: no code, key, signature, token or body.
        debugPrint(_lastDiagnostic.toString());
      }
      _message = _messageFor(error.failure);
      return false;
    } catch (_) {
      _mode = DeviceAuthMode.needsPairing;
      _message = 'Pairing could not be completed. Check your connection and try again.';
      return false;
    }
  }

  /// Records a terminal failure of the trusted token source.
  ///
  /// Transient trouble (network, outage, rate limit) leaves trusted mode alone
  /// so the existing retry policy can handle it. A revoked device, missing key
  /// or rejected assertion instead requires an explicit re-pairing step, and
  /// the local trusted flag is cleared so the next launch asks for the code.
  Future<void> reportTrustedFailure(DeviceTokenException failure) async {
    if (!isTerminalFailure(failure)) return;

    _mode = DeviceAuthMode.rePairRequired;
    _message = 'This device can no longer sign you in. Enter your access code '
        'to pair it again.';
    try {
      await _setTrusted(false);
    } catch (_) {
      // The in-memory state above is enough to require re-pairing this launch.
    }
  }

  /// Clears the message once the user starts typing a replacement code.
  void clearMessage() {
    _message = null;
    _lastDiagnostic = null;
  }

  /// Unwraps SDK error chaining to find a trusted-device failure, if any.
  static DeviceTokenException? deviceFailureFrom(Object? error) {
    if (error is DeviceTokenException) return error;
    if (error is sdk.SessionError) return deviceFailureFrom(error.cause);
    return null;
  }

  /// True when a device failure is a verdict on the device, not the network.
  static bool isTerminalFailure(DeviceTokenException error) => switch (error.failure) {
        DeviceTokenFailure.noIdentity => true,
        DeviceTokenFailure.signFailed => true,
        DeviceTokenFailure.invalidAssertion => true,
        DeviceTokenFailure.rejected => true,
        // A refused challenge is terminal only when the device is the problem.
        DeviceTokenFailure.challengeFailed => error.authFailure == DeviceAuthFailure.deviceRejected,
        _ => false,
      };

  static String _messageFor(DeviceAuthFailure failure) => switch (failure) {
        DeviceAuthFailure.unauthorized ||
        DeviceAuthFailure.invalidCode =>
          'That code could not be used to pair this device. Check it and try again.',
        DeviceAuthFailure.conflict => 'This device is already paired. Restart the app to continue.',
        DeviceAuthFailure.rateLimited => 'Too many pairing attempts. Try again later.',
        DeviceAuthFailure.deviceRejected => "I couldn't read this device's identity. Try again.",
        DeviceAuthFailure.serverUnavailable ||
        DeviceAuthFailure.networkFailure =>
          "I couldn't reach the assistant service to pair this device. "
              'Check your connection and try again.',
        DeviceAuthFailure.malformedResponse => 'Pairing could not be completed. Try again.',
        DeviceAuthFailure.endpointUnavailable =>
          'This service can\'t pair devices yet. Try again after it has been updated.',
      };
}
