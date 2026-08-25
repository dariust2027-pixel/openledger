# OpenLedger — Product & Engineering Plan

> Working title: **OpenLedger** (rename anytime — it's just a project name).
> One-line pitch: *An offline-first, AI-native accounting app you can run entirely by
> talking to it, scanning documents, or typing — on phone, desktop, and web — with
> your data staying local unless you choose to sync.*

---

## 1. Product Vision & Principles

| Principle | Meaning in practice |
|---|---|
| **Offline-first** | App is 100% functional with zero internet. Network is an enhancement, never a requirement. |
| **AI-first** | Every feature is exposed as a "tool" the AI can call. The command bar (voice or text) is the primary interface; screens are secondary. |
| **Data sovereignty** | Single user: data never leaves the device. Power user: self-host the sync server. Subscriber: use our hosted service + AI proxy. |
| **BYO-AI** | Bring Your Own Key — any OpenAI-compatible provider (OpenAI, Anthropic, Gemini, Groq, Ollama, LM Studio). Our SaaS AI is optional, never required. |
| **Simple yet functional UI** | Command bar home screen + shallow navigation. Progressive disclosure: simple by default, powerful on demand. |

### Target users
1. Freelancers / solo business owners who hate bookkeeping (voice + scan users)
2. Privacy-conscious users (offline / self-host)
3. Small teams later (multi-device sync via self-host or SaaS)

---

## 2. Legal / Clean-Room Strategy

- The decompiled Zoho Books APK is used **only as a feature checklist and pattern reference** (what modules an accounting app needs, UX conventions).
- **Zero** code, assets, strings, icons, or layouts are copied.
- All domain code, schemas, protocols, and designs are written from scratch.
- Public knowledge used for design inspiration: standard accounting concepts (double-entry ledger, invoice lifecycle), public REST API conventions.

---

## 3. Tech Stack

| Layer | Technology | Notes |
|---|---|---|
| Client app | **Flutter (Dart)** | Android, iOS, Windows, Web from one codebase |
| State management | **Riverpod** | Compile-safe, testable |
| Local database | **Drift (SQLite)** | Reactive queries, FTS5 full-text search, migrations |
| Sync server | **Go** | Single static binary, embeds SQLite; Postgres option at scale |
| Server auth | Device tokens + TOTP-based account | Simple self-host setup |
| Transport | HTTPS + WebSocket (live sync push) | Op-log protocol over JSON |
| Cloud LLM client | OpenAI-compatible HTTP client | Works with virtually every provider |
| On-device LLM | Gemma 3 1B/4B via MediaPipe / llama.cpp bindings | Optional download |
| Speech-to-text | Platform SpeechRecognizer; whisper.cpp small model (optional offline pack) | |
| Text-to-speech | Platform TTS | Free, all platforms |
| OCR | ML Kit v2 (Android/iOS), Windows.Media.Ocr (Windows), Tesseract WASM (web) | |
| Doc scanning | mobile_scanner / CameraX + ML Kit doc scanner; flat-bed photo pipeline on desktop | |

---

## 4. System Architecture

```
┌─────────────────────────── Flutter App ────────────────────────────┐
│                                                                    │
│  PRESENTATION            DOMAIN                 INFRASTRUCTURE     │
│  ┌──────────────┐   ┌──────────────────┐   ┌───────────────────┐  │
│  │ CommandBar    │   │ ActionRegistry   │   │ AiGateway         │  │
│  │ VoiceOverlay  │→  │  (AI tools =     │→  │  provider adapters│  │
│  │ Screens       │   │   typed funcs)   │   │  BYOK/SaaS/local  │  │
│  │ Reports/Forms │   │ Domain services  │   │ OcrPipeline       │  │
│  │               │   │ Entities+rules   │   │ SpeechService     │  │
│  └──────────────┘   └────────┬─────────┘   └───────────────────┘  │
│                              │                                     │
│                     ┌────────▼─────────┐                           │
│                     │ Drift DB (local) │←— SyncEngine (op-log)     │
│                     └────────┬─────────┘                           │
└──────────────────────────────┼─────────────────────────────────────┘
                        optional HTTPS/WSS
                    ┌──────────▼───────────┐
                    │  Go sync server      │  self-hosted OR SaaS
                    │  accounts, devices,  │
                    │  op-log store, blob  │
                    │  storage (receipts), │
                    │  AI proxy (SaaS only)│
                    └──────────────────────┘
```

### Key architectural decisions

1. **Everything is an Entity + Operation.**
   - Entities: Customer, Invoice, Expense, Item, Payment, TaxRate, Category, Attachment, Note.
   - Every mutation creates an `Operation { id, entity, type(create/update/delete/void), payload, deviceId, timestamp, lamportClock }`.
   - Operations append to a local log → applied to SQLite → synced when online. This gives audit trail, undo, and conflict resolution for free.

2. **Action Registry = the AI contract.**
   - Each domain function (`createInvoice`, `logExpense`, `searchTransactions`, `cashflowReport`, `sendInvoiceReminder`…) is registered once as a typed tool with JSON schema + examples.
   - The conversational layer translates speech/text → tool calls → results narrated back via TTS.
   - Adding a feature automatically makes it voice/AI-controllable. No separate "AI code" per feature.

3. **Sync protocol (op-log).**
   - Client pushes ops since last cursor; server returns ops since client's cursor; both apply idempotently (ops keyed by UUID).
   - Conflicts: per-field LWW within same entity field set; money-critical ops (payments) are append-only events so they merge trivially.
   - Attachments (scanned PDFs/photos): chunked upload to server blob store; content-addressed (SHA-256).

4. **AI Gateway abstraction.**
   ```dart
   abstract class LlmProvider {
     Future<LlmResult> complete(LlmRequest req);   // chat + tool calling
     Stream<String> stream(LlmRequest req);
   }
   ```
   - Adapters: OpenAI-compatible (covers most), Anthropic native, Google native, LocalOnDevice.
   - Config precedence: user key → hosted subscription → on-device fallback.
   - Keys stored in platform secure storage (Keychain / Keystore / DPAPI), NEVER in the DB or sync log.

---

## 5. Data Model (core tables)

```
customers(id, name, email, phone, currency, notes, ...)
items(id, name, sku, unit_price, tax_rate_id, track_inventory, qty_on_hand)
invoices(id, number, customer_id, status[draft/sent/partial/paid/void],
         issue_date, due_date, currency, subtotal, tax_total, total, notes)
invoice_lines(id, invoice_id, item_id, description, qty, unit_price,
              discount_pct, tax_rate_id, line_total)
expenses(id, date, vendor, category_id, amount, currency, tax_amount,
         payment_method, receipt_attachment_id, is_billable, invoice_id?)
payments(id, invoice_id or expense_id, date, amount, method, reference)
tax_rates(id, name, percent, is_compound)
categories(id, name, kind[income/expense], parent_id)
attachments(id, sha256, mime, bytes_local_path, sync_state)
settings(key, value)              -- non-secret prefs
ai_actions_log(id, ts, input_mode[voice/text/scan], transcript,
               tool_called, args_json, result_status)  -- local-only, user-clearable
sync_state(device_id, last_push_cursor, last_pull_cursor, ...)
```

Money handling: store minor units (integers) + currency code; never floats.

---

## 6. AI-First Experience

### Command bar (home screen)
- Placeholder: *"Say or type anything — 'invoice Acme 3 hours of design at $90'"*
- Hold mic button → live transcription → intent parse → confirmation card → execute.
- Everything the bar does is visible as normal UI afterwards (trust & editability).

### Intent flow
```
utterance → STT text → LLM w/ tool schemas → tool_call draft
   → confirmation card (amounts, names highlighted) → execute → TTS summary
```
- Ambiguity policy: the AI must ask when customer/item matches multiple records; never silently guess amounts.
- Offline mode: rule/regex parser handles top ~30 commands locally ("add expense 250 fuel", "unpaid invoices") — cloud LLM not required for basics.

### Scan-to-entry
```
photo/PDF → crop+enhance → OCR (on-device) → raw text+blocks
   → LLM structuring into {type: receipt|bill|invoice, vendor, date,
      lines[], tax, total} JSON schema (constrained decoding where supported)
   → review card (side-by-side image vs parsed fields) → save expense/bill
```
- Without any AI key: saves the scan + OCR text as attachment with manual entry assist (field autofill suggestions).

### Example voice scenarios (acceptance demos)
1. "Log 42 dollars for fuel at Shell yesterday" → expense created.
2. "Who owes me money?" → spoken list of overdue invoices.
3. Scan a paper receipt → structured expense, attached image.
4. "Draft an invoice for Acme, 3 hours consulting at 90" → editable draft.
5. "How did this month compare to last month?" → spoken mini-report.

---

## 7. UI / UX Design

- **Material 3**, light/dark, large touch targets, one-hand friendly.
- Home = command bar + 4 glance cards: Cash in (month), Cash out, Outstanding, Recent activity.
- Bottom nav (mobile): **Home · Money In · Money Out · Reports**. Desktop/web: left rail.
- Every list: pull-to-refresh-free (local reactive queries are instant), search always visible.
- Forms appear as bottom sheets with inline validation; AI pre-fills from context.
- Accessibility: full TalkBack/VoiceOver labels; voice mode usable eyes-free end-to-end for core flows.

### Theming system

**Modes** (user-selectable, persisted in local settings, follows nothing unless told):
| Mode | Background | Use |
|---|---|---|
| System | follows OS setting (light or dark) | default |
| Light | standard Material light | |
| Dark | dark gray surfaces (#121212 family) | default dark |
| AMOLED Dark | true black (#000000) surfaces, zero pixel glow | OLED battery + night use |

**Accents** (independent of mode — any accent works with light/dark/AMOLED):
- **Blue** (default) — trustworthy finance feel
- **Gold** — premium look, especially on Dark/AMOLED
- Emerald, Violet, Copper (expandable list — accents defined as seed colors)

**Implementation**
- Material 3 `ColorScheme.fromSeed(seedColor: accent, brightness: ...)` generates the full palette per combination → no hand-tuned color tables.
- AMOLED = same dark scheme but override `surface`, `surfaceContainer*`, `background` to pure black; keep elevation via subtle borders instead of shadows (shadows invisible on black).
- Theme = `(ThemeMode, AccentColor)` tuple persisted locally and included in sync settings so all devices match.
- Charts/reports read semantic colors from the scheme (`primary`, `tertiary`, error/success tokens) so they adapt automatically.
- Contrast check: gold-on-dark and every accent/mode pair must pass WCAG AA (4.5:1) for text — enforced by a golden test.

---

## 8. Security

- SQLCipher-style encryption at rest (optional passphrase) for local DB.
- Secure storage (Keystore/Keychain/DPAPI) for: API keys, sync tokens, encryption keys.
- Self-host server: HTTPS enforced, per-device tokens, optional E2E encryption phase 2 (server stores encrypted op-log; keys never leave devices).
- Receipt images: app-private storage only.
- AI privacy setting: redact names/emails before sending to cloud LLM (re-hydrate after response).

---

## 9. Platforms & Build Matrix

| Platform | Status | Notes |
|---|---|---|
| Android | Phase 1 | Primary; Play Store + APK sideload |
| Windows | Phase 1 | MSIX installer + portable exe |
| iOS | Phase 2 | Requires macOS hardware for build/sign (or CI service) |
| Web | Phase 3 | Limited: no on-device LLM/whisper; cloud AI + OCR via WASM/server |

Windows build note: Flutter Windows target needs Visual Studio C++ workload (we'll install when we get there).

---

## 10. Roadmap

### Phase 0 — Foundations ✅ DONE
- Flutter project + Riverpod + Drift + local run config
- Go server skeleton (health endpoint, config, Dockerfile)
- Docs: architecture decisions record (docs/PLAN.md)

### Phase 1 — Core ledger, offline ✅ DONE
- Entities CRUD (customers, invoices with lines/tax, expenses, payments, categories)
- Invoice numbering sequences, status lifecycle (draft→sent→partial→paid/void)
- Dashboard cards + reports (cash in/out, outstanding, net)
- Settings: theme system (System/Light/Dark/AMOLED × 5 accents), currency
- Invoice PDF export (pure-Dart pdf package)

### Phase 2 — AI-first layer ✅ DONE
- Action Registry + OpenAI-compatible / Anthropic / Google gateways (BYOK)
- Command bar + confirmation cards (AI can never move money silently)
- Local rules engine for offline basic commands (~30 command patterns)
- ai_actions_log (local-only, user-clearable)

### Phase 3 — Voice & Vision ✅ DONE
- STT integration (platform speech recognition, push-to-talk from any screen)
- TTS narration of AI results
- Scan-to-entry pipeline (OCR → LLM structuring → review form)
- Graceful degradation on platforms without mic/camera support

### Phase 4 — Sync & self-host 🔨 IN PROGRESS
- Go server: device registration + bearer-token auth ✅
- Op-log push/pull endpoints with cursors, idempotent by op-ID ✅
- File-backed persistence, survives restarts; unit tests passing ✅
- [x] Client SyncEngine (push pending ops / pull remote ops, background timer)
- [x] Client idempotent op application (merge into local SQLite)
- [x] Server-side validation re-runs domain rules before accepting ops
- [x] Settings UI: server URL, pairing token, sync-now, last-sync status
- [ ] One-command self-host bundle (single binary + `openledger-server init`)

### Phase 5 — SaaS offering
- Hosted multi-tenant deployment of the same Go binary
- Stripe subscriptions; hosted AI proxy with usage metering
- Team features (roles: owner/accountant/viewer) on the same op-log identity

### Phase 6 — Power features (proposed)
- Multi-currency: per-customer/invoice currency, FX rate capture at txn time,
  realized-gain reporting
- Recurring invoices & scheduled expenses (local scheduler + sync-safe templates)
- Full backup/export-import (encrypted JSON archive; CSV for spreadsheets)
- Richer reports: P&L by category, customer statements, tax-period summaries
- Widgets & quick-actions (home-screen widget: "log expense" shortcut)

### Phase 7 — Release engineering (proposed)
- App icon set + branding pass
- Android: signed AAB for Play Store + sideload APK; Windows: MSIX installer
- CI pipeline (GitHub Actions): test → analyze → build artifacts per commit
- Crash + performance reporting (opt-in, privacy-preserving — Sentry self-host option)
- Onboarding flow: first-run tour (create business profile → pick theme →
  optional AI key → optional sync pairing)

### Definition of done per phase
Feature works offline, has widget/unit tests, passes accessibility pass,
and its domain function is registered in the Action Registry (Phase 2+).

---

## 11. Testing Strategy

- Unit: domain rules (totals, taxes, numbering, op-log replay determinism).
- Golden tests for invoice PDF layout and key screens.
- Sync tests: deterministic simulation (two virtual devices, scripted ops, assert convergence).
- AI eval harness: 50 utterance fixtures → expected tool calls (guards regressions when prompts change).
- Manual matrix: Android device + Windows desktop each phase.

## 12. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| LLM hallucinating financial entries | Confirmation cards mandatory for writes; constrained JSON schema for parses; amounts re-validated by domain rules |
| Provider API drift | Only OpenAI-compatible surface + 2 native adapters; version pinning |
| Sync conflicts confuse users | Conflict banner + side-by-side resolver; append-only money events minimize cases |
| Scope creep toward full ERP | Ruthless: this is invoicing/expenses/reports. Payroll/inventory-lite deferred |
| Solo-dev bandwidth | Phase gates; each phase independently shippable |

## 13. Monetization mapping (your model)

| Tier | What they get | Architecture hook |
|---|---|---|
| Free / BYOK | Full app, offline, self-host sync, own AI keys | Nothing locked |
| Subscribed (SaaS) | Hosted sync + hosted AI proxy + backups | Same Go binary, multi-tenant flag |
| Team (later) | Roles, approvals | Identity already in op-log |
