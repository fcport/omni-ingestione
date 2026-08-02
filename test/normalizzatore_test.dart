import 'dart:io';

import 'package:test/test.dart';
import 'package:omni_ingestione/documento_grezzo.dart';
import 'package:omni_ingestione/html_extractor.dart';
import 'package:omni_ingestione/normalizzatore.dart';
import 'package:omni_ingestione/rss_parser.dart';

const _selettori = SelettoriHtml(
  item: 'article.evento',
  titolo: '.titolo',
  link: 'a',
  data: '.data',
  luogo: '.luogo',
  immagine: 'img',
  testo: '.descr',
);

void main() {
  const normalizzatore = Normalizzatore();

  group('Notizie (da fixture RSS)', () {
    late List<Map<String, dynamic>> righe;

    setUpAll(() {
      final xml = File('test/fixtures/notizie.rss.xml').readAsStringSync();
      final docs = const RssParser().parse(xml);
      righe = normalizzatore.notizie(
        docs,
        fonteId: 1,
        adesso: DateTime(2026, 6, 25),
      );
    });

    test('deduplica la stessa Notizia uscita su più Fonti (US-19)', () {
      // 3 documenti, di cui due sono la stessa Notizia (stesso giorno + titolo
      // quasi identico) → 2 righe.
      expect(righe.length, 2);
    });

    test('mai testo integrale: estratto ripulito dai tag e troncato (US-17)',
        () {
      final bilancio = righe.firstWhere(
        (r) => (r['titolo'] as String).startsWith('Approvata'),
      );
      final estratto = bilancio['estratto'] as String;
      expect(estratto.contains('<'), isFalse); // niente HTML
      expect(estratto.length, lessThanOrEqualTo(281)); // 280 + ellissi
      expect(estratto.endsWith('…'), isTrue); // troncato, non integrale
    });

    test('ogni riga ha dedup_key e data ISO', () {
      for (final r in righe) {
        expect(r['dedup_key'], isNotNull);
        expect(DateTime.tryParse(r['data'] as String), isNotNull);
        expect(r['fonte_id'], 1);
      }
    });

    test('scarta le Notizie più vecchie di 2 mesi (soglia inclusiva)', () {
      final adesso = DateTime(2026, 6, 25); // soglia → 2026-04-25
      final docs = [
        DocumentoGrezzo(
          titolo: 'Recente',
          url: 'https://x.sm/1',
          data: DateTime(2026, 6, 1),
        ),
        DocumentoGrezzo(
          titolo: 'Al limite',
          url: 'https://x.sm/2',
          data: DateTime(2026, 4, 25),
        ),
        DocumentoGrezzo(
          titolo: 'Vecchia',
          url: 'https://x.sm/3',
          data: DateTime(2026, 3, 1),
        ),
      ];
      final out = normalizzatore.notizie(docs, fonteId: 1, adesso: adesso);
      final titoli = out.map((r) => r['titolo']).toSet();
      expect(titoli, contains('Recente'));
      expect(titoli, contains('Al limite'));
      expect(titoli, isNot(contains('Vecchia')));
    });
  });

  group('Eventi (da fixture HTML)', () {
    late List<Map<String, dynamic>> righe;

    setUpAll(() {
      final htmlGrezzo = File('test/fixtures/eventi.html').readAsStringSync();
      final docs = const HtmlExtractor().estrai(htmlGrezzo, _selettori);
      righe = normalizzatore.eventi(docs, fonteId: 2);
    });

    test('scarta gli Eventi senza data e deduplica (US-24, US-23)', () {
      // 4 card: una senza data (scartata) e una duplicata → 2 righe.
      expect(righe.length, 2);
      final titoli = righe.map((r) => r['titolo']).toList();
      expect(titoli, contains('Sagra della piadina a Borgo'));
      expect(titoli, contains('Concerto al Teatro Titano'));
      expect(
        titoli.any((t) => (t as String).startsWith('Mostra')),
        isFalse,
      );
    });

    test('ogni Evento ha data_inizio valorizzata', () {
      for (final r in righe) {
        expect(DateTime.tryParse(r['data_inizio'] as String), isNotNull);
      }
    });
  });
}
