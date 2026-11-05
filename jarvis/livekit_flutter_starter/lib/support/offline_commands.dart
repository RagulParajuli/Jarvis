import 'package:url_launcher/url_launcher.dart';

import 'device_bridge.dart';

/// Local actions Jarvis can handle when the remote assistant is unreachable.
///
/// LiveKit, the Gemini realtime model and speech-to-text all live behind a
/// network connection, so with no internet the cloud agent is unreachable.
/// These commands are matched and executed entirely on the device instead,
/// which is exactly when the user still wants "flashlight on" or "play some
/// music" to work.
///
/// The matcher is deliberately small: it covers the handful of commands worth
/// having offline rather than trying to imitate a language model.
Future<String?> runOfflineCommand(String utterance) async {
  final command = _normalise(utterance);
  if (command.isEmpty) return null;

  for (final pattern in _patterns) {
    final match = pattern.expression.firstMatch(command);
    if (match == null) continue;
    return pattern.run(match);
  }

  return _fallback(command);
}

String _normalise(String utterance) {
  var text = utterance.toLowerCase().trim();
  for (final filler in const ['please', 'jarvis', 'for me', 'now']) {
    text = text.replaceAll(RegExp(r'\b' + filler + r'\b'), ' ');
  }
  // Speech engines punctuate what they hear ("Jarvis, ..."), and the patterns
  // below are anchored, so the stray commas have to go before matching.
  text = text.replaceAll(RegExp(r'[,.!?;:"]'), ' ').replaceAll(RegExp(r'[’]'), "'");
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

class _OfflinePattern {
  const _OfflinePattern(this.expression, this.run);

  final RegExp expression;
  final Future<String> Function(RegExpMatch match) run;
}

final _patterns = <_OfflinePattern>[
  // Short replies make local actions feel like part of the same assistant.
  _OfflinePattern(
    RegExp(r"^(?:what(?:'s| is)?(?: the)? time|what time is it|tell me the time|current time|time)$"),
    _runTime,
  ),
  _OfflinePattern(
    RegExp(r"^(?:what(?:'s| is)?(?: the)? date|what day is it(?: today)?|today'?s date|current date|date)$"),
    _runDate,
  ),
  _OfflinePattern(
    RegExp(r"^(?:who are you|what(?:'s| is)? your name|introduce yourself)$"),
        (_) async => "I'm Jarvis, your assistant. What can I do for you?",
  ),
  _OfflinePattern(
    RegExp(r"^(?:how are you|how'?s it going|you there)$"),
    (_) async => 'Still here, buddy. What do you need?',
  ),
  _OfflinePattern(
    RegExp(r'^(?:thanks|thank you|nice one|good job)$'),
    (_) async => 'Anytime, buddy.',
  ),
  _OfflinePattern(
    RegExp(r'^(?:help|what can you do|list commands|offline commands|commands)$'),
    (_) async => _helpText,
  ),

  // Hardware and settings.
  _OfflinePattern(RegExp(r'^(?:turn\s+)?(?:the\s+)?(?:flashlight|torch)\s+(on|off)$'), _runTorch),
  _OfflinePattern(RegExp(r'^(?:turn\s+)?(?:the\s+)?(?:flashlight|torch)\s+([a-z]+)$'), _runTorch),
  _OfflinePattern(RegExp(r'^(?:set\s+)?(?:the\s+)?volume\s+to\s+(\d{1,3})$'), _runVolumeTo),
  _OfflinePattern(RegExp(r'^(?:turn\s+)?(?:the\s+)?volume\s+(up|down|mute|max)$'), _runVolume),
  _OfflinePattern(RegExp(r'^(mute|unmute)$'), _runVolume),
  _OfflinePattern(
    RegExp(r'^(?:turn\s+)?(on|off)\s+(?:the\s+)?(wi-?fi|bluetooth)$'),
    (match) => _runWireless(match.group(2)!, match.group(1)!),
  ),
  _OfflinePattern(
    RegExp(r'^(?:turn\s+)?(?:the\s+)?(wi-?fi|bluetooth)\s+(on|off)$'),
    (match) => _runWireless(match.group(1)!, match.group(2)!),
  ),
  _OfflinePattern(
    RegExp(r'^(?:open|show|launch)\s+(?:the\s+)?(wi-?fi|bluetooth|settings)(?:\s+settings)?$'),
    _runOpenSettings,
  ),

  // Media and local files.
  _OfflinePattern(
    RegExp(r'^(?:next|previous|skip)\s+(?:song|track)$|^(?:pause|resume|stop)\s+(?:the\s+)?(?:music|song|playback)$'),
    _runMedia,
  ),
  _OfflinePattern(RegExp(r'^(?:find|search|look\s+for)\s+(?:my\s+)?(?:files?|songs?|music|videos?|movies?)\s+(.+)$'), _runFind),

  // Apps and websites last, because their patterns are the broadest.
  _OfflinePattern(RegExp(r'^(?:open|launch|start|run)\s+(.+)$'), _runOpen),
  _OfflinePattern(RegExp(r'^(?:play|put\s+on)\s+(.+)$'), _runPlay),
];

const _helpText = 'I can handle: flashlight on or off, volume up, down, mute '
    'or a number, next or pause for music, open an app, play or find a song, '
    'open a website, the time, the date, and opening Settings.';

Future<String> _runTime(RegExpMatch match) async {
  final now = DateTime.now();
  final hour = now.hour == 0 ? 12 : (now.hour > 12 ? now.hour - 12 : now.hour);
  final minute = now.minute.toString().padLeft(2, '0');
  final suffix = now.hour >= 12 ? 'PM' : 'AM';
  return "It's $hour:$minute $suffix.";
}

Future<String> _runDate(RegExpMatch match) async {
  const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  final now = DateTime.now();
  return 'Today is ${weekdays[now.weekday - 1]}, ${now.day} ${months[now.month - 1]} ${now.year}.';
}

Future<String> _runTorch(RegExpMatch match) async {
  final wanted = match.group(1) == 'off' ? 'off' : 'on';
  final result = await DeviceBridge.control('flashlight', wanted);
  if (result['success'] == true) {
    return wanted == 'on' ? 'Torch is on.' : 'Torch is off.';
  }
  return "I couldn't reach the torch on this device.";
}

Future<String> _runVolume(RegExpMatch match) async {
  final action = match.group(1) ?? 'up';
  final result = await DeviceBridge.control('volume', action);
  if (result['success'] == true) return 'Volume $action.';
  return "I couldn't change the volume on this device.";
}

Future<String> _runVolumeTo(RegExpMatch match) async {
  final level = match.group(1)!;
  final result = await DeviceBridge.control('volume', level);
  if (result['success'] == true) return 'Volume set to $level percent.';
  return "I couldn't change the volume on this device.";
}

Future<String> _runWireless(String target, String state) async {
  final section = target.replaceAll('-', '').contains('bluetooth') ? 'bluetooth' : 'wifi';
  final opened = await DeviceBridge.openSettings(section);
  final label = section == 'bluetooth' ? 'Bluetooth' : 'Wi-Fi';
  if (opened['success'] != true) {
    return "Android won't let me switch $label directly, and I couldn't open Settings either.";
  }
  return "Android won't let an app switch $label directly, buddy. I've opened the $label settings so you can toggle it.";
}

Future<String> _runOpenSettings(RegExpMatch match) async {
  final raw = match.group(1)!;
  final section = raw.contains('bluetooth') ? 'bluetooth' : (raw.contains('fi') ? 'wifi' : 'settings');
  final result = await DeviceBridge.openSettings(section);
  return result['success'] == true ? 'Opening Settings.' : "I couldn't open Settings.";
}

Future<String> _runMedia(RegExpMatch match) async {
  final words = match.group(0)!;
  final String action;
  if (words.contains('next') || words.contains('skip')) {
    action = 'next';
  } else if (words.contains('previous')) {
    action = 'previous';
  } else if (words.contains('pause') || words.contains('stop')) {
    action = 'pause';
  } else {
    action = 'play';
  }

  final result = await DeviceBridge.control('media', action);
  if (result['success'] == true) return 'Media $action.';
  return "I couldn't control playback on this device.";
}

Future<String> _runOpen(RegExpMatch match) async {
  final target = match.group(1)!.trim();

  // "open youtube.com" is a website, "open youtube" is an app.
  final looksLikeUrl = target.startsWith('http') || RegExp(r'^[\w-]+(\.[\w-]+)+').hasMatch(target);
  if (looksLikeUrl) {
    final url = target.startsWith('http') ? target : 'https://$target';
    if (await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) {
      return 'Opening $target.';
    }
  }

  final result = await DeviceBridge.openApp(target);
  if (result['success'] == true) return 'Opening ${result['app'] ?? target}.';
  return "I couldn't find an app called $target on this device.";
}

Future<String> _runFind(RegExpMatch match) async {
  final query = match.group(1)!.trim();
  final result = await DeviceBridge.searchMedia(query, kind: _kindFor(query));
  if (result['success'] != true) return "I couldn't search this device's files.";

  final matches = (result['matches'] as List?) ?? const [];
  if (matches.isEmpty) return "I couldn't find anything called $query on this device.";
  if (matches.length == 1) return 'Found ${_nameOf(matches.first)}.';
  return 'Found ${matches.length} matches, starting with ${_nameOf(matches.first)}.';
}

Future<String> _runPlay(RegExpMatch match) async {
  final query = match.group(1)!.trim();
  final result = await DeviceBridge.playMedia(query, kind: _kindFor(query));
  if (result['success'] == true) return 'Playing ${result['title'] ?? query}.';
  return "I couldn't find anything called $query on this device.";
}

String _kindFor(String query) {
  final movie = RegExp(r'\b(movie|film|video)\b').hasMatch(query);
  return movie ? 'video' : 'music';
}

String _nameOf(Object? match) {
  if (match is Map) return '${match['name'] ?? match['title'] ?? 'that file'}';
  return '$match';
}

/// Reached only when nothing above matched. The local command handler cannot
/// answer open-ended questions, so explain the available help without changing
/// the conversation UI.
Future<String> _fallback(String command) async {
  if (DeviceBridge.isNative) {
    return "I can't answer that question yet. I can still help with local actions like "
        '"open youtube", "play some music", "flashlight on" or "volume up". '
        'Say "help" to hear the whole list.';
  }
  return "I can't answer that question right now.";
}
