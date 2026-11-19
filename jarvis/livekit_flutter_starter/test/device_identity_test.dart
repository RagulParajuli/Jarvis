import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/support/device_bridge.dart';

/// The device identity is only useful if the native reply has the exact shape
/// the server expects: a UUID, base64 SPKI and a 64-character hex fingerprint.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('jarvis/device');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const id = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
  const publicKey = 'AQIDBA==';
  const fingerprint = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  Map<String, Object?> reply({
    bool success = true,
    Object? deviceId = id,
    Object? key = publicKey,
    Object? print = fingerprint,
  }) =>
      <String, Object?>{
        'success': success,
        'device_id': deviceId,
        'public_key': key,
        'fingerprint': print,
      };

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('a well-formed native reply becomes a device identity', () {
    final identity = parseDeviceIdentity(reply());

    expect(identity, isNotNull);
    expect(identity!.deviceId, id);
    expect(identity.publicKey, publicKey);
    expect(identity.fingerprint, fingerprint);
    expect(identity.fingerprint, hasLength(64));
  });

  test('failure and malformed replies are rejected', () {
    expect(parseDeviceIdentity(null), isNull);
    expect(parseDeviceIdentity(reply(success: false)), isNull);
    expect(parseDeviceIdentity(<String, Object?>{'device_id': id}), isNull);
    expect(parseDeviceIdentity(reply(deviceId: 'not-a-uuid')), isNull);
    expect(parseDeviceIdentity(reply(key: 'not base64!')), isNull);
    expect(parseDeviceIdentity(reply(key: 'AQIDB')), isNull);
    expect(parseDeviceIdentity(reply(print: fingerprint.toUpperCase())), isNull);
    expect(parseDeviceIdentity(reply(print: 'abcdef')), isNull);
  });

  test('the existing device channel supplies a validated identity', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return reply();
    });

    final identity = await DeviceBridge.readDeviceIdentity();

    expect(calls, <String>['deviceIdentity']);
    expect(identity?.deviceId, id);
    expect(identity?.fingerprint, fingerprint);
  });

  test('a native failure or another platform yields no identity', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    messenger.setMockMethodCallHandler(channel, (call) async => reply(success: false));
    expect(await DeviceBridge.readDeviceIdentity(), isNull);

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    messenger.setMockMethodCallHandler(channel, (call) async => throw StateError('must not be called'));
    expect(await DeviceBridge.readDeviceIdentity(), isNull);
  });
}
