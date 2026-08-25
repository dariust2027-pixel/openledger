import 'dart:convert';
import 'package:http/http.dart' as http;

/// Transport-agnostic LLM interface. Every provider speaks this language;
/// the app never knows which brain it is talking to.
class LlmMessage {
  final String role; // system | user | assistant | tool
  final String content;
  const LlmMessage(this.role, this.content);
}

class LlmToolCall {
  final String name;
  final Map<String, dynamic> arguments;
  const LlmToolCall(this.name, this.arguments);
}

class LlmToolDef {
  final String name;
  final String description;
  final Map<String, dynamic> parameters; // JSON schema
  const LlmToolDef(this.name, this.description, this.parameters);
}

class LlmResult {
  final String? text;
  final List<LlmToolCall> toolCalls;
  const LlmResult({this.text, this.toolCalls = const []});
  bool get hasToolCalls => toolCalls.isNotEmpty;
}

class AiConfig {
  final ProviderKind kind;
  final String baseUrl; // e.g. https://api.openai.com/v1 or http://localhost:11434/v1
  final String model;
  final String apiKey;

  const AiConfig({
    required this.kind,
    required this.baseUrl,
    required this.model,
    this.apiKey = '',
  });

  bool get isConfigured => baseUrl.isNotEmpty && model.isNotEmpty;
}

enum ProviderKind { openAiCompatible, anthropic, google }

abstract class LlmProvider {
  AiConfig get config;
  Future<LlmResult> complete({
    required List<LlmMessage> messages,
    List<LlmToolDef> tools = const [],
    double temperature = 0.2,
  });
}

/* ------------------------- OpenAI-compatible ------------------------- */
/// Works with OpenAI, Groq, Together, Mistral, Ollama, LM Studio, vLLM…
class OpenAiCompatibleProvider implements LlmProvider {
  @override
  final AiConfig config;
  final http.Client _client;

  OpenAiCompatibleProvider(this.config, [http.Client? client])
      : _client = client ?? http.Client();

  @override
  Future<LlmResult> complete({
    required List<LlmMessage> messages,
    List<LlmToolDef> tools = const [],
    double temperature = 0.2,
  }) async {
    final body = {
      'model': config.model,
      'messages': [
        for (final m in messages) {'role': m.role, 'content': m.content},
      ],
      'temperature': temperature,
      if (tools.isNotEmpty)
        'tools': [
          for (final t in tools)
            {
              'type': 'function',
              'function': {
                'name': t.name,
                'description': t.description,
                'parameters': t.parameters,
              },
            },
        ],
      'tool_choice': tools.isEmpty ? null : 'auto',
    };

    final res = await _client.post(
      Uri.parse('${config.baseUrl.replaceAll(RegExp(r'/$'), '')}/chat/completions'),
      headers: {
        'Content-Type': 'application/json',
        if (config.apiKey.isNotEmpty) 'Authorization': 'Bearer ${config.apiKey}',
      },
      body: jsonEncode(body),
    );
    if (res.statusCode != 200) {
      throw LlmException('provider error ${res.statusCode}: ${res.body}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final choice = ((data['choices'] as List?)?.firstOrNull ?? {}) as Map<String, dynamic>;
    final msg = (choice['message'] ?? {}) as Map<String, dynamic>;
    final calls = <LlmToolCall>[];
    for (final tc in (msg['tool_calls'] as List? ?? [])) {
      final fn = (tc as Map<String, dynamic>)['function'] as Map<String, dynamic>;
      calls.add(LlmToolCall(
        fn['name'] as String,
        jsonDecode((fn['arguments'] as String?) ?? '{}') as Map<String, dynamic>,
      ));
    }
    return LlmResult(text: msg['content'] as String?, toolCalls: calls);
  }
}

/* ----------------------------- Anthropic ----------------------------- */
class AnthropicProvider implements LlmProvider {
  @override
  final AiConfig config;
  final http.Client _client;

  AnthropicProvider(this.config, [http.Client? client])
      : _client = client ?? http.Client();

  @override
  Future<LlmResult> complete({
    required List<LlmMessage> messages,
    List<LlmToolDef> tools = const [],
    double temperature = 0.2,
  }) async {
    final system =
        messages.where((m) => m.role == 'system').map((m) => m.content).join('\n');
    final body = {
      'model': config.model,
      'max_tokens': 1024,
      if (system.isNotEmpty) 'system': system,
      'temperature': temperature,
      'messages': [
        for (final m in messages.where((m) => m.role != 'system'))
          {'role': m.role == 'assistant' ? 'assistant' : 'user', 'content': m.content},
      ],
      if (tools.isNotEmpty)
        'tools': [
          for (final t in tools)
            {
              'name': t.name,
              'description': t.description,
              'input_schema': t.parameters,
            },
        ],
    };
    final base = config.baseUrl.contains('anthropic')
        ? config.baseUrl.replaceAll(RegExp(r'/v1/$'), '')
        : 'https://api.anthropic.com';
    final res = await _client.post(
      Uri.parse('${base.replaceAll(RegExp(r'/$'), '')}/v1/messages'),
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': config.apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: jsonEncode(body),
    );
    if (res.statusCode != 200) {
      throw LlmException('provider error ${res.statusCode}: ${res.body}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    String? text;
    final calls = <LlmToolCall>[];
    for (final block in (data['content'] as List? ?? [])) {
      final b = block as Map<String, dynamic>;
      if (b['type'] == 'text') {
        text = (text ?? '') + (b['text'] as String? ?? '');
      } else if (b['type'] == 'tool_use') {
        calls.add(LlmToolCall(
          b['name'] as String,
          (b['input'] as Map<String, dynamic>?) ?? {},
        ));
      }
    }
    return LlmResult(text: text, toolCalls: calls);
  }
}

/* ------------------------------ Google ------------------------------- */
class GoogleProvider implements LlmProvider {
  @override
  final AiConfig config;
  final http.Client _client;

  GoogleProvider(this.config, [http.Client? client]) : _client = client ?? http.Client();

  @override
  Future<LlmResult> complete({
    required List<LlmMessage> messages,
    List<LlmToolDef> tools = const [],
    double temperature = 0.2,
  }) async {
    final system =
        messages.where((m) => m.role == 'system').map((m) => m.content).join('\n');
    final body = {
      'contents': [
        for (final m in messages.where((m) => m.role != 'system'))
          {
            'role': m.role == 'assistant' ? 'model' : 'user',
            'parts': [{'text': m.content}],
          },
      ],
      'generationConfig': {'temperature': temperature},
      if (tools.isNotEmpty)
        'tools': [
          {
            'functionDeclarations': [
              for (final t in tools)
                {
                  'name': t.name,
                  'description': t.description,
                  'parameters': t.parameters,
                },
            ],
          },
        ],
      if (system.isNotEmpty) 'systemInstruction': {'parts': [{'text': system}]},
    };
    final url = '${config.baseUrl.replaceAll(RegExp(r'/$'), '')}'
        '/models/${config.model}:generateContent?key=${config.apiKey}';
    final res = await _client.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (res.statusCode != 200) {
      throw LlmException('provider error ${res.statusCode}: ${res.body}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    String? text;
    final calls = <LlmToolCall>[];
    final candidates = data['candidates'] as List?;
    final content =
        candidates == null || candidates.isEmpty ? null : candidates.first['content'];
    final parts = content == null ? null : content['parts'] as List?;
    for (final part in parts ?? []) {
      final p = part as Map<String, dynamic>;
      if (p['text'] != null) {
        text = (text ?? '') + (p['text'] as String);
      } else if (p['functionCall'] != null) {
        final fc = p['functionCall'] as Map<String, dynamic>;
        calls.add(LlmToolCall(
          fc['name'] as String,
          (fc['args'] as Map<String, dynamic>?) ?? {},
        ));
      }
    }
    return LlmResult(text: text, toolCalls: calls);
  }
}

class LlmException implements Exception {
  final String message;
  LlmException(this.message);
  @override
  String toString() => message;
}

LlmProvider createProvider(AiConfig cfg) => switch (cfg.kind) {
      ProviderKind.anthropic => AnthropicProvider(cfg),
      ProviderKind.google => GoogleProvider(cfg),
      _ => OpenAiCompatibleProvider(cfg),
    };
