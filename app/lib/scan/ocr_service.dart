import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../ai/llm_provider.dart';

/// Scan-to-entry pipeline:
///   photo → on-device OCR → LLM structuring → prefill data for review.
/// Without an AI key, OCR text is still returned for manual assist.
class StructuredDocument {
  final String docType; // receipt | bill | invoice | unknown
  final String? vendor;
  final DateTime? date;
  final double? amount;
  final String? categoryHint;
  final List<Map<String, String>> lines;

  const StructuredDocument({
    this.docType = 'unknown',
    this.vendor,
    this.date,
    this.amount,
    this.categoryHint,
    this.lines = const [],
  });
}

class OcrService {
  final TextRecognizer _recognizer = TextRecognizer(script: TextRecognitionScript.latin);

  Future<String> extractText(String imagePath) async {
    final inputImage = InputImage.fromFilePath(imagePath);
    final result = await _recognizer.processImage(inputImage);
    return result.text;
  }

  void dispose() => _recognizer.close();
}

final ocrServiceProvider = Provider<OcrService>((ref) {
  final s = OcrService();
  ref.onDispose(s.dispose);
  return s;
});

/// Runs OCR then asks the configured LLM to structure it into JSON.
Future<(StructuredDocument?, String)> scanAndStructure(
    OcrService ocr, AiConfig? cfg, String imagePath) async {
  final rawText = await ocr.extractText(imagePath);

  if (cfg == null || rawText.trim().isEmpty) {
    return (null, rawText);
  }

  try {
    final llm = createProvider(cfg);
    final res = await llm.complete(messages: [
      LlmMessage('system', '''
Extract structured data from this OCR text of a financial document.
Reply with ONLY a JSON object, no markdown fences:
{"doc_type":"receipt|bill|invoice|unknown",
 "vendor":"string or null",
 "date":"ISO yyyy-MM-dd or null",
 "total": number in major currency units or null,
 "category_hint":"office|travel|meals|software|fuel|other or null",
 "lines":[{"description":"...","amount":number}]}
'''),
      LlmMessage('user', rawText),
    ], temperature: 0);

    var txt = res.text?.trim() ?? '';
    if (txt.startsWith('```')) {
      txt = txt.replaceFirst(RegExp(r'^```(json)?'), '').replaceFirst(RegExp(r'```$'), '').trim();
    }
    final j = jsonDecode(txt) as Map<String, dynamic>;
    final doc = StructuredDocument(
      docType: (j['doc_type'] ?? 'unknown') as String,
      vendor: j['vendor'] as String?,
      date: j['date'] != null ? DateTime.tryParse(j['date'] as String) : null,
      amount: (j['total'] as num?)?.toDouble(),
      categoryHint: j['category_hint'] as String?,
      lines: [
        for (final l in (j['lines'] as List? ?? []))
          {
            'description': '${(l as Map)['description'] ?? ''}',
            'amount': '${l['amount'] ?? ''}',
          }
      ],
    );
    return (doc, rawText);
  } catch (_) {
    return (null, rawText);
  }
}

/// Convenience helper to convert structured doc → expense form prefill.
Map<String, dynamic> expensePrefill(StructuredDocument doc) => {
      'amount': doc.amount,
      'vendor': doc.vendor,
      'date': doc.date,
      'category': doc.categoryHint == null ? null : _catId(doc.categoryHint!),
    };

String? _catId(String hint) => switch (hint.toLowerCase()) {
      'fuel' => 'cat-fuel',
      'meals' => 'cat-meals',
      'travel' => 'cat-travel',
      'software' => 'cat-software',
      'office' => 'cat-office',
      _ => 'cat-other',
    };
