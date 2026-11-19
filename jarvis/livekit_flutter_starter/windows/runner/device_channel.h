#ifndef RUNNER_DEVICE_CHANNEL_H_
#define RUNNER_DEVICE_CHANNEL_H_

namespace flutter {
class FlutterEngine;
}  // namespace flutter

// Registers the Windows half of the `jarvis/device` method channel declared in
// lib/support/device_bridge.dart.
//
// It mirrors the handlers in android/app/src/main/.../MainActivity.kt so the
// same Dart DeviceRpc code can drive either platform: launching apps, playing
// local media, searching local files and changing the volume.
void RegisterDeviceChannel(flutter::FlutterEngine* engine);

#endif  // RUNNER_DEVICE_CHANNEL_H_
