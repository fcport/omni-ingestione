import 'dart:convert';

import 'package:omni_ingestione/wp_eventi_parser.dart';
import 'package:test/test.dart';

/// Un post nella forma in cui l'API REST lo restituisce con `_fields`.
Map<String, dynamic> post({
  required String titolo,
  required String link,
  String? dataInizio,
  List<String> ricorrenti = const [],
  String? dove,
  String? quando,
  String? ingresso,
  int media = 0,
}) => {
  'id': link.hashCode,
  'link': link,
  'title': {'rendered': titolo},
  'featured_media': media,
  'acf': {
    // ACF non scrive `null` nei campi vuoti: scrive stringa vuota o `false`.
    'data_inizio': dataInizio ?? '',
    'data_fine': '',
    'data_ricorrente': ricorrenti.isEmpty
        ? false
        : [for (final d in ricorrenti) {'data': d}],
    'event_dove': dove ?? '',
    'event_quando': quando ?? '',
    'event_ingresso': ingresso ?? '',
  },
};

void main() {
  final adesso = DateTime.utc(2026, 8, 10, 9, 30);

  group('WpEventiParser', () {
    test('legge la data singola in YYYYMMDD e la mette a mezzanotte UTC', () {
      final d = const WpEventiParser().parse([
        post(titolo: 'Mercatino', link: 'https://x.it/m', dataInizio: '20260812'),
      ], adesso: adesso);

      expect(d, hasLength(1));
      expect(d.single.data, DateTime.utc(2026, 8, 12));
      // UTC, non locale: con la data interpretata nel fuso della macchina il
      // `toUtc()` a valle la porterebbe al giorno prima alle 22:00.
      expect(d.single.data!.isUtc, isTrue);
    });

    test('una riga per occorrenza, non una per Evento', () {
      final d = const WpEventiParser().parse([
        post(
          titolo: 'Visita guidata',
          link: 'https://x.it/v',
          ricorrenti: ['20260812', '20260819', '20260826'],
        ),
      ], adesso: adesso);

      expect(d.map((e) => e.data), [
        DateTime.utc(2026, 8, 12),
        DateTime.utc(2026, 8, 19),
        DateTime.utc(2026, 8, 26),
      ]);
      // Stesso Evento, stesso link: è corretto, la chiave di dedup è
      // titolo|giorno e le tre occorrenze non si annullano fra loro.
      expect(d.map((e) => e.url).toSet(), {'https://x.it/v'});
    });

    test('scarta le date passate e quelle oltre l orizzonte', () {
      final d = const WpEventiParser(giorniAvanti: 10).parse([
        post(
          titolo: 'Rassegna',
          link: 'https://x.it/r',
          ricorrenti: ['20260801', '20260812', '20261130'],
        ),
      ], adesso: adesso);

      expect(d.map((e) => e.data), [DateTime.utc(2026, 8, 12)]);
    });

    test('tiene il giorno di OGGI: un evento di stasera non è passato', () {
      // La data arriva a mezzanotte, cioè "prima" delle 9:30 di adesso. Con un
      // confronto sull'istante invece che sul giorno, ogni evento sparirebbe
      // la mattina stessa in cui si tiene.
      final d = const WpEventiParser().parse([
        post(titolo: 'Stasera', link: 'https://x.it/s', dataInizio: '20260810'),
      ], adesso: adesso);

      expect(d, hasLength(1));
    });

    test('non lascia più di maxOccorrenze repliche dello stesso Evento', () {
      final d = const WpEventiParser(maxOccorrenze: 2).parse([
        post(
          titolo: 'Museo aperto',
          link: 'https://x.it/mu',
          ricorrenti: ['20260812', '20260813', '20260814', '20260815'],
        ),
      ], adesso: adesso);

      expect(d, hasLength(2));
      // Le prime due in ordine di data, non due a caso.
      expect(d.map((e) => e.data), [
        DateTime.utc(2026, 8, 12),
        DateTime.utc(2026, 8, 13),
      ]);
    });

    test('decodifica le entità HTML nel titolo', () {
      final d = const WpEventiParser().parse([
        post(
          titolo: 'Visita &#8220;Oltre il codice&#8221;',
          link: 'https://x.it/e',
          dataInizio: '20260812',
        ),
      ], adesso: adesso);

      expect(d.single.titolo, 'Visita “Oltre il codice”');
    });

    test('compone la descrizione con le parole della Fonte', () {
      final d = const WpEventiParser().parse([
        post(
          titolo: 'Concerto',
          link: 'https://x.it/c',
          dataInizio: '20260812',
          dove: 'Piazza Cavour, Rimini',
          quando: 'i mercoledì alle 21:30',
          ingresso: 'Libero',
        ),
      ], adesso: adesso);

      expect(d.single.luogo, 'Piazza Cavour, Rimini');
      expect(d.single.testo, 'i mercoledì alle 21:30 — Ingresso: Libero');
    });

    test('senza data valida non produce niente', () {
      final d = const WpEventiParser().parse([
        post(titolo: 'Estate a Rimini', link: 'https://x.it/estate'),
        // 31 febbraio: DateTime.utc lo normalizzerebbe al 3 marzo, cioè un
        // giorno che la Fonte non ha mai scritto. Meglio niente di un dato
        // inventato.
        post(titolo: 'Impossibile', link: 'https://x.it/i', dataInizio: '20260231'),
        post(titolo: 'Corta', link: 'https://x.it/k', dataInizio: '2026'),
      ], adesso: adesso);

      expect(d, isEmpty);
    });

    test('attacca la locandina quando il media è noto', () {
      final d = WpEventiParser(
        immagini: const {77: 'https://x.it/foto.jpg'},
      ).parse([
        post(
          titolo: 'Con foto',
          link: 'https://x.it/f',
          dataInizio: '20260812',
          media: 77,
        ),
        post(
          titolo: 'Senza foto',
          link: 'https://x.it/nf',
          dataInizio: '20260813',
          media: 99,
        ),
      ], adesso: adesso);

      expect(d.first.immagine, 'https://x.it/foto.jpg');
      expect(d.last.immagine, isNull);
    });

    test('sopravvive a una risposta che non ha la forma attesa', () {
      final d = const WpEventiParser().parse(
        jsonDecode('[{"link":"https://x.it/a"}, 42, null, {"acf":{}}]')
            as List<dynamic>,
        adesso: adesso,
      );

      expect(d, isEmpty);
    });
  });
}
