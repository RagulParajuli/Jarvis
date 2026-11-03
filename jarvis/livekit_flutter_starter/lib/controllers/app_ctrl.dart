import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:livekit_client/livekit_client.dart' as sdk;
import 'package:livekit_components/livekit_components.dart' as components;
import 'package:logging/logging.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../support/local_token_source.dart';

enum AppScreenState { welcome, agent }

enum AgentScreenState { visualizer, transcription }

class AppCtrl extends ChangeNotifier {
  static const uuid = Uuid();
  static final _logger = Logger('AppCtrl');

  // States
  AppScreenState appScreenState = AppScreenState.welcome;
  AgentScreenState agentScreenState = AgentScreenState.visualizer;

  //Test
  bool isUserCameEnabled = false;
  bool isScreenshareEnabled = false;

  final messageCtrl = TextEditingController();
  final messageFocusNode = FocusNode();

  late final sdk.Room room = sdk.Room(roomOptions: const sdk.RoomOptions(enableVisualizer: true));
  late final roomContext = components.RoomContext(room: room);
  late final sdk.Session session = _createSession(room: room);

  /// `preConnectAudio` is off on purpose. With it on, the microphone is opened
  /// *before* the room connects, so a denied permission, a busy device or an app
  /// that is not foregrounded yet throws from `startRecording` and aborts the
  /// whole connection. Opening the mic after the join instead lets the room
  /// connect first and report microphone problems as their own error.
  static sdk.Session _createSession({required sdk.Room room}) => sdk.Session.fromFixedTokenSource(
        LocalTokenSource(),
        options: sdk.SessionOptions(room: room, preConnectAudio: false),
      );

  bool isSendButtonEnabled = false;
  bool isSessionStarting = false;
  bool _hasCleanedUp = false;
  bool _autoConnectAttempted = false;

  /// True while the platform is refusing to play the agent's audio.
  ///
  /// Browsers only allow audio playback after the user has interacted with the
  /// page, so on the web the agent can be speaking into silence with everything
  /// else working. The HUD turns this into a "tap to enable audio" prompt.
  bool isAudioBlocked = false;
  Future<void> Function()? _audioPlaybackListener;

  AppCtrl() {
    final format = DateFormat('HH:mm:ss');
    // configure logs for debugging
    Logger.root.level = Level.FINE;
    Logger.root.onRecord.listen((record) {
      debugPrint('${format.format(record.time)}: ${record.message}');
    });

    messageCtrl.addListener(() {
      final newValue = messageCtrl.text.isNotEmpty;
      if (newValue != isSendButtonEnabled) {
        isSendButtonEnabled = newValue;
        notifyListeners();
      }
    });

    session.addListener(_handleSessionChange);
    room.registerRpcMethod(_openUrlMethod, _handleOpenUrl);

    _audioPlaybackListener = room.events.on<sdk.AudioPlaybackStatusChanged>((event) {
      if (isAudioBlocked == !event.isPlaying) return;
      isAudioBlocked = !event.isPlaying;
      notifyListeners();
    });

    autoConnect();
  }

  /// RPC method the agent calls when it wants *this* device to open a link.
  static const _openUrlMethod = 'open_url';

  /// Opens a link on this device on the agent's behalf.
  ///
  /// The agent runs on the user's computer, so a browser it drives always
  /// appears there. Handing the URL back lets a phone open its own browser
  /// when the user asks for "open youtube" while talking through the app.
  Future<String> _handleOpenUrl(sdk.RpcInvocationData data) async {
    final url = data.payload.trim();
    if (url.isEmpty) {
      return jsonEncode({'success': false, 'error': 'empty url'});
    }

    try {
      final opened = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      return jsonEncode({'success': opened});
    } catch (error) {
      _logger.warning('Could not open $url: $error');
      return jsonEncode({'success': false, 'error': '$error'});
    }
  }

  /// Resumes playback after the platform stopped it.
  ///
  /// On the web this only has an effect when called from a user gesture, which
  /// is why the app calls it on every pointer down.
  Future<void> enableAudio() async {
    if (!isAudioBlocked) return;

    await room.startAudio();

    final blocked = !room.canPlaybackAudio;
    if (blocked != isAudioBlocked) {
      isAudioBlocked = blocked;
      notifyListeners();
    }
  }

  /// Hands-free start: connect on our own so the user only ever has to speak,
  /// never tap a button. Runs once per launch, after the boot animation, and
  /// leaves the welcome screen's button in place as a manual fallback.
  void autoConnect() {
    if (_autoConnectAttempted) return;
    _autoConnectAttempted = true;

    Timer(const Duration(milliseconds: 1600), () {
      if (appScreenState == AppScreenState.welcome) {
        connect();
      }
    });
  }

  Future<void> cleanUp() async {
    if (_hasCleanedUp) return;
    _hasCleanedUp = true;

    session.removeListener(_handleSessionChange);
    room.unregisterRpcMethod(_openUrlMethod);
    await _audioPlaybackListener?.call();
    _audioPlaybackListener = null;
    await session.dispose();
    await room.dispose();
    roomContext.dispose();
    messageCtrl.dispose();
    messageFocusNode.dispose();
  }

  @override
  void dispose() {
    unawaited(cleanUp());
    super.dispose();
  }

  void sendMessage() async {
    isSendButtonEnabled = false;

    final text = messageCtrl.text;
    messageCtrl.clear();
    notifyListeners();

    if (text.isEmpty) return;
    await session.sendText(text);
  }

  void toggleUserCamera(components.MediaDeviceContext? deviceCtx) {
    isUserCameEnabled = !isUserCameEnabled;
    isUserCameEnabled ? deviceCtx?.enableCamera() : deviceCtx?.disableCamera();
    notifyListeners();
  }

  void toggleScreenShare() {
    isScreenshareEnabled = !isScreenshareEnabled;
    notifyListeners();
  }

  void toggleAgentScreenMode() {
    agentScreenState =
        agentScreenState == AgentScreenState.visualizer ? AgentScreenState.transcription : AgentScreenState.visualizer;
    notifyListeners();
  }

  void connect() async {
    if (isSessionStarting) {
      _logger.fine('Connection attempt ignored: session already starting.');
      return;
    }

    _logger.info('Starting session connection…');
    isSessionStarting = true;
    notifyListeners();

    try {
      await session.start();
      if (session.connectionState == sdk.ConnectionState.connected) {
        appScreenState = AppScreenState.agent;
        notifyListeners();
      }
    } catch (error, stackTrace) {
      _logger.severe('Connection error: $error', error, stackTrace);
      appScreenState = AppScreenState.welcome;
      notifyListeners();
    } finally {
      if (isSessionStarting) {
        isSessionStarting = false;
        notifyListeners();
      }
    }
  }

  Future<void> disconnect() async {
    await session.end();
    session.restoreMessageHistory(const []);
    appScreenState = AppScreenState.welcome;
    agentScreenState = AgentScreenState.visualizer;
    notifyListeners();
  }

  void _handleSessionChange() {
    final sdk.ConnectionState state = session.connectionState;
    AppScreenState? nextScreen;
    switch (state) {
      case sdk.ConnectionState.connected:
      case sdk.ConnectionState.reconnecting:
        nextScreen = AppScreenState.agent;
        break;
      case sdk.ConnectionState.disconnected:
        nextScreen = AppScreenState.welcome;
        break;
      case sdk.ConnectionState.connecting:
        nextScreen = null;
        break;
    }

    if (nextScreen != null && nextScreen != appScreenState) {
      appScreenState = nextScreen;
      notifyListeners();
    }
  }
}
