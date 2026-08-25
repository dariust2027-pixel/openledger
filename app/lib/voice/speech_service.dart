import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Push-to-talk + spoken replies. Degrades gracefully: every capability is
/// reported via [available] so the UI can hide controls instead of crashing
/// on platforms without support (e.g. web without mic permission).
class SpeechService {
  final stt.SpeechToText _stt = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool _sttReady = false;
  bool get canListen => _sttReady;

  Future<bool> init() async {
    if (_sttReady) return true;
    try {
      _sttReady = await _stt.initialize();
    } catch (_) {
      _sttReady = false;
    }
    try {
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.5);
    } catch (_) {/* TTS optional */}
    return _sttReady;
  }

  /// Starts listening; returns live partials through [onPartial] and the
  /// final transcript through the returned future.
  Future<String?> listen({
    void Function(String partial)? onPartial,
  }) async {
    if (!_sttReady) return null;
    final completerResult = <String?>[null];
    await _stt.listen(
      listenOptions: stt.SpeechListenOptions(
        localeId: 'en_US',
        partialResults: true,
        cancelOnError: true,
        listenMode: stt.ListenMode.dictation,
      ),
      onResult: (r) {
        if (r.finalResult) {
          completerResult[0] = r.recognizedWords;
        } else {
          onPartial?.call(r.recognizedWords);
        }
      },
    );
    // The caller stops listening via stop(); result delivered by callback.
    return null;
  }

  void stopListening() {
    if (_sttReady) _stt.stop();
  }

  Future<void> speak(String text) async {
    try {
      await _tts.setLanguage('en-US');
      await _tts.speak(text);
    } catch (_) {}
  }

  Future<void> stopSpeaking() => _tts.stop();
}
