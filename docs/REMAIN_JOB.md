# OpenLedger — Remaining Jobs (updated after v0.5.0)

## What shipped in v0.5.0 (this release)
- **Delivery Challans** (DC), **Credit Notes** (CN), **Vendor Credits** (VC) — full document engine types with stock effects:
  - challan → stock OUT, credit note → stock IN (sales return), vendor credit → stock OUT (purchase return)
- **Payments screen** with Received/Made tabs (drawer: Sales → Payments Received, Purchases → Payments Made)
- **Banking** screen: Money In / Money Out / Balance cards + unified transaction ledger
- **Manual Journals**: double-entry (debit/credit against categories), schema v3 (`journals`, `journal_lines`), balanced-entry validation
- **Documents Inbox**: grid of scanned receipts from expenses, tap to view
- **New AI voice tools**: `create_vendor`, `create_item`, `stock_level`, `create_document` (all 7 doc types), plus existing customer/invoice/expense tools

## Known cosmetic issues (non-blocking)
- 2 info-level lints in inbox_screen.dart (`__` → `_` in errorBuilder)

## Remaining roadmap (in priority order)

### P1 — correctness before scale
1. **Invoice/doc number collisions on sync** — two devices can both mint INV-0001.
   Fix: device-prefixed numbers (e.g. `INV-{deviceTag}-0001`) or server-allocated sequences.
2. **Server-side op validation** — Go server accepts any pushed op payload; add schema/type checks per entity before applying.
3. **Local DB encryption** — SQLCipher promised, not built.

### P2 — Zoho parity gaps still missing
4. **Blob sync channel** — receipt images don't sync across devices (op-log is text only). Needs multipart upload endpoint + CDN/local storage.
5. **PDF viewer in Documents inbox** — currently a stub snackbar; integrate `flutter_pdfview` or similar.
6. **Multi-line document forms** — doc form sheet supports a single line item; extend to N lines.
7. **Credit note ↔ invoice linking** — apply CN against an invoice to reduce its balance (currently standalone docs).
8. **Bank reconciliation rules** — match imported bank statements to payments/expenses.
9. **COGS + inventory valuation report** — stock movements exist; no cost-of-goods reporting yet.

### P3 — polish
10. Recurring bills/quotes (recurring invoices already done).
11. Customer/vendor statements (PDF of all activity + balance).
12. Multi-currency for documents (invoices have it; documents table has currency column but UI defaults USD).
13. AI tools for journals and bill payment ("pay the Acme bill").

## Key files for whoever picks this up
| Area | File |
|---|---|
| Schema DDL (v1+v2+v3) | `app/lib/db/schema.dart` |
| DB + migrations | `app/lib/db/database.dart` (schemaVersion=3) |
| Document engine | `app/lib/data/documents_repository.dart` |
| Journals | `app/lib/data/journals_repository.dart`, `app/lib/ui/accountant/journals_screen.dart` |
| Banking | `app/lib/ui/banking/banking_screen.dart` |
| Payments tabs | `app/lib/ui/payments/payments_screen.dart` |
| Inbox | `app/lib/ui/documents/inbox_screen.dart` |
| Drawer wiring | `app/lib/ui/root_shell.dart` |
| AI tools | `app/lib/ai/action_registry.dart` |
| Sync server | `server/` (main.go, store.go, handlers.go) |

## Release process
1. Commit + push to `main`
2. `git tag vX.Y.Z && git push origin vX.Y.Z`
3. GitHub Actions builds APK (~10 min); download via `gh run download --dir C:\Users\just2\Downloads\openledger-apk`
