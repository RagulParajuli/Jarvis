import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/support/device_bridge.dart';

/// The agent only calls the methods a client advertises, so the capability
/// list is the contract between the two. These checks keep Windows from
/// promising something its native channel does not implement.
void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Windows advertises exactly the device actions it implements', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    expect(devicePlatform, 'windows');
    expect(
      deviceCapabilities,
      unorderedEquals(<String>[
        'open_url',
        'open_app',
        'play_media',
        'find_local_files',
        'device_control',
      ]),
    );
    // WhatsApp has no silent-send path on Windows, so it stays unadvertised.
    expect(deviceCapabilities, isNot(contains('send_whatsapp')));
    expect(DeviceBridge.isNative, isTrue);
  });

  test('Android keeps its full set, including WhatsApp', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    expect(
      deviceCapabilities,
      unorderedEquals(<String>[
        'open_url',
        'open_app',
        'play_media',
        'find_local_files',
        'send_whatsapp',
        'device_control',
      ]),
    );
    expect(DeviceBridge.isNative, isTrue);
  });

  test('Platforms without a native channel only advertise open_url', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;

    expect(deviceCapabilities, <String>['open_url']);
    expect(DeviceBridge.isNative, isFalse);
  });

  test('Offline speech is only claimed where the channel implements it', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(DeviceBridge.hasNativeSpeech, isFalse);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(DeviceBridge.hasNativeSpeech, isTrue);
  });
}
