import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../ai/ai_settings.dart';
import '../../ai/llm_provider.dart' show ProviderKind;
import '../../sync/sync_engine.dart';
import '../../theme/theme.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeControllerProvider);
    final ai = ref.watch(aiSettingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Appearance', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<AppThemeMode>(
          segments: const [
            ButtonSegment(value: AppThemeMode.system, icon: Icon(Icons.brightness_auto), label: Text('System')),
            ButtonSegment(value: AppThemeMode.light, icon: Icon(Icons.light_mode), label: Text('Light')),
            ButtonSegment(value: AppThemeMode.dark, icon: Icon(Icons.dark_mode), label: Text('Dark')),
            ButtonSegment(value: AppThemeMode.amoled, icon: Icon(Icons.contrast), label: Text('AMOLED')),
          ],
          selected: {theme.mode},
          onSelectionChanged: (s) =>
              ref.read(themeControllerProvider.notifier).setMode(s.first),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final accent in AppAccent.values)
              ChoiceChip(
                label: Text(accent.label),
                selected: theme.accent == accent,
                avatar: CircleAvatar(backgroundColor: accent.seed),
                onSelected: (_) =>
                    ref.read(themeControllerProvider.notifier).setAccent(accent),
              ),
          ],
        ),
        const Divider(height: 32),
        Text('AI assistant (bring your own key)',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          ai.hasKey
              ? 'Configured ✓ — keys stay in this device\'s secure storage.'
              : 'Not configured — the app still works offline with basic commands.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        _AiSettingsForm(initial: ai),
        const Divider(height: 32),
        Text('Sync', style: Theme.of(context).textTheme.titleMedium),
        const _SyncSection(),
      ]),
    );
  }
}

class _SyncSection extends ConsumerStatefulWidget {
  const _SyncSection();

  @override
  ConsumerState<_SyncSection> createState() => _SyncSectionState();
}

class _SyncSectionState extends ConsumerState<_SyncSection> {
  final _urlCtrl = TextEditingController();
  bool _pairing = false;

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(syncEngineProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Icon(switch (sync.status) {
          SyncStatus.disabled => Icons.cloud_off,
          SyncStatus.idle => Icons.cloud_done,
          SyncStatus.syncing => Icons.sync,
          SyncStatus.error => Icons.error_outline,
        }, size: 18, color: sync.status == SyncStatus.error
            ? Theme.of(context).colorScheme.error : null),
        const SizedBox(width: 8),
        Expanded(child: Text(
          sync.status == SyncStatus.disabled
              ? sync.message
              : '${sync.message}'
                  '${sync.lastSync != null ? ' · ${sync.lastSync!.toLocal().toString().substring(0, 16)}' : ''}'
                  '${sync.pendingOps > 0 ? ' · ${sync.pendingOps} pending' : ''}',
          style: Theme.of(context).textTheme.bodySmall,
        )),
      ]),
      const SizedBox(height: 8),
      if (sync.status == SyncStatus.disabled) ...[
        TextField(
          controller: _urlCtrl,
          decoration: const InputDecoration(
            labelText: 'Self-hosted server URL',
            hintText: 'http://192.168.1.20:8420',
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          icon: _pairing
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.link, size: 18),
          label: const Text('Pair with server'),
          onPressed: _pairing ? null : () async {
            setState(() => _pairing = true);
            final err = await ref.read(syncEngineProvider.notifier).pair(_urlCtrl.text);
            setState(() => _pairing = false);
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(err ?? 'Paired — syncing every 60 seconds.')));
          },
        ),
      ] else ...[
        Wrap(spacing: 8, children: [
          FilledButton.tonalIcon(
            icon: const Icon(Icons.sync, size: 18),
            label: const Text('Sync now'),
            onPressed: sync.status == SyncStatus.syncing ? null :
                () => ref.read(syncEngineProvider.notifier).syncNow(),
          ),
          OutlinedButton(
            onPressed: () => ref.read(syncEngineProvider.notifier).unpair(),
            child: const Text('Unpair'),
          ),
        ]),
      ],
      const SizedBox(height: 8),
      Text('Your data lives on this device. Sync only relays encrypted-at-rest '
          'operation logs between your own devices via your own server.',
          style: Theme.of(context).textTheme.bodySmall),
    ]);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }
}

class _AiSettingsForm extends ConsumerStatefulWidget {
  final AiSettingsState initial;
  const _AiSettingsForm({required this.initial});

  @override
  ConsumerState<_AiSettingsForm> createState() => _AiSettingsFormState();
}

class _AiSettingsFormState extends ConsumerState<_AiSettingsForm> {
  late ProviderKind _kind = widget.initial.kind;
  late final TextEditingController _baseCtrl =
      TextEditingController(text: widget.initial.baseUrl);
  late final TextEditingController _modelCtrl =
      TextEditingController(text: widget.initial.model);
  final TextEditingController _keyCtrl = TextEditingController();

  String get _hintUrl => switch (_kind) {
        ProviderKind.anthropic => 'https://api.anthropic.com',
        ProviderKind.google => 'https://generativelanguage.googleapis.com/v1beta',
        _ => 'https://api.openai.com/v1',
      };

  String get _hintModel => switch (_kind) {
        ProviderKind.anthropic => 'claude-sonnet-4-5',
        ProviderKind.google => 'gemini-2.5-flash',
        _ => 'gpt-4o-mini',
      };

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SegmentedButton<ProviderKind>(
        segments: const [
          ButtonSegment(value: ProviderKind.openAiCompatible, label: Text('OpenAI-compat')),
          ButtonSegment(value: ProviderKind.anthropic, label: Text('Anthropic')),
          ButtonSegment(value: ProviderKind.google, label: Text('Google')),
        ],
        selected: {_kind},
        onSelectionChanged: (s) => setState(() => _kind = s.first),
      ),
      const SizedBox(height: 8),
      TextField(controller: _baseCtrl,
          decoration: InputDecoration(labelText: 'Base URL', hintText: _hintUrl)),
      TextField(controller: _modelCtrl,
          decoration: InputDecoration(labelText: 'Model', hintText: _hintModel)),
      TextField(
        controller: _keyCtrl,
        obscureText: true,
        decoration: InputDecoration(
          labelText: widget.initial.hasKey ? 'API key (stored — enter to replace)' : 'API key',
        ),
      ),
      const SizedBox(height: 8),
      FilledButton.icon(
        icon: const Icon(Icons.key),
        label: const Text('Save AI settings'),
        onPressed: () async {
          await ref.read(aiSettingsProvider.notifier).save(
                kind: _kind,
                baseUrl: _baseCtrl.text.trim().isEmpty ? _hintUrl : _baseCtrl.text.trim(),
                model: _modelCtrl.text.trim(),
                apiKey: _keyCtrl.text,
              );
          _keyCtrl.clear();
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('AI settings saved securely.')));
          }
        },
      ),
    ]);
  }

  @override
  void dispose() {
    _baseCtrl.dispose();
    _modelCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }
}
