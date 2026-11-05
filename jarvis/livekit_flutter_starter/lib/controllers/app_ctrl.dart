import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:livekit_client/livekit_client.dart' as sdk;
import 'package:livekit_components/livekit_components.dart' as components;
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../support/background_service.dart';
import '../support/device_bridge.dart';
import '../support/device_rpc.dart';
import '../support/offline_commands.dart';
import '../support/offline_voice.dart';

enum AppScreenState { welcome, agent }

enum AgentScreenState { visualizer, transcription }

class AppCtrl extends ChangeNotifier {
  static const uuid = Uuid();
  static final _logger = Logger('AppCtrl');
  static final _connectionId = uuid.v4();
  static const _tokenEndpoint = String.fromEnvironment('LIVEKIT_TOKEN_ENDPOINT');
  static const _agentName = String.fromEnvironment('LIVEKIT_AGENT_NAME', defaultValue: 'my-agent');
  static final Map<String, String> _tokenHeaders = {};

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

  /// Serves the RPC calls the agent makes when it wants this device to act,
  /// so a request spoken into the phone is carried out on the phone.
  late final _deviceRpc = DeviceRpc(room);

  /// The device's own speech engine, used only while offline.
  late final _offlineVoice = OfflineVoice(onEvent: _handleOfflineSpeechEvent);

  /// `preConnectAudio` is off on purpose. With it on, the microphone is opened
  /// *before* the room connects, so a denied permission, a busy device or an app
  /// that is not foregrounded yet throws from `startRecording` and aborts the
  /// whole connection. Opening the mic after the join instead lets the room
  /// connect first and report microphone problems as their own error.
  static sdk.Session _createSession({required sdk.Room room}) => sdk.Session.fromConfigurableTokenSource(
        sdk.EndpointTokenSource(url: Uri.parse(_tokenEndpoint), headers: _tokenHeaders),
        tokenOptions: sdk.TokenRequestOptions(
          roomName: 'jarvis_$_connectionId',
          participantName: 'user',
          participantIdentity: 'jarvis_user_$_connectionId',
          agentName: _agentName,
          participantMetadata: jsonEncode({
            'platform': devicePlatform,
            'capabilities': deviceCapabilities,
          }),
        ),
        options: sdk.SessionOptions(room: room, preConnectAudio: false),
      );

  bool isSendButtonEnabled = false;
  bool isSessionStarting = false;
  String? accessCodeError;
  bool _hasCleanedUp = false;
  bool _autoConnectAttempted = false;
  bool _everConnected = false;
  bool _localListeningRequested = false;
  bool _connectionIssueShown = false;

  /// True while the phone's own speech engine is listening for an offline
  /// command. The online path uses the LiveKit microphone instead.
  bool isOfflineListening = false;
  bool get isLocalListeningRequested => _localListeningRequested;

  /// Words recognised so far in the current offline turn, shown live in the HUD.
  String offlineTranscript = '';

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
    _deviceRpc.register();
    _offlineVoice.register();

    _audioPlaybackListener = room.events.on<sdk.AudioPlaybackStatusChanged>((event) {
      if (isAudioBlocked == !event.isPlaying) return;
      isAudioBlocked = !event.isPlaying;
      notifyListeners();
    });

    autoConnect();
  }

  /// True while the room is up, meaning the agent can be asked to do things.
  bool get isConnected => session.connectionState == sdk.ConnectionState.connected;

  /// True when the last connection attempt failed, so the HUD can say why the
  /// assistant is only answering a small built-in command set.
  bool isOffline = false;

  Timer? _reconnectTimer;

  /// Keeps trying while offline so the link comes back on its own the moment
  /// the network does, with no button to press.
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 15), () {
      if (!isConnected && !_hasCleanedUp) connect();
    });
  }

  bool _isRejoining = false;

  /// Rejoins the room when the assistant is missing from it.
  ///
  /// The SDK already knows both ways the app can end up talking to nobody: it
  /// raises `AgentFailure.timeout` when no agent arrives within the connect
  /// timeout, and `AgentFailure.left` when the worker drops out mid-session.
  /// Nothing reacted to either, so a room whose agent had died stayed open and
  /// silent indefinitely — the app looked connected while Jarvis heard nothing.
  ///
  /// Joining a fresh room is what re-requests an agent, because LiveKit never
  /// places one into a room that was already open when a worker restarted.
  Future<void> _rejoinForAgent() async {
    if (_isRejoining || _hasCleanedUp) return;

    _isRejoining = true;
    _logger.warning('No assistant in the room (${session.agent.error?.message}); rejoining.');

    try {
      await session.end();
      if (_hasCleanedUp) return;
      // connect() reports its own failures and returns before the join
      // completes, so the rejoin flag only has to cover the deliberate
      // disconnect above.
      connect();
    } catch (error, stackTrace) {
      _logger.severe('Rejoin failed: $error', error, stackTrace);
      _scheduleReconnect();
    } finally {
      _isRejoining = false;
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

    Timer(const Duration(milliseconds: 1600), () async {
      if (appScreenState != AppScreenState.welcome) return;
      if (!_tokenHeaders.containsKey('X-Jarvis-Access-Code')) {
        final savedCode = await DeviceBridge.readSavedAccessCode();
        if (!_tokenHeaders.containsKey('X-Jarvis-Access-Code') && savedCode != null && savedCode.isNotEmpty) {
          setAccessCode(savedCode);
        }
      }
      if (appScreenState == AppScreenState.welcome && _tokenHeaders.containsKey('X-Jarvis-Access-Code')) connect();
    });
  }

  /// Saves a code entered by the user, then starts the room connection.
  Future<void> activateWithAccessCode(String value) async {
    if (value.trim().isEmpty) return;
    final code = value;
    setAccessCode(code);
    await DeviceBridge.saveAccessCode(code);
    connect();
  }

  void setAccessCode(String value) {
    if (value.isEmpty) {
      _tokenHeaders.remove('X-Jarvis-Access-Code');
    } else {
      _tokenHeaders['X-Jarvis-Access-Code'] = value;
    }
    accessCodeError = null;
    notifyListeners();
  }

  Future<void> cleanUp() async {
    if (_hasCleanedUp) return;
    _hasCleanedUp = true;

    _reconnectTimer?.cancel();
    session.removeListener(_handleSessionChange);
    _deviceRpc.unregister();
    await _offlineVoice.stopListening();
    await _offlineVoice.stopSpeaking();
    _offlineVoice.unregister();
    await _audioPlaybackListener?.call();
    _audioPlaybackListener = null;
    await BackgroundService.stop();
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

    // With no room there is no agent to ask, so the built-in command set takes
    // over. This is what keeps the app useful with no internet at all.
    if (!isConnected) {
      await _handleOfflineUtterance(text);
      return;
    }

    await session.sendText(text);
  }

  // ── Offline voice ───────────────────────────────────────────────────────

  /// True when this build can hear and speak without the network.
  bool get canListenOffline => _offlineVoice.isAvailable;

  /// Starts or stops a local speech turn when the room cannot hear the phone.
  Future<void> toggleOfflineListening() async {
    if (_localListeningRequested) {
      _localListeningRequested = false;
      await _offlineVoice.stopListening();
      isOfflineListening = false;
      notifyListeners();
      return;
    }

    if (isConnected || isSessionStarting) return;

    if (!_offlineVoice.isAvailable) {
      _appendAgentNote(
        "Voice input isn't available on this device. Type your command instead.",
      );
      return;
    }

    // Stop any reply that is still playing, otherwise the microphone hears it.
    await _offlineVoice.stopSpeaking();

    offlineTranscript = '';
    _localListeningRequested = true;
    final started = await _offlineVoice.startListening();
    isOfflineListening = started;
    if (!started) {
      _localListeningRequested = false;
      _appendAgentNote("I couldn't start the microphone, buddy. Type the command instead.");
    }
    notifyListeners();
  }

  /// Toggles the live room microphone and reports capture failures in chat.
  Future<void> toggleRoomMicrophone() async {
    if (isSessionStarting) return;
    final participant = room.localParticipant;
    if (participant == null || !isConnected) return;

    try {
      await participant.setMicrophoneEnabled(!participant.isMicrophoneEnabled());
    } catch (error, stackTrace) {
      _logger.warning('Could not change microphone state: $error', error, stackTrace);
      _appendAgentNote("I couldn't open the microphone. Check that no other app is using it, then try again.");
    }
  }

  void _handleOfflineSpeechEvent(String event, String text) {
    switch (event) {
      case 'ready':
        isOfflineListening = true;
        notifyListeners();
      case 'partial':
        offlineTranscript = text;
        notifyListeners();
      case 'speech_start':
        isOfflineListening = true;
        notifyListeners();
      case 'speech_end':
        // Android reports this immediately before the final transcript. Keep
        // the HUD active until the turn is processed or an error arrives.
        break;
      case 'final':
        isOfflineListening = false;
        offlineTranscript = '';
        notifyListeners();
        if (text.trim().isNotEmpty) unawaited(_handleOfflineUtterance(text));
      case 'error':
        isOfflineListening = false;
        offlineTranscript = '';
        notifyListeners();
        if (text == 'no_speech') {
          if (_localListeningRequested) {
            unawaited(_resumeLocalListening());
          } else {
            _appendAgentNote("I didn't catch that. Tap the mic and try again.");
          }
        } else if (text == 'permission') {
          _localListeningRequested = false;
          _appendAgentNote('I need microphone permission before I can hear you.');
        } else if (text == 'network') {
          _localListeningRequested = false;
          _appendAgentNote(
            "The on-device voice engine isn't ready. Download the offline speech "
            'language in Android settings, or type the command instead.',
          );
        } else {
          _localListeningRequested = false;
          _appendAgentNote("The phone's speech recognizer stopped. Tap the mic to try again.");
        }
      case 'speech_done':
      case 'speech_error':
        unawaited(_resumeLocalListening());
        break;
    }
  }

  Future<void> _handleOfflineUtterance(String text) async {
    final reply = await runOfflineCommand(text);
    if (reply == null) {
      unawaited(_resumeLocalListening());
      return;
    }

    _recordLocalExchange(text, reply);
    // Restart recognition after speech completes so the phone doesn't hear its
    // own answer. TTS completion/error events call _resumeLocalListening.
    final spoken = await _offlineVoice.speak(reply);
    if (!spoken) await _resumeLocalListening();
  }

  Future<void> _resumeLocalListening() async {
    if (!_localListeningRequested || !isOffline || isConnected || _hasCleanedUp) return;
    final started = await _offlineVoice.startListening();
    isOfflineListening = started;
    if (!started) {
      _localListeningRequested = false;
      _appendAgentNote("I couldn't restart the microphone. Tap the mic to try again.");
    }
    notifyListeners();
  }

  /// Adds a note from Jarvis without inventing a user message for it.
  void _appendAgentNote(String note) {
    final now = DateTime.now();
    session.restoreMessageHistory([
      ...session.messages,
      sdk.ReceivedMessage(
        id: 'local-note-${now.microsecondsSinceEpoch}',
        timestamp: now,
        content: sdk.AgentTranscript(note),
      ),
    ]);
    agentScreenState = AgentScreenState.transcription;
    notifyListeners();
  }

  /// Appends a locally answered exchange to the transcript.
  ///
  /// There is no agent on the other end in offline mode, so the messages are
  /// written straight into the session history the transcript view reads.
  void _recordLocalExchange(String request, String reply) {
    final now = DateTime.now();
    final stamp = now.microsecondsSinceEpoch;

    session.restoreMessageHistory([
      ...session.messages,
      sdk.ReceivedMessage(
        id: 'local-user-$stamp',
        timestamp: now,
        content: sdk.UserInput(request),
      ),
      sdk.ReceivedMessage(
        id: 'local-agent-$stamp',
        timestamp: now,
        content: sdk.AgentTranscript(reply),
      ),
    ]);

    agentScreenState = AgentScreenState.transcription;
    notifyListeners();
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

    final tokenUri = Uri.tryParse(_tokenEndpoint);
    if (tokenUri == null ||
        !tokenUri.hasScheme ||
        tokenUri.host.isEmpty ||
        !{'http', 'https'}.contains(tokenUri.scheme)) {
      const message =
          'Jarvis is missing its token server URL. Rebuild with '
          '--dart-define=LIVEKIT_TOKEN_ENDPOINT=https://<your-host>/api/token. '
          'The URL must point to the deployed frontend token endpoint.';
      _logger.severe(message);
      isOffline = true;
      appScreenState = AppScreenState.agent;
      agentScreenState = AgentScreenState.transcription;
      _appendAgentNote(message);
      notifyListeners();
      return;
    }

    _logger.info('Starting session connection…');
    isSessionStarting = true;
    notifyListeners();

    try {
      if (_localListeningRequested) {
        await _offlineVoice.stopListening();
        isOfflineListening = false;
      }
      await session.start();
      if (session.connectionState == sdk.ConnectionState.connected) {
        _everConnected = true;
        _connectionIssueShown = false;
        appScreenState = AppScreenState.agent;
        isOffline = false;
        _localListeningRequested = false;
        // The cloud agent is back, so the device microphone and speaker are no
        // longer needed and would otherwise talk over it.
        unawaited(_offlineVoice.stopListening());
        unawaited(_offlineVoice.stopSpeaking());
        isOfflineListening = false;
        offlineTranscript = '';
        // Lets the microphone keep running once the app is backgrounded, which
        // is what makes talking to Jarvis from the home screen possible.
        unawaited(BackgroundService.start());
        notifyListeners();
      } else if (session.error != null) {
        _enterLocalAssistant();
      }
    } catch (error, stackTrace) {
      _logger.severe('Connection error: $error', error, stackTrace);
      _enterLocalAssistant();
    } finally {
      if (isSessionStarting) {
        isSessionStarting = false;
        notifyListeners();
      }
      if (isOffline && _localListeningRequested) unawaited(_resumeLocalListening());
    }
  }

  void _enterLocalAssistant() {
    isOffline = true;
    appScreenState = AppScreenState.agent;
    agentScreenState = AgentScreenState.transcription;
    if (!_connectionIssueShown) {
      _connectionIssueShown = true;
      _appendAgentNote(
        "I can't reach the assistant service right now. You can still speak to me "
        'for actions supported on this phone.',
      );
    }
    _scheduleReconnect();
    notifyListeners();
  }

  Future<void> disconnect() async {
    // Cleared first so the disconnect notification is not mistaken for a drop
    // and routed back into offline mode.
    isOffline = false;
    _connectionIssueShown = false;
    _localListeningRequested = false;
    _reconnectTimer?.cancel();

    await _offlineVoice.stopListening();
    await _offlineVoice.stopSpeaking();
    isOfflineListening = false;
    offlineTranscript = '';

    await session.end();
    await BackgroundService.stop();
    session.restoreMessageHistory(const []);
    appScreenState = AppScreenState.welcome;
    agentScreenState = AgentScreenState.visualizer;
    notifyListeners();
  }

  void _handleSessionChange() {
    // Rejoining ends the session on purpose, so the disconnect it causes must
    // not bounce the user back to the welcome screen.
    if (_isRejoining) return;

    // The assistant never turned up, or dropped out of the room. Reconnect
    // instead of leaving the user talking into a room with nobody in it.
    if (session.agent.error != null && !_hasCleanedUp) {
      unawaited(_rejoinForAgent());
      return;
    }

    final sdk.ConnectionState state = session.connectionState;
    AppScreenState? nextScreen;
    switch (state) {
      case sdk.ConnectionState.connected:
      case sdk.ConnectionState.reconnecting:
        nextScreen = AppScreenState.agent;
        break;
      case sdk.ConnectionState.disconnected:
        if (_everConnected && !_hasCleanedUp && !_isRejoining) {
          // A live session dropped. Keep the HUD usable on-device instead of
          // bouncing to the welcome screen, and retry quietly in the background.
          isOffline = true;
          _scheduleReconnect();
          nextScreen = AppScreenState.agent;
          break;
        }
        // Keep the assistant screen open after a failed join so local actions
        // remain usable; an intentional disconnect returns to welcome.
        nextScreen = isOffline ? AppScreenState.agent : AppScreenState.welcome;
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
