import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Invoice PDF export using the pure-Dart pdf package (works on every
/// platform; no platform channels involved).
Future<String> exportInvoicePdf(
  Map<String, dynamic> invoice,
  List<Map<String, dynamic>> lines,
) async {
  final doc = pw.Document();

  final number = invoice['number'] as String? ?? 'Invoice';
  final customer = invoice['customer_name'] as String? ?? '';
  final issueDate = invoice['issue_date'] as String? ?? '';

  pw.Widget totalRow(String label, int minor, {bool bold = false}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(label),
              pw.Text('\$${(minor / 100).toStringAsFixed(2)}',
                  style: bold
                      ? pw.TextStyle(fontWeight: pw.FontWeight.bold)
                      : null),
            ]),
      );

  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.a4,
    build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('INVOICE',
                  style: pw.TextStyle(fontSize: 26, fontWeight: pw.FontWeight.bold)),
              pw.Text(number),
            ]),
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
              pw.Text('Issued: $issueDate'),
              if (invoice['due_date'] != null) pw.Text('Due: ${invoice['due_date']}'),
              pw.Text('Status: ${invoice['status']}'),
            ]),
          ]),
          pw.SizedBox(height: 20),
          pw.Text('Billed to:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          pw.Text(customer),
          pw.SizedBox(height: 16),
          pw.TableHelper.fromTextArray(
            headers: ['Description', 'Qty', 'Unit price', 'Amount'],
            data: [
              for (final l in lines)
                [
                  '${l['description']}',
                  '${l['qty']}',
                  '\$${((l['unit_price'] as int) / 100).toStringAsFixed(2)}',
                  '\$${((l['line_total'] as int) / 100).toStringAsFixed(2)}',
                ],
            ],
          ),
          pw.SizedBox(height: 12),
          pw.Container(
            alignment: pw.Alignment.centerRight,
            width: 240,
            child: pw.Column(children: [
              totalRow('Subtotal', invoice['subtotal'] as int? ?? 0),
              totalRow('Tax', invoice['tax_total'] as int? ?? 0),
              pw.Divider(),
              totalRow('Total', invoice['total'] as int? ?? 0, bold: true),
            ]),
          ),
        ]),
  ));

  final bytes = await doc.save();
  final dir = await _bestDir();
  final path = '${dir.path}${Platform.pathSeparator}$number.pdf';
  await File(path).writeAsBytes(bytes);
  return path;
}

Future<Directory> _bestDir() async {
  try {
    final downloads = await getDownloadsDirectory();
    if (downloads != null) return downloads;
  } catch (_) {/* not supported on this platform */}
  return getApplicationDocumentsDirectory();
}
