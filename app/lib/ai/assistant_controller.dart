import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../db/database.dart';
import '../db/providers.dart';
import '../data/customer_repository.dart' show customerRepoProvider;
import 'action_registry.dart';
import 'ai_settings.dart';
import 'llm_provider.dart';
import 'rules_engine.dart';

enum DraftStatus { pending, executed, failed, cancelled }
enum InputMode { text, voice, scan }

/// A parsed-but-not-yet-executed action. Money-touching operations MUST be
/// confirmed by the user before execution — the LLM can never move money
/// silently.
class ActionDraft {
  final String id;
  final String tool;
  final Map<String, dynamic> args;
  final String humanSummary;
  final InputMode mode;
  DraftStatus status;

  ActionDraft({
    required this.id,
    required this.tool,
    required this.args,
    required this.humanSummary,
    this.mode = InputMode.text,
    this.status = DraftStatus.pending,
  });
}

class AssistantController extends Notifier<AsyncValue<ActionDraft?>> {
  @override
  AsyncValue<ActionDraft?> build() => const AsyncData(null);

  Future<ActionDraft?> parse(String utterance, {InputMode mode = InputMode.text}) async {
    final registry = ref.read(actionRegistryProvider);
    final db = ref.read(appDbProvider);

    // 1. Try the cloud/local LLM when configured.
    final cfg = await ref.read(aiSettingsProvider.notifier).loadConfig();
    if (cfg != null) {
      try {
        final llm = createProvider(cfg);
        final res = await llm.complete(
          messages: [
            LlmMessage(
              'system',
              'You are the assistant of a small-business accounting app. '
                  'Prefer calling tools over answering in prose. Today is '
                  '${DateTime.now().toIso8601String().substring(0, 10)}. '
                  'If information is missing for a tool call, ask one short question.',
            ),
            LlmMessage('user', utterance),
          ],
          tools: registry.buildTools(),
        );
        if (res.hasToolCalls) {
          final call = res.toolCalls.first;
          final draft = ActionDraft(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            tool: call.name,
            args: call.arguments,
            humanSummary: _summarize(call.name, call.arguments),
            mode: mode,
          );
          state = AsyncData(draft);
          await _log(db, mode, utterance, call.name, 'drafted');
          return draft;
        }
        // No tool call — treat as a plain answer.
        state = const AsyncData(null);
        await _log(db, mode, utterance, null, 'answered');
        return null;
      } on LlmException {
        // fall through to rules engine
      } catch (_) {
        // fall through to rules engine
      }
    }

    // 2. Offline rules engine.
    final local = RulesEngine(registry, ref.read(customerRepoProvider)).match(utterance);
    if (local != null) {
      final draft = ActionDraft(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        tool: local.tool,
        args: local.args,
        humanSummary: _summarize(local.tool, local.args),
        mode: mode,
      );
      state = AsyncData(draft);
      await _log(db, mode, utterance, local.tool, 'drafted-local');
      return draft;
    }

    state = const AsyncData(null);
    return null;
  }

  /// Executes after user confirmation. Returns result narration.
  Future<String> confirm(ActionDraft draft) async {
    final registry = ref.read(actionRegistryProvider);
    final db = ref.read(appDbProvider);
    try {
      final result = await registry.execute(draft.tool, draft.args,
          onInvoiceCreated: (_) {});
      draft.status = DraftStatus.executed;
      state = AsyncData(draft);
      await _log(db, draft.mode, null, draft.tool, 'executed');
      return result;
    } catch (e) {
      draft.status = DraftStatus.failed;
      state = AsyncData(draft);
      await _log(db, draft.mode, null, draft.tool, 'failed');
      return 'Could not complete: $e';
    }
  }

  void cancel(ActionDraft draft) {
    draft.status = DraftStatus.cancelled;
    state = AsyncData(draft);
  }

  String _summarize(String tool, Map<String, dynamic> args) {
    switch (tool) {
      case 'log_expense':
        return 'Log expense \$${args['amount']}'
            '${args['vendor'] != null ? ' at ${args['vendor']}' : ''}'
            '${args['category'] != null ? ' (${args['category']})' : ''}';
      case 'create_invoice':
        final lines = (args['lines'] as List?) ?? [];
        double total = 0;
        for (final l in lines) {
          total += ((l as Map)['qty'] ?? 1) * ((l)['unit_price'] as num? ?? 0);
        }
        return 'Create invoice for ${args['customer']} — '
            '\$${total.toStringAsFixed(2)}, ${lines.length} line(s)';
      case 'create_customer':
        return 'Create customer "${args['name']}"';
      case 'list_unpaid_invoices':
        return 'Show unpaid invoices';
      case 'monthly_summary':
        return 'Monthly summary';
      default:
        return tool;
    }
  }

  Future<void> _log(AppDatabase db, InputMode mode, String? transcript,
      String? tool, String status) async {
    try {
      await db.exec(
        'INSERT INTO ai_actions_log (id, ts, input_mode, transcript, tool_called, args_json, result_status) '
        'VALUES (?, ?, ?, ?, ?, NULL, ?)',
        [
          DateTime.now().microsecondsSinceEpoch.toString(),
          DateTime.now().millisecondsSinceEpoch,
          mode.name,
          transcript,
          tool,
          status,
        ],
      );
    } catch (_) {/* logging must never break the flow */}
  }
}

final assistantProvider =
    NotifierProvider<AssistantController, AsyncValue<ActionDraft?>>(AssistantController.new);
