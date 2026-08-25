import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../ai/assistant_controller.dart';
import '../voice/speech_service.dart';

/// The primary interface: type or hold-to-talk. Every feature is reachable
/// from here; screens are for review and editing, not data entry.
class CommandBar extends ConsumerStatefulWidget {
  const CommandBar({super.key});

  @override
  ConsumerState<CommandBar> createState() => _CommandBarState();
}

class _CommandBarState extends ConsumerState<CommandBar> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final SpeechService _speech = SpeechService();
  bool _listening = false;
  String _partial = '';

  @override
  void initState() {
    super.initState();
    _speech.init();
  }

  Future<void> _submit(String text) async {
    if (text.trim().isEmpty) return;
    _focus.unfocus();
    _controller.clear();
    setState(() => _partial = '');

    final draft = await ref.read(assistantProvider.notifier).parse(
          text,
          mode: _listening ? InputMode.voice : InputMode.text,
        );
    if (!mounted) return;
    if (draft == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Not understood. Try: "log expense 42 fuel" or '
            '"invoice Acme 3 hours consulting at 90". Configure an AI key in '
            'Settings for full natural language.'),
      ));
    } else {
      await _speech.speak('Ready to ${draft.humanSummary.toLowerCase()}. Confirm below.');
    }
  }

  Future<void> _toggleMic() async {
    final ok = await _speech.init();
    if (!ok || !_speech.canListen) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Speech recognition not available on this device.')));
      }
      return;
    }
    if (_listening) {
      _speech.stopListening();
      if (_partial.isNotEmpty) await _submit(_partial);
      setState(() => _listening = false);
      return;
    }
    setState(() {
      _listening = true;
      _partial = '';
    });
    await _speech.listen(onPartial: (p) {
      if (mounted) setState(() => _partial = p);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        TextField(
          controller: _controller,
          focusNode: _focus,
          textInputAction: TextInputAction.send,
          onSubmitted: _submit,
          decoration: InputDecoration(
            hintText: 'Say or type anything… "log expense 42 fuel"',
            prefixIcon: const Icon(Icons.auto_awesome),
            suffixIcon: IconButton(
              tooltip: _listening ? 'Tap to stop' : 'Voice command',
              icon: Icon(
                _listening ? Icons.stop_circle : Icons.mic,
                color: _listening ? scheme.error : scheme.primary,
                size: 28,
              ),
              onPressed: _toggleMic,
            ),
            filled: true,
          ),
        ),
        if (_listening && _partial.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('"$_partial"',
                  style: TextStyle(fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant)),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }
}

/// Confirmation card shown for every parsed action before it executes.
class ConfirmationCard extends ConsumerWidget {
  final ActionDraft draft;
  const ConfirmationCard({super.key, required this.draft});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(Icons.fact_check, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(draft.humanSummary,
                  style: Theme.of(context).textTheme.titleSmall)),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              FilledButton.icon(
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Confirm'),
                onPressed: () async {
                  final result =
                      await ref.read(assistantProvider.notifier).confirm(draft);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(result)));
                },
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () =>
                    ref.read(assistantProvider.notifier).cancel(draft),
                child: const Text('Cancel'),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
