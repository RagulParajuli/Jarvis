import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// The always-listening half of the hands-free start.
///
/// A small zipformer keyword-spotting model runs on the device through
/// sherpa-onnx, so "Jarvis" is heard without a network round trip, without an
/// account and without streaming audio anywhere. It owns the microphone while it
/// listens, which is why the caller stops it before LiveKit starts capturing.
///
/// The model (Apache-2.0, ~5 MB int8) and its BPE vocabulary live in
/// `assets/kws/`. The keyword itself is `keywords.txt`, generated from the
/// model's own vocabulary as `▁JA R VI S`, so no training step is needed.
class WakeWord {
  WakeWord({required this.onDetected});

  static const _sampleRate = 16000;
  static final _logger = Logger('WakeWord');

  /// Copied out of the asset bundle on first run: sherpa-onnx loads models from
  /// real file paths, not from asset bytes.
  static const _modelFiles = <String>[
    'encoder.int8.onnx',
    'decoder.int8.onnx',
    'joiner.int8.onnx',
    'tokens.txt',
    'bpe.model',
    'keywords.txt',
  ];

  final VoidCallback onDetected;

  sherpa.KeywordSpotter? _spotter;
  sherpa.OnlineStream? _stream;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _audio;
  Future<void>? _releasing;
  bool _starting = false;
  bool _bindingsReady = false;
  bool _detected = false;

  /// v1 is a foreground Android feature; elsewhere the app keeps its previous
  /// behaviour of connecting on launch.
  bool get isSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Starts listening. Returns false when no engine could be started, so the
  /// caller can fall back to connecting directly instead of going silent.
  Future<bool> start() async {
    if (!isSupported) return false;
    if (_spotter != null) return true;
    if (_starting) return false;

    // A previous release may still be closing the microphone.
    if (_releasing != null) await _releasing;

    _starting = true;
    _detected = false;
    try {
      final directory = await _modelDirectory();
      if (!_bindingsReady) {
        sherpa.initBindings();
        _bindingsReady = true;
      }

      final spotter = sherpa.KeywordSpotter(
        sherpa.KeywordSpotterConfig(
          feat: const sherpa.FeatureConfig(sampleRate: _sampleRate, featureDim: 80),
          model: sherpa.OnlineModelConfig(
            transducer: sherpa.OnlineTransducerModelConfig(
              encoder: '${directory.path}/encoder.int8.onnx',
              decoder: '${directory.path}/decoder.int8.onnx',
              joiner: '${directory.path}/joiner.int8.onnx',
            ),
            tokens: '${directory.path}/tokens.txt',
            numThreads: 1,
            provider: 'cpu',
            debug: false,
            modelingUnit: 'bpe',
            bpeVocab: '${directory.path}/bpe.model',
          ),
          keywordsFile: '${directory.path}/keywords.txt',
          // Tuned against synthesized speech: 1.5 scores "Jarvis" clearly while
          // leaving ordinary sentences alone.
          keywordsScore: 1.5,
          keywordsThreshold: 0.25,
          maxActivePaths: 4,
          numTrailingBlanks: 1,
        ),
      );

      final recorder = AudioRecorder();
      if (!await recorder.hasPermission()) {
        spotter.free();
        _logger.warning('wake word unavailable: microphone permission was denied');
        return false;
      }

      final audio = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _sampleRate,
          numChannels: 1,
        ),
      );

      _spotter = spotter;
      _stream = spotter.createStream();
      _recorder = recorder;
      _audio = audio.listen(_onAudio, onError: (Object error) {
        _logger.warning('wake word audio error: $error');
      });
      _logger.info('Listening for "Jarvis".');
      return true;
    } catch (error, stackTrace) {
      _logger.warning('wake word unavailable: $error', error, stackTrace);
      await stop();
      return false;
    } finally {
      _starting = false;
    }
  }

  /// Releases the microphone and the native engine. Idempotent, and safe to call
  /// from the detection callback itself: the returned future completes only once
  /// the microphone is really free, so `connect()` can await it instead of racing
  /// the recorder for the device.
  Future<void> stop() {
    final audio = _audio;
    final recorder = _recorder;
    if (audio != null || recorder != null) {
      _audio = null;
      _recorder = null;
      _releasing = _release(audio, recorder);
    }
    return _releasing ?? Future<void>.value();
  }

  Future<void> _release(StreamSubscription<Uint8List>? audio, AudioRecorder? recorder) async {
    try {
      await audio?.cancel();
    } catch (_) {
      // The stream may already be closed; nothing to release.
    }

    final spotter = _spotter;
    _spotter = null;
    _stream?.free();
    _stream = null;
    spotter?.free();

    if (recorder != null) {
      try {
        await recorder.stop();
        await recorder.dispose();
      } catch (error) {
        _logger.fine('could not release the recorder: $error');
      }
    }
  }

  void _onAudio(Uint8List bytes) {
    final spotter = _spotter;
    final stream = _stream;
    if (spotter == null || stream == null || _detected || bytes.length < 2) return;

    final view = ByteData.sublistView(bytes);
    final samples = Float32List(bytes.length ~/ 2);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
    }

    stream.acceptWaveform(samples: samples, sampleRate: _sampleRate);
    while (spotter.isReady(stream)) {
      spotter.decode(stream);
      final result = spotter.getResult(stream);
      if (result.keyword.isEmpty) continue;

      _detected = true;
      _logger.info('Wake word detected: ${result.keyword}');
      // The recorder is holding the microphone; hand it back before the session
      // tries to open the same device.
      unawaited(stop());
      onDetected();
      return;
    }
  }

  /// Resolves the model directory, copying the bundled assets once.
  Future<Directory> _modelDirectory() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}/kws');
    final encoder = File('${directory.path}/encoder.int8.onnx');
    if (await encoder.exists()) return directory;

    await directory.create(recursive: true);
    for (final name in _modelFiles) {
      final data = await rootBundle.load('assets/kws/$name');
      final file = File('${directory.path}/$name');
      await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
    }
    _logger.info('Wake word model unpacked to ${directory.path}');
    return directory;
  }
}
