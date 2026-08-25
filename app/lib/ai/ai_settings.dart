import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'llm_provider.dart';

/// BYO-AI settings. API keys live ONLY in platform secure storage
/// (Keystore / Keychain / DPAPI) — never in the database, never synced.
class AiSettingsState {
  final ProviderKind kind;
  final String baseUrl;
  final String model;
  final bool keyLoaded;
  final bool hasKey;

  const AiSettingsState({
    this.kind = ProviderKind.openAiCompatible,
    this.baseUrl = '',
    this.model = '',
    this.keyLoaded = false,
    this.hasKey = false,
  });

  AiSettingsState copyWith({
    ProviderKind? kind, String? baseUrl, String? model,
    bool? keyLoaded, bool? hasKey,
  }) => AiSettingsState(
        kind: kind ?? this.kind,
        baseUrl: baseUrl ?? this.baseUrl,
        model: model ?? this.model,
        keyLoaded: keyLoaded ?? this.keyLoaded,
        hasKey: hasKey ?? this.hasKey,
      );
}

const _kKind = 'ai_kind';
const _kBaseUrl = 'ai_base_url';
const _kModel = 'ai_model';
const _kKey = 'ai_api_key';

class AiSettingsController extends Notifier<AiSettingsState> {
  final _secure = const FlutterSecureStorage();

  @override
  AiSettingsState build() {
    _load();
    return const AiSettingsState();
  }

  Future<void> _load() async {
    final kind = await _secure.read(key: _kKind);
    final base = await _secure.read(key: _kBaseUrl) ?? '';
    final model = await _secure.read(key: _kModel) ?? '';
    final hasKey = (await _secure.read(key: _kKey))?.isNotEmpty ?? false;
    state = state.copyWith(
      kind: ProviderKind.values.asNameMap()[kind] ?? ProviderKind.openAiCompatible,
      baseUrl: base,
      model: model,
      keyLoaded: true,
      hasKey: hasKey,
    );
  }

  Future<void> save({
    required ProviderKind kind,
    required String baseUrl,
    required String model,
    String? apiKey,
  }) async {
    await _secure.write(key: _kKind, value: kind.name);
    await _secure.write(key: _kBaseUrl, value: baseUrl.trim());
    await _secure.write(key: _kModel, value: model.trim());
    if (apiKey != null && apiKey.trim().isNotEmpty) {
      await _secure.write(key: _kKey, value: apiKey.trim());
    }
    state = state.copyWith(
      kind: kind,
      baseUrl: baseUrl.trim(),
      model: model.trim(),
      hasKey: apiKey != null && apiKey.trim().isNotEmpty ? true : state.hasKey,
    );
  }

  Future<AiConfig?> loadConfig() async {
    final s = state;
    if (!s.keyLoaded) await _load();
    final key = (await _secure.read(key: _kKey)) ?? '';
    final cfg = AiConfig(kind: s.kind, baseUrl: s.baseUrl, model: s.model, apiKey: key);
    return cfg.isConfigured ? cfg : null;
  }
}

final aiSettingsProvider =
    NotifierProvider<AiSettingsController, AiSettingsState>(AiSettingsController.new);

/// Resolves the active provider at call time; null when not configured.
final llmProviderProvider = Provider<LlmProvider?>((ref) {
  // Not watched for changes inside requests — resolved lazily by callers
  // via ref.read(aiSettingsProvider.notifier).loadConfig().
  return null;
});
