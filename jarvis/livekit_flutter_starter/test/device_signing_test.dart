import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/support/device_bridge.dart';

/// The native signer is the only path to the non-exportable device key. These
/// tests pin the channel contract: the exact payload is forwarded, only a
/// canonical base64 DER reply is accepted, and every failure is safe.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('jarvis/device');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  // A canonical padded base64 value standing in for a DER ECDSA signature.
  final signature = base64Encode(List<int>.generate(70, (i) => i + 1));

  Map<String, Object?> signReply({bool success = true, Object? value}) =>
      <String, Object?>{'success': success, 'signature': value ?? signature};

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  group('parseDeviceAssertionSignature', () {
    test('accepts a canonical base64 signature', () {
      final parsed = parseDeviceAssertionSignature(signReply());

      expect(parsed, isNotNull);
      expect(parsed!.signature, signature);
    });

    test('failure maps and malformed base64 are rejected', () {
      expect(parseDeviceAssertionSignature(null), isNull);
      expect(parseDeviceAssertionSignature(signReply(success: false)), isNull);
      expect(parseDeviceAssertionSignature(<String, Object?>{'success': true}), isNull);
      expect(parseDeviceAssertionSignature(signReply(value: '')), isNull);
      expect(parseDeviceAssertionSignature(signReply(value: 'not base64!')), isNull);
      // Bad padding: length is not a multiple of four.
      expect(parseDeviceAssertionSignature(signReply(value: 'AQI')), isNull);
      expect(parseDeviceAssertionSignature(signReply(value: 7)), isNull);
    });
  });

  group('DeviceBridge.signDeviceAssertion', () {
    test('forwards the exact payload and returns the validated signature', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return signReply();
      });

      const payload = 'jarvis-device-assertion-v1\nid\nnonce\n123\njarvis-token-api-v1';
      final result = await DeviceBridge.signDeviceAssertion(payload);

      expect(calls, hasLength(1));
      expect(calls.single.method, 'signDeviceAssertion');
      expect(calls.single.arguments, <String, Object?>{'payload': payload});
      expect(result, signature);
    });

    test('native failure maps and channel errors yield no signature', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      messenger.setMockMethodCallHandler(channel, (call) async => signReply(success: false));
      expect(await DeviceBridge.signDeviceAssertion('payload'), isNull);

      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'device_signing', message: 'Device signing is unavailable.');
      });
      expect(await DeviceBridge.signDeviceAssertion('payload'), isNull);

      messenger.setMockMethodCallHandler(channel, (call) async => throw MissingPluginException());
      expect(await DeviceBridge.signDeviceAssertion('payload'), isNull);
    });

    test('non-Android platforms never call native code', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      messenger.setMockMethodCallHandler(channel, (call) async => throw StateError('must not be called'));
      expect(await DeviceBridge.signDeviceAssertion('payload'), isNull);
    });
  });

  group('trusted-device flag', () {
    test('reads the trusted flag from the native reply', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return <String, Object?>{'success': true, 'trusted': true};
      });

      expect(await DeviceBridge.isDeviceTrusted(), isTrue);
      expect(calls, <String>['isDeviceTrusted']);
    });

    test('missing, malformed or failed replies are unsafe', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      messenger.setMockMethodCallHandler(channel, (call) async => <String, Object?>{'success': true, 'trusted': false});
      expect(await DeviceBridge.isDeviceTrusted(), isFalse);

      messenger.setMockMethodCallHandler(channel, (call) async => <String, Object?>{'success': false, 'trusted': true});
      expect(await DeviceBridge.isDeviceTrusted(), isNull);

      messenger.setMockMethodCallHandler(channel, (call) async => throw MissingPluginException());
      expect(await DeviceBridge.isDeviceTrusted(), isNull);
    });

    test('writes both flag values and reports success', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return <String, Object?>{'success': true};
      });

      expect(await DeviceBridge.setDeviceTrusted(true), isTrue);
      expect(calls.single.method, 'setDeviceTrusted');
      expect(calls.single.arguments, <String, Object?>{'trusted': true});

      expect(await DeviceBridge.setDeviceTrusted(false), isTrue);
      expect(calls.last.arguments, <String, Object?>{'trusted': false});
    });

    test('failed or unsupported writes report false', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'device_preferences');
      });
      expect(await DeviceBridge.setDeviceTrusted(true), isFalse);

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      messenger.setMockMethodCallHandler(channel, (call) async => throw StateError('must not be called'));
      expect(await DeviceBridge.setDeviceTrusted(true), isFalse);
    });
  });
}
