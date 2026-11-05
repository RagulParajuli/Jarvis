import 'package:flutter_background/flutter_background.dart';
import 'package:logging/logging.dart';

import 'device_bridge.dart';

/// Keeps the session alive after the app leaves the foreground.
///
/// Android suspends the process as soon as the user goes home, which tears down
/// the microphone and ends the conversation. A foreground service keeps the
/// process runnable so Jarvis can still be spoken to from the home screen.
///
/// The cost is a permanent notification. Android requires a visible one for
/// background microphone access, so there is no way to avoid it.
class BackgroundService {
  const BackgroundService._();

  static final _logger = Logger('BackgroundService');

  static bool _initialised = false;

  /// True once the service is running, which is also what the HUD reports.
  static bool get isRunning => FlutterBackground.isBackgroundExecutionEnabled;

  /// Starts the service, returning whether it is actually running afterwards.
  ///
  /// Never throws: a phone that refuses the permission simply keeps the
  /// foreground-only behaviour.
  static Future<bool> start() async {
    if (devicePlatform != 'android') return false;
    if (isRunning) return true;

    try {
      if (!_initialised) {
        _initialised = await FlutterBackground.initialize(
          androidConfig: const FlutterBackgroundAndroidConfig(
            notificationTitle: 'Jarvis is listening',
            notificationText: 'Tap to return to the assistant.',
            notificationImportance: AndroidNotificationImportance.normal,
            // The Wi-Fi lock matters here: without it Doze can park the radio
            // and the live audio connection silently dies.
            enableWifiLock: true,
          ),
        );
      }

      if (!_initialised) return false;

      await FlutterBackground.enableBackgroundExecution();
      return isRunning;
    } catch (error, stackTrace) {
      _logger.warning('could not start background execution', error, stackTrace);
      return false;
    }
  }

  static Future<void> stop() async {
    if (devicePlatform != 'android' || !_initialised || !isRunning) return;

    try {
      await FlutterBackground.disableBackgroundExecution();
    } catch (error, stackTrace) {
      _logger.warning('could not stop background execution', error, stackTrace);
    }
  }
}
