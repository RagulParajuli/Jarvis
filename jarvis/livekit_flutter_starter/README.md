<img src="./.github/assets/app-icon.png" alt="Jarvis app icon" width="100" height="100">

# Jarvis

Jarvis is a personal AI assistant with a voice-first HUD. It runs on LiveKit
Agents: a Python agent does the thinking and tool calling, and the Flutter app
is the client you talk to on Android, iOS, web, macOS and Windows.

There is also a browser frontend in [`../frontend`](../frontend) that serves the
same HUD on the web.

## Features

- **Voice, text and video.** Talk to Jarvis, type to it, or share the camera so
  it can see what you show it.
- **One assistant experience.** Jarvis reconnects in the background and keeps
  local device actions available on the same screen when the cloud agent cannot
  be reached. The current local handler supports flashlight, volume, media,
  apps, websites, time and date; open-ended AI answers still need the cloud.
- **Wake word.** Say "Jarvis" and the app authenticates and joins the room
  without touching the screen. Detection is offline and on-device; the audio
  never leaves the phone before the session starts.
- **Device actions.** The agent can call tools that are executed on the phone:
  opening apps, playing local media, sending WhatsApp messages, torch, volume,
  and opening Settings.
- **No terminal needed.** Once the agent is deployed to LiveKit Cloud, the app
  connects on its own from PC or phone.

## Configure the app

The app needs short-lived room tokens before it can join a room. One base URL in
`lib/support/jarvis_config.dart` is the single source of truth: the token
endpoint (`/api/token`) and the device-pairing routes (`/api/device/*`) are
derived from it, so they always share the same backend origin. No manual URL
entry is needed for development or normal builds.

### 1. Hosted Jarvis backend (default)

No build flag is required. The built-in base is
`https://jarvis-ai-beta-teal.vercel.app`, which gives the token endpoint
`https://jarvis-ai-beta-teal.vercel.app/api/token`. To point a build at a
different environment, override the base once at build time:

```bash
flutter run \
  --dart-define=JARVIS_API_BASE_URL=https://<your-host> \
  --dart-define=LIVEKIT_AGENT_NAME=my-agent
```

Pass a base origin, not a credential-bearing URL. A trailing slash or a path
such as `/api/token` is normalized away, and the app adds `/api/token` itself.
Never put an access code, token or secret in this value. There is deliberately
no runtime URL setting.

### 2. LiveKit Cloud's token server (development alternative)

Enable the **Development token server** in your LiveKit Cloud
[project settings](https://cloud.livekit.io/projects/p_/settings/project) and
copy the **Token server ID**. Pass it at build or run time:

```bash
flutter run \
  --dart-define=LIVEKIT_TOKEN_SERVER_ID=<id> \
  --dart-define=LIVEKIT_AGENT_NAME=my-agent
```

LiveKit Cloud mints the tokens, so nothing needs to run on your computer and no
access code is required. The ID lets anyone who has it request tokens for the
project, so keep it out of public repositories and treat this as a development
setup. The hosted backend above is the production auth path with device pairing.

The "Jarvis" wake word needs no key and no account, so there is nothing else to
configure.

For the endpoint option, configure `LIVEKIT_URL`, `LIVEKIT_API_KEY`,
`LIVEKIT_API_SECRET`, `AGENT_NAME`, `JARVIS_ACCESS_CODE`, and the Upstash
rate-limit settings on the host as described in the
[web frontend guide](../frontend/README.md#token-generation-in-production).
Keep the API secret on the server; the Flutter app only contains the public
endpoint URL. The agent name must match the deployed agent's dispatch name.
Do not set `ALLOW_PUBLIC_TOKEN=true`: it removes the access-code check and is
never recommended, even for a private deployment.

## Run it

```bash
flutter pub get
flutter run \
  --dart-define=LIVEKIT_TOKEN_SERVER_ID=<id> \
  --dart-define=LIVEKIT_AGENT_NAME=my-agent
```

There is no localhost default. On a phone, `127.0.0.1` is the phone itself and
not your computer, so an Android build must use the token server ID or a
deployed HTTPS endpoint. The app reports a missing token configuration instead
of falling back to a local development server.

To run against a local agent, see the [agent README](../README.md) and start it
with `lk agent dev`.

## Wake word

[`lib/support/wake_word.dart`](lib/support/wake_word.dart) listens for "Jarvis"
with a small keyword-spotting model from
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0). It is fully
offline: no account, no key, no audio uploaded.

- The int8 zipformer model and its BPE vocabulary live in `assets/kws/` (~5.5 MB)
  and are copied to the app support directory on first launch, because the native
  engine loads models from file paths.
- `assets/kws/keywords.txt` holds the keyword, `▁JA R VI S`, built from the
  model's own vocabulary, so no training step is involved.
- On detection the app releases the microphone, then authenticates and connects.
  When the session ends it re-arms the wake word.

Wake-word listening is Android-only in v1 and runs while the app is open on
screen. Elsewhere, and if the engine cannot start (for example the microphone
permission is denied), the app falls back to connecting on launch.

The native libraries add about 26 MB per ABI to the APK. Building for every ABI
in one APK multiplies that, which is why the split-per-ABI command above is the
recommended way to ship it.

## Local use without a connection

The app keeps the same HUD on screen and retries the cloud connection in the
background. The built-in local actions are matched by
[`lib/support/offline_commands.dart`](lib/support/offline_commands.dart) and the
device speech is handled by [`lib/support/offline_voice.dart`](lib/support/offline_voice.dart):

- **Android** uses `SpeechRecognizer` with `EXTRA_PREFER_OFFLINE` and the system
  `TextToSpeech` engine, through the existing `jarvis/device` channel. No extra
  packages are added.
- **Every platform** can type an offline command. Offline speech is Android-only;
  native device actions are implemented on Android and Windows.
- Say or type `help` to hear the local actions available on this device.

The current app does not include an on-device language model, so it cannot hold
an open-ended AI conversation with the internet disconnected. It can still hear
and speak supported local actions without switching to a separate screen.

For reliable offline recognition, install the offline speech language for your
locale in Android Settings. The app opens Settings for you if the engine reports
it is missing.

## Small release builds

Release builds enable R8 minification and resource shrinking. Build split APKs
so each phone downloads only the ABI it needs:

```bash
flutter build apk --release --split-per-abi --obfuscate --split-debug-info=build/symbols
```

The default hosted backend needs no token define. To use another environment,
add `--dart-define=JARVIS_API_BASE_URL=https://<your-host>`; for the
development-only LiveKit token server, add
`--dart-define=LIVEKIT_TOKEN_SERVER_ID=<id>` instead. `--dart-define=LIVEKIT_AGENT_NAME`
defaults to `my-agent`.

Keep the `build/symbols` folder: it is required to read stack traces from an
obfuscated build. The ProGuard keep rules live in
`android/app/proguard-rules.pro`; they protect Flutter, WebRTC and the plugins
that are reached through reflection.

## App icon

The launcher icon and every generated size come from one master image:

```bash
python tool/generate_brand_assets.py
```

It writes the Android mipmaps, iOS/macOS icon sets, web/PWA icons, the Windows
`.ico`, the Next.js icon, the README artwork, and `assets/jarvis_logo.png` used
on the welcome screen. To change the branding, replace the master image path at
the top of the script, or overwrite `assets/jarvis_logo.png` and re-run it.

## Testing

```bash
flutter test
flutter analyze
```

`test/offline_commands_test.dart` covers the offline matcher, and
`test/widget_test.dart` covers the HUD widgets without starting a LiveKit
session.

## Notes

- Video and screen share may need a physical device rather than an emulator.
- iOS builds need signing certificates configured in Xcode.
- The app is dark-only by design; both theme slots point at the same HUD palette.
