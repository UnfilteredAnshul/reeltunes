// Local purchase-summary PDF.
//
// Google Play is the merchant of record, so this is deliberately labelled a
// "purchase summary", never a tax invoice. The PDF is built on the phone from
// data already cached by `Entitlements` and saved wherever the user chooses
// through the system file picker. Nothing is emailed, uploaded or queued.

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'entitlements.dart';
import 'purchase_record.dart';

class ReceiptPdf {
  ReceiptPdf._();

  static const _supportEmail = 'contact.unfiltered.anshul@gmail.com';

  /// Filename shown in the system save sheet.
  static String suggestedFileName() {
    final d = DateTime.now();
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return 'ReelTunes-purchase-summary-${d.year}-$mm-$dd.pdf';
  }

  /// Builds the PDF and opens the system "save as" sheet. Returns true when the
  /// file was written, false when the user cancelled. Throws only on a genuine
  /// PDF error; callers show a generic message.
  static Future<bool> saveToDevice() async {
    final bytes = await build();
    final uri = await FilePicker.saveFile(
      dialogTitle: 'Save purchase summary',
      fileName: suggestedFileName(),
      bytes: bytes,
      mimeType: 'application/pdf',
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    return uri != null;
  }

  /// The PDF itself, also used by tests / preview tools.
  static Future<Uint8List> build() async {
    final e = Entitlements.I;
    final doc = pw.Document(
      title: 'ReelTunes purchase summary',
      author: 'ReelTunes',
      creator: 'ReelTunes',
    );
    final blue = PdfColor.fromHex('#0A5CD6');
    final ink = PdfColor.fromHex('#1A1A1A');
    final muted = PdfColor.fromHex('#5C5C5C');
    final rule = PdfColor.fromHex('#D9D9D9');
    final soft = PdfColor.fromHex('#F3F6FC');
    final warnBg = PdfColor.fromHex('#FFF4E0');
    final warnInk = PdfColor.fromHex('#7A4B00');

    pw.Widget line(String label, String value) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 3),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.SizedBox(
                width: 120,
                child: pw.Text(label,
                    style: pw.TextStyle(fontSize: 10, color: muted)),
              ),
              pw.Expanded(
                child: pw.Text(value,
                    style: pw.TextStyle(
                        fontSize: 10.5,
                        color: ink,
                        fontWeight: pw.FontWeight.bold)),
              ),
            ],
          ),
        );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(42, 40, 42, 40),
        build: (ctx) {
          final plan = e.planLabel;
          final price = e.receiptPrice.isNotEmpty
              ? e.receiptPrice
              : 'Shown in Google Play';
          final end = e.subscriptionEndsAt;
          final purchased = e.purchaseDate;
          final original = e.originalPurchaseDate;
          final history = e.purchaseHistory;

          return [
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: pw.BoxDecoration(
                color: blue,
                borderRadius: pw.BorderRadius.circular(8),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('ReelTunes',
                          style: pw.TextStyle(
                              color: PdfColors.white,
                              fontSize: 18,
                              fontWeight: pw.FontWeight.bold)),
                      pw.SizedBox(height: 2),
                      pw.Text('Purchase summary',
                          style: const pw.TextStyle(
                              color: PdfColors.white, fontSize: 11)),
                    ],
                  ),
                  pw.Text(_dateLong(DateTime.now()),
                      style: const pw.TextStyle(
                          color: PdfColors.white, fontSize: 9)),
                ],
              ),
            ),
            pw.SizedBox(height: 18),
            pw.Text('Subscription',
                style: pw.TextStyle(
                    fontSize: 13,
                    color: ink,
                    fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 8),
            pw.Container(
              padding: const pw.EdgeInsets.all(14),
              decoration: pw.BoxDecoration(
                color: soft,
                borderRadius: pw.BorderRadius.circular(8),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  line('Plan', plan),
                  line('Amount', price),
                  line('Purchase date',
                      purchased == null ? '—' : _dateLong(purchased)),
                  if (original != null && purchased != null && original != purchased)
                    line('Subscribed since', _dateLong(original)),
                  line('Access until', end == null ? '—' : _dateLong(end)),
                  line('Auto-renew',
                      e.willRenew ? 'On — charged by Google Play' : 'Off'),
                  line('Status', e.statusLabel),
                  line('Store', e.storeLabel),
                  line('Reference',
                      e.productId == null ? '—' : e.productId!),
                ],
              ),
            ),
            if (e.willRenew && end != null) ...[
              pw.SizedBox(height: 12),
              pw.Container(
                padding: const pw.EdgeInsets.all(12),
                decoration: pw.BoxDecoration(
                  color: soft,
                  border: pw.Border.all(color: rule),
                  borderRadius: pw.BorderRadius.circular(8),
                ),
                child: pw.Text(
                  'Automatic payment: Google Play will charge $price on '
                  '${_dateLong(end)} unless you cancel before then.',
                  style: pw.TextStyle(fontSize: 10, color: ink),
                ),
              ),
            ],
            if (e.sandboxPurchase) ...[
              pw.SizedBox(height: 12),
              pw.Container(
                padding: const pw.EdgeInsets.all(12),
                decoration: pw.BoxDecoration(
                  color: warnBg,
                  borderRadius: pw.BorderRadius.circular(8),
                ),
                child: pw.Text(
                  'SANDBOX / TEST PURCHASE — no money was charged. This copy '
                  'exists only because ReelTunes was tested through the '
                  'RevenueCat Test Store or a Google Play licence tester. It is '
                  'not proof of payment.',
                  style: pw.TextStyle(
                      fontSize: 10,
                      color: warnInk,
                      fontWeight: pw.FontWeight.bold),
                ),
              ),
            ],
            pw.SizedBox(height: 12),
            pw.Container(
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: rule),
                borderRadius: pw.BorderRadius.circular(8),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('About this document',
                      style: pw.TextStyle(
                          fontSize: 10.5,
                          color: ink,
                          fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(height: 4),
                  pw.Text(
                    'Google Play is the merchant of record for this purchase. '
                    'This is a purchase summary generated by ReelTunes on your '
                    'device. It is not a tax invoice, and it is not a Google '
                    'Play receipt. Google Play issues the official receipt and '
                    'invoice for every purchase; those are available in your '
                    'Google Play account and in the email Google sends you.',
                    style: pw.TextStyle(fontSize: 9.5, color: muted, lineSpacing: 2),
                  ),
                  pw.SizedBox(height: 6),
                  pw.Text(
                    'Manage or cancel: Google Play → Payments & subscriptions, '
                    'or play.google.com/store/account/subscriptions. '
                    'Cancelling stops the next renewal; access continues until '
                    'the date above. Refunds are handled by Google Play under '
                    'its refund policy.',
                    style: pw.TextStyle(fontSize: 9.5, color: muted, lineSpacing: 2),
                  ),
                ],
              ),
            ),
            if (history.length > 1) ...[
              pw.SizedBox(height: 18),
              pw.Text('Purchase history on this device',
                  style: pw.TextStyle(
                      fontSize: 13,
                      color: ink,
                      fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 6),
              pw.Table(
                border: pw.TableBorder.all(color: rule, width: 0.5),
                columnWidths: const {
                  0: pw.FlexColumnWidth(2.4),
                  1: pw.FlexColumnWidth(1.6),
                  2: pw.FlexColumnWidth(1.6),
                  3: pw.FlexColumnWidth(1.4),
                },
                children: [
                  pw.TableRow(
                    decoration: pw.BoxDecoration(color: soft),
                    children: [
                      _cell('Plan', bold: true),
                      _cell('Amount', bold: true),
                      _cell('Purchase date', bold: true),
                      _cell('Store', bold: true),
                    ],
                  ),
                  for (final r in history.take(8))
                    pw.TableRow(children: [
                      _cell(r.planLabel),
                      _cell(r.priceString.isEmpty ? '—' : r.priceString),
                      _cell(_dateLong(r.purchasedAt)),
                      _cell(r.storeLabel),
                    ]),
                ],
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                'This list is kept only on this device and is cleared when the '
                'app is uninstalled. Google Play and RevenueCat keep the '
                'authoritative purchase records.',
                style: pw.TextStyle(fontSize: 8.5, color: muted),
              ),
            ],
            pw.SizedBox(height: 18),
            pw.Divider(color: rule, thickness: 0.5),
            pw.SizedBox(height: 4),
            pw.Text(
              'Questions about this purchase: $_supportEmail\n'
              'Generated by ReelTunes on ${_dateTimeLong(DateTime.now())}.',
              style: pw.TextStyle(fontSize: 8.5, color: muted, lineSpacing: 2),
            ),
          ];
        },
      ),
    );
    return doc.save();
  }

  static pw.Widget _cell(String text, {bool bold = false}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        child: pw.Text(text,
            style: pw.TextStyle(
                fontSize: 8.5,
                color: PdfColor.fromHex('#1A1A1A'),
                fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
      );

  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  static String _dateLong(DateTime d) =>
      '${d.day} ${_months[d.month - 1]} ${d.year}';

  static String _dateTimeLong(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    final ampm = d.hour < 12 ? 'am' : 'pm';
    return '${_dateLong(d)}, $h:$m $ampm';
  }
}

/// Convenience for the paywall: the newest record, or a synthetic one built
/// from the live entitlement when history is empty (for example after a
/// restore on a fresh install).
PurchaseRecord? currentPurchaseRecord() {
  final e = Entitlements.I;
  if (e.purchaseHistory.isNotEmpty) return e.purchaseHistory.first;
  if (!e.purchased || e.purchaseDate == null) return null;
  return PurchaseRecord(
    productId: e.productId ?? 'reeltunes_pro',
    planLabel: e.planLabel,
    priceString: e.receiptPrice,
    purchasedAt: e.purchaseDate!,
    expiresAt: e.subscriptionEndsAt,
    willRenew: e.willRenew,
    sandbox: e.sandboxPurchase,
    storeLabel: e.storeLabel,
  );
}
