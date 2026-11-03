import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:livekit_client/livekit_client.dart' as sdk;
import 'package:uuid/uuid.dart';

/// Mints LiveKit access tokens locally from the credentials in `assets/.env`.
///
/// LiveKit Cloud's sandbox token server is a development convenience that can
/// expire or disappear, which leaves the app connected to a room with no agent
/// listening. Signing the token here removes that dependency, so the same build
/// works on desktop and mobile without a token server running.
///
/// A fresh token is produced on every [fetch], which is what [sdk.Session]
/// calls each time a connection is started.
class LocalTokenSource implements sdk.TokenSourceFixed {
  LocalTokenSource();

  static const _uuid = Uuid();
  static const _tokenLifetime = Duration(hours: 6);

  @override
  Future<sdk.TokenSourceResponse> fetch() async {
    final serverUrl = _env('LIVEKIT_URL');
    final apiKey = _env('LIVEKIT_API_KEY');
    final apiSecret = _env('LIVEKIT_API_SECRET');
    final agentName = _env('LIVEKIT_AGENT_NAME');

    if (serverUrl == null || apiKey == null || apiSecret == null) {
      throw StateError(
        'assets/.env must define LIVEKIT_URL, LIVEKIT_API_KEY and LIVEKIT_API_SECRET.',
      );
    }

    final roomName = 'voice_assistant_room_${_uuid.v4().substring(0, 8)}';
    final identity = 'voice_assistant_user_${_uuid.v4().substring(0, 8)}';

    final token = JWT(
      {
        'name': 'user',
        'video': {
          'roomJoin': true,
          'room': roomName,
          'canPublish': true,
          'canSubscribe': true,
          'canPublishData': true,
        },
        // Dispatching by name here means the agent worker is requested as part
        // of joining, exactly like the Next.js /api/token route does.
        if (agentName != null)
          'roomConfig': {
            'agents': [
              {'agentName': agentName},
            ],
          },
      },
      issuer: apiKey,
      subject: identity,
    ).sign(
      SecretKey(apiSecret),
      algorithm: JWTAlgorithm.HS256,
      expiresIn: _tokenLifetime,
      noIssueAt: true,
    );

    return sdk.TokenSourceResponse(
      serverUrl: serverUrl,
      participantToken: token,
      participantName: 'user',
      roomName: roomName,
    );
  }

  static String? _env(String key) {
    final value = dotenv.maybeGet(key)?.replaceAll(RegExp(r'''^["']|["']$'''), '').trim();
    return (value == null || value.isEmpty) ? null : value;
  }
}
