import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/support/offline_commands.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('answers the time with no network', () async {
    final reply = await runOfflineCommand('what time is it');
    expect(reply, isNotNull);
    expect(reply, contains(':'));
  });

  test('answers the date with no network', () async {
    final reply = await runOfflineCommand('what is the date');
    expect(reply, isNotNull);
    expect(reply, contains('Today is'));
  });

  test('help describes the offline command set', () async {
    final reply = await runOfflineCommand('help');
    expect(reply, contains('flashlight'));
    expect(reply, contains('volume'));
  });

  test('strips wake word and filler before matching', () async {
    final reply = await runOfflineCommand('Jarvis, please tell me the time');
    expect(reply, isNotNull);
    expect(reply, contains(':'));
  });

  test('ignores an empty utterance', () async {
    expect(await runOfflineCommand('   '), isNull);
  });
}
