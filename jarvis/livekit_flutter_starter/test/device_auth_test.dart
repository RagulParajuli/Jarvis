import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/support/device_auth.dart';

/// The signature is over exact bytes, so the Dart builder must match the
/// server's `assertionPayload()` byte for byte. These tests pin that contract:
/// one golden vector, and every input that must be refused before signing.
void main() {
  const deviceId = '3F2504E0-4F89-41D3-9A0C-0305E82C3301';
  const nonce = '0123456789abcdef-ABCDEF_ghijklmn';
  const issuedAtMs = 1700000000123;

  group('buildDeviceAssertionPayload', () {
    test('matches the server golden vector byte for byte', () {
      final payload = buildDeviceAssertionPayload(
        deviceId: deviceId,
        nonce: nonce,
        issuedAtMs: issuedAtMs,
        audience: deviceAssertionAudience,
      );

      // Lowercased id, four newline separators, no trailing newline.
      const golden = 'jarvis-device-assertion-v1\n'
          '3f2504e0-4f89-41d3-9a0c-0305e82c3301\n'
          '0123456789abcdef-ABCDEF_ghijklmn\n'
          '1700000000123\n'
          'jarvis-token-api-v1';

      expect(payload.text, golden);
      expect(payload.bytes, utf8.encode(golden));
      expect(payload.bytes.last, 0x31); // '1' from the audience, not a trailing 0x0a newline.
      expect(payload.bytes.where((byte) => byte == 0x0a).length, 4);
    });

    test('a lowercase device id is unchanged', () {
      final payload = buildDeviceAssertionPayload(
        deviceId: '3f2504e0-4f89-41d3-9a0c-0305e82c3301',
        nonce: nonce,
        issuedAtMs: issuedAtMs,
        audience: deviceAssertionAudience,
      );
      expect(payload.text.split('\n')[1], '3f2504e0-4f89-41d3-9a0c-0305e82c3301');
    });

    test('text is suitable for the Android signing bridge', () {
      final payload = buildDeviceAssertionPayload(
        deviceId: deviceId,
        nonce: nonce,
        issuedAtMs: issuedAtMs,
        audience: deviceAssertionAudience,
      );
      // The bridge takes a String and signs its UTF-8 bytes; the two views
      // must describe the same payload.
      expect(utf8.encode(payload.text), payload.bytes);
      expect(payload.text.isEmpty, isFalse);
    });
  });

  group('malformed input is rejected before a payload is built', () {
    test('device id must be a UUID', () {
      for (final bad in const [
        '',
        'not-a-uuid',
        '3f2504e04f8941d39a0c0305e82c3301',
        '3f2504e0-4f89-41d3-9a0c-0305e82c330',
        '3f2504e0-4f89-41d3-9a0c-0305e82c33010',
        '3g2504e0-4f89-41d3-9a0c-0305e82c3301',
        ' 3f2504e0-4f89-41d3-9a0c-0305e82c3301',
        '3f2504e0-4f89-41d3-9a0c-0305e82c3301\n',
      ]) {
        expect(
          () => buildDeviceAssertionPayload(
            deviceId: bad,
            nonce: nonce,
            issuedAtMs: issuedAtMs,
            audience: deviceAssertionAudience,
          ),
          throwsA(isA<DeviceAssertionValidationException>()),
          reason: 'device id: $bad',
        );
      }
    });

    test('nonce must be exactly 32 base64url characters', () {
      for (final bad in const [
        '',
        '0123456789abcdef-ABCDEF_ghijklm', // 31
        '0123456789abcdef-ABCDEF_ghijklmno', // 33
        '0123456789abcdef.ABCDEF_ghijklmn', // '.' is not base64url
        '0123456789abcdef-ABCDEF ghijklmn', // space
      ]) {
        expect(
          () => buildDeviceAssertionPayload(
            deviceId: deviceId,
            nonce: bad,
            issuedAtMs: issuedAtMs,
            audience: deviceAssertionAudience,
          ),
          throwsA(isA<DeviceAssertionValidationException>()),
          reason: 'nonce: $bad',
        );
      }
    });

    test('timestamp must be a non-negative safe integer', () {
      for (final bad in [-1, 9007199254740992, 9007199254740991 * 2]) {
        expect(
          () => buildDeviceAssertionPayload(
            deviceId: deviceId,
            nonce: nonce,
            issuedAtMs: bad,
            audience: deviceAssertionAudience,
          ),
          throwsA(isA<DeviceAssertionValidationException>()),
          reason: 'issuedAtMs: $bad',
        );
      }

      // The boundary itself is valid and printed as a plain decimal string.
      final boundary = buildDeviceAssertionPayload(
        deviceId: deviceId,
        nonce: nonce,
        issuedAtMs: 9007199254740991,
        audience: deviceAssertionAudience,
      );
      expect(boundary.text.split('\n')[3], '9007199254740991');
    });
  });

  group('audience is never trusted from the server', () {
    test('only the fixed server audience is accepted', () {
      for (final bad in const [
        '',
        'jarvis-token-api-v2',
        'JARVIS-TOKEN-API-V1',
        'jarvis-token-api-v1\n',
        ' jarvis-token-api-v1',
        'jarvis-chat-api-v1',
      ]) {
        expect(
          () => buildDeviceAssertionPayload(
            deviceId: deviceId,
            nonce: nonce,
            issuedAtMs: issuedAtMs,
            audience: bad,
          ),
          throwsA(isA<DeviceAssertionValidationException>()),
          reason: 'audience: $bad',
        );
      }
    });

    test('the signed payload always ends with the fixed audience', () {
      final payload = buildDeviceAssertionPayload(
        deviceId: deviceId,
        nonce: nonce,
        issuedAtMs: issuedAtMs,
        audience: deviceAssertionAudience,
      );
      expect(payload.text.endsWith('\n$deviceAssertionAudience'), isTrue);
      expect(deviceAssertionAudience, 'jarvis-token-api-v1');
    });
  });
}
