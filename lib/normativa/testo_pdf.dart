// Dal documento scaricato al testo: PDF con `pdftotext` (poppler-utils), ZIP
// dei testi coordinati aperti al volo.
//
// Perché `pdftotext` e non una libreria Dart: in Dart puro non esiste un
// estrattore di testo da PDF affidabile, e questo è un repo di Dart puro su
// un runner Linux nudo, dove poppler si installa con una riga di apt. Gli atti
// dell'archivio hanno tutti lo strato di testo — anche quelli degli anni
// Sessanta, ribattuti — quindi niente OCR.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

/// Sotto questa lunghezza il PDF non ha testo (una scansione) o il testo non
/// è venuto fuori: l'atto entra lo stesso, col solo titolo, e lo si conta.
const minCaratteriTesto = 80;

/// Il testo di un documento dell'archivio, dai suoi byte.
///
/// I testi coordinati arrivano spesso in uno ZIP con DUE PDF: «CON NOTE» e
/// «SENZA NOTE». Si prende quello SENZA: le note sono la storia delle
/// modifiche, articolo per articolo, e dentro la ricerca diventerebbero il
/// rumore più pertinente di tutti («modificato dall'art. 3 della Legge…»).
Future<String> testoDocumento(List<int> byte) async {
  if (_eZip(byte)) {
    final pdf = pdfDaZip(byte);
    if (pdf == null) throw const FormatException('ZIP senza PDF');
    return testoPdf(pdf);
  }
  return testoPdf(byte);
}

bool _eZip(List<int> b) => b.length > 4 && b[0] == 0x50 && b[1] == 0x4B;

/// Il PDF da usare dentro uno ZIP: quello «SENZA NOTE» se c'è, altrimenti il
/// più grande.
List<int>? pdfDaZip(List<int> byte) {
  final archivio = ZipDecoder().decodeBytes(byte);
  final pdf = archivio.files
      .where((f) => f.isFile && f.name.toLowerCase().endsWith('.pdf'))
      .toList();
  if (pdf.isEmpty) return null;
  final senzaNote = pdf.where((f) => f.name.toUpperCase().contains('SENZA NOTE'));
  final scelto = senzaNote.isNotEmpty
      ? senzaNote.first
      : (pdf..sort((a, b) => b.size.compareTo(a.size))).first;
  return scelto.content as List<int>;
}

/// `pdftotext -enc UTF-8` su un file temporaneo.
Future<String> testoPdf(List<int> byte) async {
  final dir = await Directory.systemTemp.createTemp('omni_pdf_');
  try {
    final f = File('${dir.path}/atto.pdf');
    await f.writeAsBytes(byte, flush: true);
    final r = await Process.run(
      'pdftotext',
      ['-enc', 'UTF-8', '-q', f.path, '-'],
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
    );
    if (r.exitCode != 0) {
      throw ProcessException('pdftotext', [f.path], '${r.stderr}', r.exitCode);
    }
    return r.stdout as String;
  } finally {
    await dir.delete(recursive: true);
  }
}
