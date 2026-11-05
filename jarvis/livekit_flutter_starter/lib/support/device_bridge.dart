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
/// Android is the only platform with the native handler behind these; elsewhere
/// the call would come back as a failure, so it is not advertised.
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
  }

  return capabilities.toList();
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

  /// True when a native implementation backs this build. Only Android ships
  /// one, so everywhere else only the `url_launcher` path is available.
  static bool get isNative => devicePlatform == 'android';

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
  static Future<DeviceActionResult> openSettings(String section) =>
      _invoke('openSettings', {'section': section});
}
