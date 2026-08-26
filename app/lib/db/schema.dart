/// SQL DDL for the local SQLite database (applied via drift runtime API).
///
/// Design notes:
/// - All ids are UUID strings generated client-side (sync-friendly).
/// - Money columns are INTEGER minor units.
/// - `updated_at` millis-since-epoch used later by the op-log sync engine.
class Schema {
  static const tables = [
    _customers,
    _items,
    _taxRates,
    _categories,
    _invoices,
    _invoiceLines,
    _expenses,
    _payments,
    _settings,
    _aiActionsLog,
    _opsLog,
  ];

  /// One executable statement per entry (drift's customStatement takes a
  /// single statement at a time).
  static const statements = [
    ...tables,
    _idxInvoicesStatus,
    _idxInvoicesCustomer,
    _idxLinesInvoice,
    _idxPaymentsInvoice,
    _idxExpensesDate,
    _idxOpsSynced,
    defaultCategories,
  ];

  static const _customers = '''
  CREATE TABLE IF NOT EXISTS customers (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT,
    phone TEXT,
    currency TEXT NOT NULL DEFAULT 'USD',
    notes TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )''';

  static const _items = '''
  CREATE TABLE IF NOT EXISTS items (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    sku TEXT,
    unit_price INTEGER NOT NULL DEFAULT 0,
    tax_rate_id TEXT,
    qty_on_hand REAL NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )''';

  static const _taxRates = '''
  CREATE TABLE IF NOT EXISTS tax_rates (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    percent REAL NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )''';

  static const _categories = '''
  CREATE TABLE IF NOT EXISTS categories (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    kind TEXT NOT NULL, -- income | expense
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )''';

  static const _invoices = '''
  CREATE TABLE IF NOT EXISTS invoices (
    id TEXT PRIMARY KEY,
    number TEXT NOT NULL UNIQUE,
    customer_id TEXT NOT NULL REFERENCES customers(id),
    status TEXT NOT NULL DEFAULT 'draft', -- draft|sent|partial|paid|void
    issue_date TEXT NOT NULL,             -- ISO yyyy-MM-dd
    due_date TEXT,
    currency TEXT NOT NULL DEFAULT 'USD',
    subtotal INTEGER NOT NULL DEFAULT 0,
    tax_total INTEGER NOT NULL DEFAULT 0,
    total INTEGER NOT NULL DEFAULT 0,
    notes TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )''';

  static const _invoiceLines = '''
  CREATE TABLE IF NOT EXISTS invoice_lines (
    id TEXT PRIMARY KEY,
    invoice_id TEXT NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    description TEXT NOT NULL,
    qty REAL NOT NULL DEFAULT 1,
    unit_price INTEGER NOT NULL DEFAULT 0,
    tax_percent REAL NOT NULL DEFAULT 0,
    line_total INTEGER NOT NULL DEFAULT 0,
    position INTEGER NOT NULL DEFAULT 0
  )''';

  static const _expenses = '''
  CREATE TABLE IF NOT EXISTS expenses (
    id TEXT PRIMARY KEY,
    date TEXT NOT NULL,
    vendor TEXT,
    category_id TEXT REFERENCES categories(id),
    description TEXT,
    amount INTEGER NOT NULL,
    tax_amount INTEGER NOT NULL DEFAULT 0,
    currency TEXT NOT NULL DEFAULT 'USD',
    payment_method TEXT,
    receipt_path TEXT,
    billable INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )''';

  static const _payments = '''
  CREATE TABLE IF NOT EXISTS payments (
    id TEXT PRIMARY KEY,
    invoice_id TEXT REFERENCES invoices(id) ON DELETE CASCADE,
    expense_id TEXT REFERENCES expenses(id) ON DELETE SET NULL,
    date TEXT NOT NULL,
    amount INTEGER NOT NULL,
    method TEXT,
    reference TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )''';

  static const _settings = '''
  CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT
  )''';

  static const _aiActionsLog = '''
  CREATE TABLE IF NOT EXISTS ai_actions_log (
    id TEXT PRIMARY KEY,
    ts INTEGER NOT NULL,
    input_mode TEXT NOT NULL,   -- voice|text|scan
    transcript TEXT,
    tool_called TEXT,
    args_json TEXT,
    result_status TEXT
  )''';

  /// Append-only operation log — the foundation of the Phase-4 sync engine
  /// and the full audit trail.
  static const _opsLog = '''
  CREATE TABLE IF NOT EXISTS ops_log (
    id TEXT PRIMARY KEY,              -- op uuid
    entity TEXT NOT NULL,             -- customers|invoices|expenses|...
    entity_id TEXT NOT NULL,
    op_type TEXT NOT NULL,            -- create|update|delete|void
    payload_json TEXT,
    device_id TEXT NOT NULL,
    lamport INTEGER NOT NULL,
    ts INTEGER NOT NULL,
    synced INTEGER NOT NULL DEFAULT 0
  )''';

  // Default seed rows inserted on first run (single INSERT statement).
  static const defaultCategories = """
  INSERT OR IGNORE INTO categories (id, name, kind, created_at, updated_at) VALUES
    ('cat-office',   'Office & Supplies', 'expense', 0, 0),
    ('cat-travel',   'Travel',            'expense', 0, 0),
    ('cat-meals',    'Meals',             'expense', 0, 0),
    ('cat-software', 'Software',          'expense', 0, 0),
    ('cat-fuel',     'Fuel',              'expense', 0, 0),
    ('cat-other',    'Other',             'expense', 0, 0),
    ('cat-sales',    'Sales',             'income',  0, 0);
""";

  /* ---------------------- v2: inventory & purchasing ---------------------- */

  static const _vendors = '''
  CREATE TABLE IF NOT EXISTS vendors (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT,
    phone TEXT,
    notes TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )''';

  /// Polymorphic commercial documents:
  /// quote | sales_order | purchase_order | bill
  static const _documents = '''
  CREATE TABLE IF NOT EXISTS documents (
    id TEXT PRIMARY KEY,
    doc_type TEXT NOT NULL,
    number TEXT NOT NULL,
    party_id TEXT NOT NULL,          -- customer (sales) or vendor (purchases)
    status TEXT NOT NULL DEFAULT 'draft',
    date TEXT NOT NULL,
    due_date TEXT,
    currency TEXT NOT NULL DEFAULT 'USD',
    subtotal INTEGER NOT NULL DEFAULT 0,
    tax_total INTEGER NOT NULL DEFAULT 0,
    total INTEGER NOT NULL DEFAULT 0,
    notes TEXT,
    converted_doc_id TEXT,           -- quote -> invoice link
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )''';

  static const _documentLines = '''
  CREATE TABLE IF NOT EXISTS document_lines (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    item_id TEXT,
    description TEXT NOT NULL,
    qty REAL NOT NULL DEFAULT 1,
    unit_price INTEGER NOT NULL DEFAULT 0,
    tax_percent REAL NOT NULL DEFAULT 0,
    line_total INTEGER NOT NULL DEFAULT 0,
    position INTEGER NOT NULL DEFAULT 0
  )''';

  static const _idxDocumentsType =
      'CREATE INDEX IF NOT EXISTS idx_documents_type ON documents(doc_type, status)';
  static const _idxDocumentLinesDoc =
      'CREATE INDEX IF NOT EXISTS idx_document_lines_doc ON document_lines(document_id)';
  static const _idxInvoiceLinesItem =
      'CREATE INDEX IF NOT EXISTS idx_invoice_lines_item ON invoice_lines(item_id)';

  static const statementsV2 = [
    _vendors,
    _documents,
    _documentLines,
    _idxDocumentsType,
    _idxDocumentLinesDoc,
    'ALTER TABLE invoice_lines ADD COLUMN item_id TEXT',
    'ALTER TABLE payments ADD COLUMN doc_id TEXT',
    _idxInvoiceLinesItem,
  ];

  /* -------------------- v3: accountant / manual journals -------------------- */

  static const _journals = '''
  CREATE TABLE IF NOT EXISTS journals (
    id TEXT PRIMARY KEY,
    date TEXT NOT NULL,
    narration TEXT NOT NULL,
    amount INTEGER NOT NULL,
    currency TEXT NOT NULL DEFAULT 'USD',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )''';

  /// Double-entry lines: exactly two lines per MVP entry (debit + credit),
  /// each tied to a category acting as its ledger account.
  static const _journalLines = '''
  CREATE TABLE IF NOT EXISTS journal_lines (
    id TEXT PRIMARY KEY,
    journal_id TEXT NOT NULL REFERENCES journals(id) ON DELETE CASCADE,
    category_id TEXT NOT NULL REFERENCES categories(id),
    side TEXT NOT NULL,           -- debit | credit
    amount INTEGER NOT NULL
  )''';

  static const _idxJournalLinesJournal =
      'CREATE INDEX IF NOT EXISTS idx_journal_lines_journal ON journal_lines(journal_id)';

  static const statementsV3 = [
    _journals,
    _journalLines,
    _idxJournalLinesJournal,
  ];

  /* -------------------- v4: credit-note links + COGS -------------------- */

  /// Credit notes applied against an invoice reduce its outstanding balance.
  static const v4AlterDocumentsAppliedInvoice =
      'ALTER TABLE documents ADD COLUMN applied_invoice_id TEXT';
  static const _idxDocumentsAppliedInvoice =
      'CREATE INDEX IF NOT EXISTS idx_documents_applied ON documents(applied_invoice_id)';

  /// Per-item acquisition cost for COGS reporting.
  static const v4AlterItemsCost =
      'ALTER TABLE items ADD COLUMN cost_minor INTEGER NOT NULL DEFAULT 0';

  static const statementsV4 = [
    v4AlterDocumentsAppliedInvoice,
    _idxDocumentsAppliedInvoice,
    v4AlterItemsCost,
  ];

  static const _idxInvoicesStatus =
      'CREATE INDEX IF NOT EXISTS idx_invoices_status ON invoices(status)';
  static const _idxInvoicesCustomer =
      'CREATE INDEX IF NOT EXISTS idx_invoices_customer ON invoices(customer_id)';
  static const _idxLinesInvoice =
      'CREATE INDEX IF NOT EXISTS idx_lines_invoice ON invoice_lines(invoice_id)';
  static const _idxPaymentsInvoice =
      'CREATE INDEX IF NOT EXISTS idx_payments_invoice ON payments(invoice_id)';
  static const _idxExpensesDate =
      'CREATE INDEX IF NOT EXISTS idx_expenses_date ON expenses(date)';
  static const _idxOpsSynced =
      'CREATE INDEX IF NOT EXISTS idx_ops_synced ON ops_log(synced)';
}
