import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import 'device_bridge.dart';

/// On-device speech for the offline half of Jarvis.
///
/// The online assistant hears and talks through LiveKit. With no network there
/// is no LiveKit session and no cloud model, so the phone's own speech engine
/// takes over: recognition runs with `preferOffline` set, and replies are spoken
/// by the system text-to-speech engine. Both are Android platform APIs reached
/// through the same channel as the rest of the device actions, so this adds no
/// packages and almost nothing to the download size.
///
/// Events arrive from the native side as `(event, text)` pairs:
/// `ready`, `speech_start`, `speech_end`, `partial`, `final`, `error`,
/// `speech_done`, `speech_error`.
class OfflineVoice {
  OfflineVoice({this.onEvent});

  static const _channel = MethodChannel('jarvis/device');
  static final _logger = Logger('OfflineVoice');

  final void Function(String event, String text)? onEvent;

  bool _registered = false;
  bool _listening = false;

  /// Whether this build has the native handlers behind offline voice.
  bool get isAvailable => DeviceBridge.isNative;

  /// True from the moment the engine is asked to listen until a result or an
  /// error ends the turn.
  bool get isListening => _listening;

  void register() {
    if (!isAvailable || _registered) return;
    _registered = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method != 'offlineSpeech') return null;

      final arguments = call.arguments is Map ? call.arguments as Map : const <Object?, Object?>{};
      final event = '${arguments['event'] ?? ''}';
      final text = '${arguments['text'] ?? ''}';

      if (event == 'ready') _listening = true;
      if (event == 'final' || event == 'error' || event == 'speech_end') _listening = false;

      onEvent?.call(event, text);
      return null;
    });
  }

  void unregister() {
    if (!_registered) return;
    _registered = false;
    _listening = false;
    _channel.setMethodCallHandler(null);
  }

  /// Starts a single recognition turn. Returns whether the engine accepted it.
  Future<bool> startListening({String? language}) async {
    if (!isAvailable) return false;

    try {
      final reply = await _channel.invokeMethod<Map<Object?, Object?>>('listen', {
        'language': language,
        'offline': true,
      });
      final started = reply?['listening'] == true;
      _listening = started;
      if (!started) {
        _logger.warning('offline listening was refused: ${reply?['error']}');
      }
      return started;
    } on PlatformException catch (error) {
      _logger.warning('could not start offline listening: ${error.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> stopListening() async {
    _listening = false;
    if (!isAvailable) return;
    try {
      await _channel.invokeMethod<void>('stopListening');
    } on PlatformException catch (error) {
      _logger.fine('could not stop offline listening: ${error.message}');
    } on MissingPluginException {
      // The build has no native handler; nothing is listening anyway.
    }
  }

  /// Speaks [text] with the system voice. Returns false when speech is not
  /// available, so the caller can fall back to text only.
  Future<bool> speak(String text) async {
    if (!isAvailable || text.trim().isEmpty) return false;

    try {
      final reply = await _channel.invokeMethod<Map<Object?, Object?>>('speak', {'text': text});
      return reply?['success'] == true;
    } on PlatformException catch (error) {
      _logger.fine('could not speak offline reply: ${error.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> stopSpeaking() async {
    if (!isAvailable) return;
    try {
      await _channel.invokeMethod<void>('stopSpeaking');
    } on PlatformException catch (error) {
      _logger.fine('could not stop speech: ${error.message}');
    } on MissingPluginException {
      // Nothing to stop.
    }
  }

  @visibleForTesting
  static MethodChannel get channel => _channel;
}
