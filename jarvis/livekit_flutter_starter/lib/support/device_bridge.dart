import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform name reported to the agent in the LiveKit participant metadata.
///
/// The agent runs on the user's computer, so it cannot tell a phone from the
/// browser build by itself. Sending this along lets it pick the right target.
String get devicePlatform {
  if (kIsWeb) return 'web';

  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    TargetPlatform.windows => 'windows',
    TargetPlatform.macOS => 'macos',
    TargetPlatform.linux => 'linux',
    TargetPlatform.fuchsia => 'unknown',
  };
}

/// Everything this build can be asked to do over RPC.
///
/// The agent only calls methods listed here, so a phone gets its own apps while
/// the web build — which cannot touch the filesystem — is never asked to.
///
/// Android and Windows both ship a native handler behind the `jarvis/device`
/// channel; every other platform only has the `url_launcher` path, so nothing
/// else is advertised.
List<String> get deviceCapabilities {
  final capabilities = <String>{'open_url'};

  if (devicePlatform == 'android') {
    capabilities.addAll(const [
      'open_app',
      'play_media',
      'find_local_files',
      'send_whatsapp',
      'device_control',
    ]);
  } else if (devicePlatform == 'windows') {
    // whatsapp has no silent-send path on Windows, so it stays unadvertised.
    capabilities.addAll(const [
      'open_app',
      'play_media',
      'find_local_files',
      'device_control',
    ]);
  }

  return capabilities.toList();
}

/// Public identity of this app installation.
///
/// Android generates a random installation UUID and a non-exportable P-256
/// signing key in Keystore. Only public material crosses the channel: the
/// private key never leaves the device.
class DeviceIdentity {
  const DeviceIdentity({
    required this.deviceId,
    required this.publicKey,
    required this.fingerprint,
  });

  /// Stable random UUID for this app installation.
  final String deviceId;

  /// Base64 of the DER X.509 SubjectPublicKeyInfo encoding of the public key.
  final String publicKey;

  /// Lowercase hex SHA-256 of those DER bytes: exactly 64 characters.
  final String fingerprint;
}

final RegExp _deviceIdPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);
final RegExp _publicKeyPattern = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');
final RegExp _fingerprintPattern = RegExp(r'^[0-9a-f]{64}$');

/// Validates the native `deviceIdentity` response.
///
/// Returns null for a failure map or malformed public material, so a bad reply
/// can never become a device credential the server would try to trust.
DeviceIdentity? parseDeviceIdentity(Object? response) {
  if (response is! Map || response['success'] != true) return null;

  final deviceId = response['device_id'];
  final publicKey = response['public_key'];
  final fingerprint = response['fingerprint'];
  if (deviceId is! String || !_deviceIdPattern.hasMatch(deviceId)) return null;
  if (publicKey is! String ||
      publicKey.isEmpty ||
      publicKey.length % 4 != 0 ||
      !_publicKeyPattern.hasMatch(publicKey)) {
    return null;
  }
  if (fingerprint is! String || !_fingerprintPattern.hasMatch(fingerprint)) return null;

  return DeviceIdentity(
    deviceId: deviceId,
    publicKey: publicKey,
    fingerprint: fingerprint,
  );
}

/// Signed assertion produced by the device's non-exportable EC key.
class DeviceAssertionSignature {
  const DeviceAssertionSignature(this.signature);

  /// Standard base64 of the DER-encoded ECDSA signature.
  final String signature;
}

final RegExp _signaturePattern = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');

/// Validates the native `signDeviceAssertion` response.
///
/// A failure map or malformed base64 returns null, so a bad reply can never be
/// sent to the token server as a valid assertion.
DeviceAssertionSignature? parseDeviceAssertionSignature(Object? response) {
  if (response is! Map || response['success'] != true) return null;

  final signature = response['signature'];
  if (signature is! String ||
      signature.isEmpty ||
      signature.length % 4 != 0 ||
      !_signaturePattern.hasMatch(signature)) {
    return null;
  }

  return DeviceAssertionSignature(signature);
}

/// Always shaped like the agent's tool payloads: `{success: bool, ...}`.
typedef DeviceActionResult = Map<String, dynamic>;

/// Bridge to the native side for actions the agent cannot perform itself:
/// launching installed apps, playing local media, sending WhatsApp messages and
/// flipping hardware features.
///
/// Every entry point returns a failure map instead of throwing, so a missing
/// native handler or a denied permission surfaces as an ordinary tool error the
/// agent can report to the user.
class DeviceBridge {
  const DeviceBridge._();

  static const _channel = MethodChannel('jarvis/device');

  /// Reads this installation's public identity over the same device channel.
  ///
  /// Android alone backs it today; other platforms return null without calling
  /// native code, so callers can fall back to the access code.
  static Future<DeviceIdentity?> readDeviceIdentity() async {
    if (devicePlatform != 'android') return null;
    try {
      return parseDeviceIdentity(
        await _channel.invokeMethod<Map<Object?, Object?>>('deviceIdentity'),
      );
    } on PlatformException catch (error) {
      debugPrint('Could not read device identity: ${error.message ?? error.code}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Signs [payload] with the device's non-exportable EC key.
  ///
  /// Returns the base64 DER signature, or null when signing is unsupported or
  /// fails. Only Android backs this today; other platforms return null without
  /// calling native code, so callers can fall back to the access code. Neither
  /// the payload nor the signature is ever logged.
  static Future<String?> signDeviceAssertion(String payload) async {
    if (devicePlatform != 'android') return null;
    try {
      final response = await _channel.invokeMethod<Map<Object?, Object?>>(
        'signDeviceAssertion',
        {'payload': payload},
      );
      return parseDeviceAssertionSignature(response)?.signature;
    } on PlatformException catch (error) {
      debugPrint('Could not sign device assertion: ${error.code}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Reads the trusted flag written after a successful device pairing.
  ///
  /// Null means the flag is unavailable (unsupported platform or native
  /// failure). Callers must treat null as untrusted and use the access code.
  static Future<bool?> isDeviceTrusted() async {
    if (devicePlatform != 'android') return null;
    try {
      final response = await _channel.invokeMethod<Map<Object?, Object?>>('isDeviceTrusted');
      if (response is! Map || response['success'] != true) return null;
      final trusted = response['trusted'];
      return trusted is bool ? trusted : null;
    } on PlatformException catch (error) {
      debugPrint('Could not read trusted-device status: ${error.code}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Persists the trusted flag after a pairing. Returns false on any failure.
  static Future<bool> setDeviceTrusted(bool trusted) async {
    if (devicePlatform != 'android') return false;
    try {
      final response = await _channel.invokeMethod<Map<Object?, Object?>>(
        'setDeviceTrusted',
        {'trusted': trusted},
      );
      return response is Map && response['success'] == true;
    } on PlatformException catch (error) {
      debugPrint('Could not save trusted-device status: ${error.code}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Reads the access code saved in the platform's secure storage.
  static Future<String?> readSavedAccessCode() async {
    if (!{'android', 'ios'}.contains(devicePlatform)) return null;
    try {
      return await _channel.invokeMethod<String>('readSavedAccessCode');
    } on PlatformException catch (error) {
      debugPrint('Could not read saved access code: ${error.message ?? error.code}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Stores the code in Android Keystore-backed storage or the iOS Keychain.
  static Future<void> saveAccessCode(String value) async {
    if (!{'android', 'ios'}.contains(devicePlatform)) return;
    try {
      await _channel.invokeMethod<void>('saveAccessCode', {'value': value});
    } on PlatformException catch (error) {
      debugPrint('Could not save access code: ${error.message ?? error.code}');
    } on MissingPluginException {
      // The LiveKit connection can still proceed without remembering the code.
    }
  }

  /// Removes the saved code and the key that protects it.
  ///
  /// Used when the server rejects a code, so a revoked credential cannot be
  /// replayed on the next launch. Platforms without secure storage have
  /// nothing to remove.
  static Future<void> clearSavedAccessCode() async {
    if (!{'android', 'ios'}.contains(devicePlatform)) return;
    try {
      await _channel.invokeMethod<void>('clearSavedAccessCode');
    } on PlatformException catch (error) {
      debugPrint('Could not clear the saved access code: ${error.message ?? error.code}');
    } on MissingPluginException {
      // Nothing was stored by this build.
    }
  }

  /// True when a native implementation backs this build. Android and Windows
  /// ship one; everywhere else only the `url_launcher` path is available.
  static bool get isNative => devicePlatform == 'android' || devicePlatform == 'windows';

  /// True when the platform's own speech engine is reachable through this
  /// channel. Only Android implements `listen` and `speak`, so the offline
  /// voice toggle stays hidden elsewhere even though [isNative] is true.
  static bool get hasNativeSpeech => devicePlatform == 'android';

  static Future<DeviceActionResult> _invoke(String method, Map<String, Object?> arguments) async {
    if (!isNative) {
      return {'success': false, 'error': 'device actions are unavailable on $devicePlatform'};
    }

    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(method, arguments);
      if (result == null) {
        return {'success': false, 'error': 'the device returned no result'};
      }
      return result.map((key, value) => MapEntry('$key', value));
    } on PlatformException catch (error) {
      return {'success': false, 'error': error.message ?? error.code};
    } on MissingPluginException {
      return {'success': false, 'error': 'the device channel is missing from this build'};
    }
  }

  /// Launches an installed app by name, for example "youtube" or "spotify".
  static Future<DeviceActionResult> openApp(String app) => _invoke('openApp', {'app': app});

  /// Finds a local audio or video file and plays it with the default player.
  static Future<DeviceActionResult> playMedia(String query, {String kind = 'music'}) =>
      _invoke('playMedia', {'query': query, 'kind': kind});

  /// Searches local storage and reports matches without playing anything.
  static Future<DeviceActionResult> searchMedia(String query, {String kind = 'music'}) =>
      _invoke('searchMedia', {'query': query, 'kind': kind});

  /// Opens WhatsApp on a chat with the message written out.
  ///
  /// WhatsApp offers no API for sending silently, so the user always confirms
  /// the final tap. Everything up to that point is done for them.
  static Future<DeviceActionResult> sendWhatsapp(String contact, String message) =>
      _invoke('sendWhatsapp', {'contact': contact, 'message': message});

  /// Volume, torch and media transport control.
  ///
  /// `feature` is one of `volume`, `flashlight` or `media`; `value` carries the
  /// feature-specific argument, such as `up`, `mute`, `on`, `play` or `40`.
  static Future<DeviceActionResult> control(String feature, String value) =>
      _invoke('deviceControl', {'feature': feature, 'value': value});

  /// Opens a settings screen, because Android will not let an app flip Wi-Fi or
  /// Bluetooth itself. [section] is `wifi`, `bluetooth` or anything else for the
  /// main settings screen.
  static Future<DeviceActionResult> openSettings(String section) => _invoke('openSettings', {'section': section});
}
