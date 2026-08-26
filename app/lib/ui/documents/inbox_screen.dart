import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../db/providers.dart';

/// Documents / Inbox: every file the app has captured — scanned receipts,
/// attached images. Tap to view full-screen.
class InboxScreen extends ConsumerWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filesAsync = ref.watch(_filesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Documents')),
      body: filesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (files) => files.isEmpty
            ? const Center(
                child: Text('No documents yet.\nScanned receipts appear here.'))
            : GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8),
                itemCount: files.length,
                itemBuilder: (context, i) {
                  final f = files[i];
                  return InkWell(
                    onTap: () => _openFile(context, f),
                    child: Card(
                      margin: EdgeInsets.zero,
                      clipBehavior: Clip.antiAlias,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Expanded(
                          child: f['path'].toString().toLowerCase().endsWith('.pdf')
                              ? const Center(child: Icon(Icons.picture_as_pdf, size: 32))
                              : Image.file(File(f['path'] as String),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => const Center(
                                      child: Icon(Icons.description, size: 32))),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(4),
                          child: Text(f['label'] as String? ?? '',
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall),
                        ),
                      ]),
                    ),
                  );
                },
              ),
      ),
    );
  }

  void _openFile(BuildContext context, Map<String, dynamic> f) {
    final path = f['path'] as String;
    if (path.toLowerCase().endsWith('.pdf')) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PdfViewerScreen(path: path, title: f['label'] as String? ?? 'Document'),
      ));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(f['label'] as String? ?? 'Document')),
        body: Center(child: InteractiveViewer(child: Image.file(File(path)))),
      ),
    ));
  }
}

/// Sources: receipt images attached to expenses + any exported invoice PDFs.
final _filesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(appDbProvider);
  final receipts = await db.rows(
      "SELECT receipt_path AS path, COALESCE(vendor, 'Receipt') AS label, date "
      'FROM expenses WHERE receipt_path IS NOT NULL ORDER BY date DESC');
  final existing = <Map<String, dynamic>>[];
  for (final r in receipts) {
    if (await File(r['path'] as String).exists()) existing.add(r);
  }
  return existing;
});

/// Full-screen PDF viewer (invoices, exported reports, saved documents).
class PdfViewerScreen extends StatefulWidget {
  final String path;
  final String title;
  const PdfViewerScreen({super.key, required this.path, required this.title});

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  int _pages = 0;
  int _page = 1;
  bool _ready = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), actions: [
        if (_ready && _pages > 1)
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: Text('$_page / $_pages')),
          ),
      ]),
      body: PDFView(
        filePath: widget.path,
        enableSwipe: true,
        swipeHorizontal: false,
        autoSpacing: true,
        pageFling: true,
        onPageChanged: (p, total) => setState(() {
          if (p != null) _page = p + 1;
          if (total != null) _pages = total;
        }),
        onRender: (total) => setState(() {
          _pages = total ?? 0;
          _ready = true;
        }),
        onError: (e) => ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open PDF: $e'))),
      ),
    );
  }
}
