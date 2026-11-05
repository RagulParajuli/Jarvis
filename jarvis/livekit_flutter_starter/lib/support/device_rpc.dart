import 'dart:convert';

import 'package:livekit_client/livekit_client.dart' as sdk;
import 'package:logging/logging.dart';
import 'package:url_launcher/url_launcher.dart';

import 'device_bridge.dart';

/// Handles the RPC calls the agent makes when it wants *this* device to act.
///
/// The agent runs on the user's computer, so every browser or file action it
/// performs itself happens there. These handlers are what let "open youtube"
/// spoken into a phone open YouTube on the phone instead.
///
/// Registering a method the platform cannot serve (say `play_media` on the web
/// build) is harmless: the agent only calls methods this build advertises in
/// its [deviceCapabilities], and anything that slips through answers with a
/// normal failure payload.
class DeviceRpc {
  DeviceRpc(this._room);

  final sdk.Room _room;
  final _registered = <String>[];

  static final _logger = Logger('DeviceRpc');

  void register() {
    _bind('open_url', _openUrl);
    _bind('open_app', _openApp);
    _bind('play_media', _playMedia);
    _bind('find_local_files', _findLocalFiles);
    _bind('send_whatsapp', _sendWhatsapp);
    _bind('device_control', _deviceControl);
  }

  void unregister() {
    for (final method in _registered) {
      _room.unregisterRpcMethod(method);
    }
    _registered.clear();
  }

  /// Wraps [handler] so the agent always receives JSON, never an exception.
  void _bind(String method, Future<DeviceActionResult> Function(Map<String, dynamic> args) handler) {
    _room.registerRpcMethod(method, (data) async {
      try {
        return jsonEncode(await handler(_arguments(data.payload)));
      } catch (error, stackTrace) {
        _logger.warning('$method failed', error, stackTrace);
        return jsonEncode({'success': false, 'error': '$error'});
      }
    });
    _registered.add(method);
  }

  /// Accepts both the structured payloads the agent now sends and the bare
  /// string the first version of `open_url` used.
  Map<String, dynamic> _arguments(String payload) {
    final trimmed = payload.trim();
    if (trimmed.isEmpty) return const {};

    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          return decoded.map((key, value) => MapEntry('$key', value));
        }
      } on FormatException {
        // Not JSON after all; the fallthrough below treats it as a bare value.
      }
    }

    return {'value': trimmed};
  }

  static String? _string(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value == null) return null;

    final text = '$value'.trim();
    return text.isEmpty ? null : text;
  }

  /// Reads `key`, falling back to the bare `value` form.
  static String? _target(Map<String, dynamic> args, String key) =>
      _string(args, key) ?? _string(args, 'value');

  static DeviceActionResult _failure(String message) => {'success': false, 'error': message};

  Future<DeviceActionResult> _openUrl(Map<String, dynamic> args) async {
    final url = _target(args, 'url');
    if (url == null) return _failure('no url was supplied');

    final opened = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    return {'success': opened};
  }

  Future<DeviceActionResult> _openApp(Map<String, dynamic> args) async {
    final app = _target(args, 'app');
    if (app == null) return _failure('no app was named');

    return DeviceBridge.openApp(app);
  }

  Future<DeviceActionResult> _playMedia(Map<String, dynamic> args) async {
    final query = _target(args, 'query');
    if (query == null) return _failure('nothing to play was named');

    return DeviceBridge.playMedia(query, kind: _string(args, 'kind') ?? 'music');
  }

  Future<DeviceActionResult> _findLocalFiles(Map<String, dynamic> args) async {
    final query = _target(args, 'query') ?? '';

    return DeviceBridge.searchMedia(query, kind: _string(args, 'kind') ?? 'music');
  }

  Future<DeviceActionResult> _sendWhatsapp(Map<String, dynamic> args) async {
    final contact = _target(args, 'contact');
    if (contact == null) return _failure('no contact was named');

    return DeviceBridge.sendWhatsapp(contact, _string(args, 'message') ?? '');
  }

  Future<DeviceActionResult> _deviceControl(Map<String, dynamic> args) async {
    final feature = _target(args, 'feature');
    if (feature == null) return _failure('no device feature was named');

    return DeviceBridge.control(feature, _string(args, 'value') ?? '');
  }
}
