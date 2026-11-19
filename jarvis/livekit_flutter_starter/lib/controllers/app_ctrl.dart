import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:livekit_client/livekit_client.dart' as sdk;
import 'package:livekit_components/livekit_components.dart' as components;
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../support/access_code_store.dart';
import '../support/background_service.dart';
import '../support/device_auth.dart';
import '../support/device_auth_flow.dart';
import '../support/device_bridge.dart';
import '../support/device_rpc.dart';
import '../support/device_token_source.dart';
import '../support/jarvis_config.dart';
import '../support/offline_commands.dart';
import '../support/offline_voice.dart';
import '../support/reconnect_policy.dart';
import '../support/wake_word.dart';

enum AppScreenState { welcome, agent }

enum AgentScreenState { visualizer, transcription }

class AppCtrl extends ChangeNotifier {
  static const uuid = Uuid();
  static final _logger = Logger('AppCtrl');
  static final _connectionId = uuid.v4();

  /// LiveKit Cloud's development token server ID, supplied at build time with
  /// `--dart-define=LIVEKIT_TOKEN_SERVER_ID=<id>`.
  ///
  /// With this set, the app asks LiveKit Cloud for room tokens directly, so a
  /// phone reaches the deployed agent with no token server running on anyone's
  /// computer. Anyone holding the ID can mint tokens for this project, so do not
  /// publish it; LiveKit treats the token server as a development feature.
  static const _tokenServerId = String.fromEnvironment('LIVEKIT_TOKEN_SERVER_ID');

  static const _agentName = String.fromEnvironment('LIVEKIT_AGENT_NAME', defaultValue: 'my-agent');
  static final Map<String, String> _tokenHeaders = {};

  /// True when this build gets room tokens from LiveKit Cloud itself.
  static bool get usesTokenServer => _tokenServerId.trim().isNotEmpty;

  /// True when the build still gates the connection behind an access code.
  /// LiveKit's token server needs none, so the HUD can connect straight away.
  static bool get needsAccessCode => !usesTokenServer;

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
  late final sdk.Session session = _createSession(room: room, tokenSource: _authTokenSource);

  /// Serves the RPC calls the agent makes when it wants this device to act,
  /// so a request spoken into the phone is carried out on the phone.
  late final _deviceRpc = DeviceRpc(room);

  /// Owns the "verify first, then persist" ordering for the access code.
  late final _accessCodes = AccessCodeStore(
    verify: _verifyWithServer,
    read: DeviceBridge.readSavedAccessCode,
    save: DeviceBridge.saveAccessCode,
    clear: DeviceBridge.clearSavedAccessCode,
  );

  /// Pairing and trusted-device token auth share one backend origin. Both the
  /// base and the derived token endpoint come from [jarvisApiBaseUrl].
  late final DeviceAuthClient _deviceClient = DeviceAuthClient(
    baseUrl: jarvisApiBaseUrlString,
  );

  /// Decides between first-time pairing and trusted-device authentication.
  late final DeviceAuthFlow _deviceAuth = DeviceAuthFlow(deviceClient: _deviceClient);

  late final DeviceTokenSource _deviceTokenSource = DeviceTokenSource(
    tokenEndpoint: jarvisTokenEndpoint,
    deviceClient: _deviceClient,
  );

  /// The session holds this stable source; switching the delegate avoids
  /// rebuilding the session, which would change connection/retry timing.
  late final _SwitchingTokenSource _authTokenSource = _SwitchingTokenSource(
    usesTokenServer
        ? sdk.DevelopmentTokenSource(id: _tokenServerId.trim())
        : sdk.EndpointTokenSource(
            url: jarvisTokenEndpoint,
            method: 'POST',
            headers: _tokenHeaders,
          ),
  );

  /// Resolves once the startup trust check has set the auth mode. Both the boot
  /// timer and a manual connect wait for it so an unread flag cannot send a
  /// request with the wrong credential.
  late final Future<void> _authPrepared = _prepareAuthentication();

  /// Android can register a device key; other platforms keep the code path.
  /// The LiveKit token-server build has no access-code flow to pair from.
  bool get _canPairDevice => devicePlatform == 'android' && !usesTokenServer;

  Future<void> _prepareAuthentication() async {
    if (usesTokenServer) return;
    await _deviceAuth.prepare();
    if (_deviceAuth.isTrusted) {
      _authTokenSource.use(_deviceTokenSource);
      // A trusted launch never carries the access code, even if one was saved.
      _tokenHeaders.remove('X-Jarvis-Access-Code');
    }
    if (!_hasCleanedUp) notifyListeners();
  }

  /// The device's own speech engine, used only while offline.
  late final _offlineVoice = OfflineVoice(onEvent: _handleOfflineSpeechEvent);

  /// The on-device wake-word engine that turns "Jarvis" into a connection.
  late final _wakeWord = WakeWord(onDetected: _onWakeWordDetected);

  /// `preConnectAudio` is off on purpose. With it on, the microphone is opened
  /// *before* the room connects, so a denied permission, a busy device or an app
  /// that is not foregrounded yet throws from `startRecording` and aborts the
  /// whole connection. Opening the mic after the join instead lets the room
  /// connect first and report microphone problems as their own error.
  static sdk.Session _createSession({
    required sdk.Room room,
    required sdk.TokenSourceConfigurable tokenSource,
  }) {
    // The source is chosen by the auth state at request time; see
    // `_SwitchingTokenSource`. LiveKit's token server needs no backend at all.
    return sdk.Session.fromConfigurableTokenSource(
      tokenSource,
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
  }

  bool isSendButtonEnabled = false;
  bool isSessionStarting = false;
  String? accessCodeError;

  /// True when tokens must come from the signed-assertion source.
  bool get isTrustedDevice => _deviceAuth.isTrusted;

  /// True while a trust check or pairing request is in flight.
  bool get isAuthenticating => _submission.isRunning || _deviceAuth.isBusy;

  /// The access-code field is for pairing only, and stays hidden until the
  /// startup trust check has finished.
  bool get showAccessCodeField =>
      needsAccessCode && _deviceAuth.mode != DeviceAuthMode.checking && !_deviceAuth.isTrusted;

  /// A typed, secret-free pairing/re-pairing message for the welcome screen.
  String? get deviceAuthMessage => _deviceAuth.message;

  /// Gates access-code checks so one submission cannot start a second request.
  final _submission = AccessCodeSubmission();

  /// True while a candidate code is being checked with the token server, so
  /// the welcome screen can disable its button instead of starting twice.
  bool get isVerifyingAccessCode => _submission.isRunning;

  /// Bounds and paces automatic reconnection after a network failure.
  final _reconnect = ReconnectPolicy();

  /// Set once the server rejects the stored code. Nothing retries on its own
  /// until the user supplies a different one.
  bool _authRejected = false;

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

    // Start the trust check now; the boot timer waits for it before deciding
    // whether an access code is needed.
    unawaited(_authPrepared);
    autoConnect();
  }

  /// True while the room is up, meaning the agent can be asked to do things.
  bool get isConnected => session.connectionState == sdk.ConnectionState.connected;

  /// True when the last connection attempt failed, so the HUD can say why the
  /// assistant is only answering a small built-in command set.
  bool isOffline = false;

  Timer? _reconnectTimer;

  /// Schedules the next automatic reconnect, if the budget allows one.
  ///
  /// Waits double after each failure and stop after [ReconnectPolicy.maxAttempts]
  /// consecutive failures. Repeated notifications for the same drop must not
  /// consume several attempts, so an already-pending retry wins.
  ///
  /// A rejected access code never gets this far: it is cleared, the timer is
  /// cancelled, and the welcome screen asks for a new one instead.
  void _scheduleReconnect() {
    if (_authRejected) return;
    if (_reconnectTimer?.isActive ?? false) return;
    if (isConnected || _hasCleanedUp) return;

    final delay = _reconnect.takeAttempt();
    if (delay == null) {
      _logger.warning('Automatic reconnection gave up after ${_reconnect.attempts} attempts.');
      return;
    }

    _reconnectTimer = Timer(delay, () {
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

  /// Hands-free start: the user only ever has to speak, never tap a button.
  /// Runs once per launch, after the boot animation.
  ///
  /// Where a wake-word engine is available this only arms the listener — the
  /// session starts when "Jarvis" is heard. Everywhere else (web, desktop, or a
  /// device where the on-device engine could not start) it keeps the previous
  /// behaviour of connecting straight away, and the welcome screen's button stays
  /// as the manual fallback.
  void autoConnect() {
    if (_autoConnectAttempted) return;
    _autoConnectAttempted = true;

    Timer(const Duration(milliseconds: 1600), () async {
      if (appScreenState != AppScreenState.welcome) return;
      await _authPrepared;
      if (_hasCleanedUp || appScreenState != AppScreenState.welcome) return;

      if (_deviceAuth.isTrusted) {
        // A trusted launch has no credential to load or display.
        _tokenHeaders.remove('X-Jarvis-Access-Code');
      } else if (_canPairDevice) {
        // Android uses the code only to pair. An unpaired device waits for the
        // welcome screen instead of connecting with a saved code.
        return;
      } else {
        // Platforms without a device key keep the existing saved-code flow.
        if (needsAccessCode && !_tokenHeaders.containsKey('X-Jarvis-Access-Code')) {
          final savedCode = await _accessCodes.restore();
          if (!_tokenHeaders.containsKey('X-Jarvis-Access-Code') && savedCode != null && savedCode.isNotEmpty) {
            setAccessCode(savedCode);
          }
        }
        if (needsAccessCode && !_tokenHeaders.containsKey('X-Jarvis-Access-Code')) return;
      }

      if (await _wakeWord.start()) return;
      if (appScreenState == AppScreenState.welcome && !_hasCleanedUp) connect();
    });
  }

  /// Runs when the on-device engine hears "Jarvis". The room is not connected at
  /// this point, so the saved access code is loaded (when the launch pass did not
  /// already do it) and the normal connect path takes over from there.
  Future<void> _onWakeWordDetected() async {
    if (isConnected || isSessionStarting || _hasCleanedUp) return;
    if (_canPairDevice && !_deviceAuth.isTrusted) {
      _logger.info('Wake word heard before this device was paired.');
      return;
    }
    _logger.info('Wake word detected; starting the session.');

    if (needsAccessCode && !_tokenHeaders.containsKey('X-Jarvis-Access-Code')) {
      final savedCode = await _accessCodes.restore();
      if (savedCode != null && savedCode.isNotEmpty) setAccessCode(savedCode);
    }

    if (needsAccessCode && !_tokenHeaders.containsKey('X-Jarvis-Access-Code')) {
      // Nothing to authenticate with, so leave the welcome screen's code field
      // as the only way forward.
      _logger.warning('Wake word heard, but no access code is saved.');
      return;
    }

    connect();
  }

  /// Verifies a code with the token server, stores it only once accepted, and
  /// then starts the session.
  ///
  /// A code that fails the check is never written, so a typo cannot replace
  /// the code that already works. A rejected code is additionally never
  /// silently retried; the reason is shown on the welcome screen and the user
  /// can correct it there.
  Future<void> activateWithAccessCode(String value) async {
    if (value.trim().isEmpty) return;
    // A second tap or Enter while a check is running would be a duplicate
    // authentication request, so the first one keeps ownership of the result.
    if (_submission.isRunning) return;

    accessCodeError = null;
    final pending = _submission.run(() => _accessCodes.approve(value));
    notifyListeners();

    final status = await pending;
    if (status == null) return;

    switch (status) {
      case AccessCodeStatus.verified:
        // A previously rejected build can retry now that the server accepted
        // this code, and the retry budget starts over from a clean state.
        _authRejected = false;
        _reconnect.reset();
        if (_canPairDevice) {
          // The code's only job on Android is to obtain a device credential.
          final paired = await _deviceAuth.pair(value);
          if (!paired || _hasCleanedUp) {
            notifyListeners();
            return;
          }
          _authTokenSource.use(_deviceTokenSource);
          // Never put the code on a request that carries a device assertion.
          _tokenHeaders.remove('X-Jarvis-Access-Code');
        } else {
          // Platforms without a device key keep the original access-code path.
          setAccessCode(value);
        }
        connect();
      case AccessCodeStatus.rejected:
        accessCodeError = 'That access code was rejected. Check it and try again.';
        notifyListeners();
      case AccessCodeStatus.unreachable:
        accessCodeError = "I couldn't reach the assistant service to check that code. "
            'Check your connection and try again.';
        notifyListeners();
    }
  }

  /// Asks the token endpoint whether [candidate] is accepted.
  ///
  /// The session's own token source type is reused so the URL, method and
  /// header name cannot drift from the real connection. The minted token is
  /// discarded here; only the HTTP status is interpreted, and the code itself
  /// is never logged.
  Future<AccessCodeStatus> _verifyWithServer(String candidate) async {
    final probe = sdk.EndpointTokenSource(
      url: jarvisTokenEndpoint,
      method: 'POST',
      headers: {'X-Jarvis-Access-Code': candidate},
    );

    try {
      await probe.fetch(
        sdk.TokenRequestOptions(
          // No agent name: a check must not dispatch an agent or join a room.
          roomName: 'jarvis_probe_$_connectionId',
          participantName: 'verification',
          participantIdentity: 'jarvis_probe_$_connectionId',
        ),
      );
      return AccessCodeStatus.verified;
    } on sdk.TokenSourceHttpException catch (error) {
      return statusForHttpResponse(error.statusCode);
    } catch (_) {
      // Transport failures say nothing about the code, so it is not rejected.
      _logger.warning('The access code check could not complete.');
      return AccessCodeStatus.unreachable;
    }
  }

  /// True when a failure means the server refused the access code, rather than
  /// the network being unavailable.
  static bool _isAuthRejection(Object? error) {
    if (error is sdk.SessionError) return _isAuthRejection(error.cause);
    if (error is sdk.TokenSourceHttpException) {
      return statusForHttpResponse(error.statusCode) == AccessCodeStatus.rejected;
    }
    return false;
  }

  /// Forgets a rejected code, stops retrying and asks for a new one.
  ///
  /// Reached for HTTP 401/403 only. Retrying would produce the same answer, so
  /// the stored credential is cleared and the welcome screen becomes the only
  /// way forward.
  Future<void> _handleAuthRejection() async {
    _authRejected = true;
    _reconnect.stop();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    _tokenHeaders.remove('X-Jarvis-Access-Code');
    await _accessCodes.forgetRejected();

    // Replace the raw SDK error with the message the welcome screen shows.
    session.dismissError();

    isOffline = false;
    _connectionIssueShown = false;
    _localListeningRequested = false;
    isOfflineListening = false;
    offlineTranscript = '';
    accessCodeError = 'That access code was rejected. Enter it again to continue.';
    appScreenState = AppScreenState.welcome;
    agentScreenState = AgentScreenState.visualizer;

    // Without a code the wake word would only fail again, so it stays off.
    await _wakeWord.stop();

    if (!_hasCleanedUp) notifyListeners();
  }

  /// A revoked device, missing key or rejected assertion is a verdict on the
  /// device, not the network. Stop retrying and require an explicit re-pairing
  /// step; the saved access code is never used as a silent fallback.
  Future<void> _handleDeviceAuthFailure(DeviceTokenException failure) async {
    _authRejected = true;
    _reconnect.stop();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _tokenHeaders.remove('X-Jarvis-Access-Code');

    await _deviceAuth.reportTrustedFailure(failure);

    session.dismissError();
    isOffline = false;
    _connectionIssueShown = false;
    _localListeningRequested = false;
    isOfflineListening = false;
    offlineTranscript = '';
    accessCodeError = null;
    appScreenState = AppScreenState.welcome;
    agentScreenState = AgentScreenState.visualizer;

    await _wakeWord.stop();
    if (!_hasCleanedUp) notifyListeners();
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

  /// Clears the message left by a rejected or unchecked code as the user
  /// starts typing a replacement.
  void dismissAccessCodeError() {
    if (accessCodeError == null && _deviceAuth.message == null) return;
    accessCodeError = null;
    _deviceAuth.clearMessage();
    notifyListeners();
  }

  Future<void> cleanUp() async {
    if (_hasCleanedUp) return;
    _hasCleanedUp = true;

    _reconnectTimer?.cancel();
    session.removeListener(_handleSessionChange);
    _deviceRpc.unregister();
    await _wakeWord.stop();
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
    if (_authRejected) {
      _logger.fine('Connection attempt ignored: the access code was rejected.');
      return;
    }
    if (isSessionStarting) {
      _logger.fine('Connection attempt ignored: session already starting.');
      return;
    }
    await _authPrepared;
    if (_hasCleanedUp) return;

    // This attempt supersedes any retry that was waiting to fire.
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    _logger.info('Starting session connection…');
    isSessionStarting = true;
    notifyListeners();

    try {
      // Porcupine holds the microphone while it listens, so it must let go
      // before the session opens the same device.
      await _wakeWord.stop();
      if (_localListeningRequested) {
        await _offlineVoice.stopListening();
        isOfflineListening = false;
      }
      await session.start();
      if (session.connectionState == sdk.ConnectionState.connected) {
        _everConnected = true;
        _connectionIssueShown = false;
        // A working link restores the full automatic-retry budget.
        _reconnect.reset();
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
        final deviceFailure = DeviceAuthFlow.deviceFailureFrom(session.error);
        if (deviceFailure != null && DeviceAuthFlow.isTerminalFailure(deviceFailure)) {
          await _handleDeviceAuthFailure(deviceFailure);
        } else if (_isAuthRejection(session.error)) {
          await _handleAuthRejection();
        } else {
          _enterLocalAssistant();
        }
      }
    } catch (error, stackTrace) {
      _logger.severe('Connection error: $error', error, stackTrace);
      final deviceFailure = DeviceAuthFlow.deviceFailureFrom(error);
      if (deviceFailure != null && DeviceAuthFlow.isTerminalFailure(deviceFailure)) {
        await _handleDeviceAuthFailure(deviceFailure);
      } else if (_isAuthRejection(error)) {
        await _handleAuthRejection();
      } else {
        _enterLocalAssistant();
      }
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
    // A terminal device failure stays terminal until the device is re-paired.
    _authRejected = _deviceAuth.mode == DeviceAuthMode.rePairRequired;
    _reconnect.reset();
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
    // Hands-free again: the next "Jarvis" reopens the session.
    unawaited(_wakeWord.start());
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
        // A working link restores the full automatic-retry budget, including
        // one the SDK restored without going through connect().
        _reconnect.reset();
        nextScreen = AppScreenState.agent;
        break;
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

/// Keeps the LiveKit session's token source stable while the credential mode
/// changes. The session is created once; only the delegate swaps between the
/// access-code endpoint, the development server and the device source.
class _SwitchingTokenSource implements sdk.TokenSourceConfigurable {
  _SwitchingTokenSource(this._delegate);

  sdk.TokenSourceConfigurable _delegate;

  void use(sdk.TokenSourceConfigurable delegate) => _delegate = delegate;

  @override
  Future<sdk.TokenSourceResponse> fetch(sdk.TokenRequestOptions options) => _delegate.fetch(options);
}
