import 'dart:io';

import 'package:omni_ingestione/normativa/archivio_parser.dart';
import 'package:omni_ingestione/normativa/brani.dart';
import 'package:omni_ingestione/normativa/riferimenti.dart';
import 'package:test/test.dart';

String _fixture(String nome) =>
    File('test/fixtures/normativa/$nome').readAsStringSync();
List<int> _byte(String nome) =>
    File('test/fixtures/normativa/$nome').readAsBytesSync();

void main() {
  group('chiavi e citazioni', () {
    test('la famiglia separa le numerazioni che non sono la stessa', () {
      expect(chiave('Legge', 2018, 3), 'o:2018/3');
      expect(chiave('Legge Qualificata', 2018, 3), 'q:2018/3');
      expect(chiave('Legge Costituzionale', 2005, 183), 'c:2005/183');
      expect(chiave('Regolamento', 2025, 9), 'r:2025/9');
      // Decreti di ogni genere condividono la progressione delle leggi.
      expect(chiave('Decreto Delegato', 2025, 159), 'o:2025/159');
      expect(chiave('Decreto-Legge', 2025, 161), 'o:2025/161');
      expect(chiave('Decreto Reggenziale', 2025, 146), 'o:2025/146');
      expect(chiave('Errata corrige', 2025, null), isNull);
    });

    test('le citazioni con la data e con la barra', () {
      final c = citazioni(
        'Visti l\'articolo 5 della Legge Costituzionale n.185/2005 e il '
        'Decreto Delegato 22 marzo 2011, n. 50 e la Legge Qualificata 15 '
        'dicembre 2005 n.184',
      );
      expect(c.map((x) => x.chiaveAtto), ['c:2005/185', 'o:2011/50', 'q:2005/184']);
      expect(c[1].data, DateTime.utc(2011, 3, 22));
    });

    test('un atto non cita sé stesso', () {
      const titolo = 'Decreto Delegato 24 dicembre 2025 n.159 - Modifica della '
          'Legge 25 luglio 2025 n.101 - Recepimento del Regolamento (UE) 2023/1115';
      expect(chiaviCitate(titolo, propria: 'o:2025/159'), ['o:2025/101']);
    });

    test('il tipo in testa al titolo, anche in maiuscolo', () {
      expect(tipoInTesta('DECRETO CONSILIARE 22 dicembre 2025 n.157 - Ratifica'),
          'DECRETO CONSILIARE');
      expect(tipoInTesta('Errata corrige al Decreto Reggenziale'), isNull);
    });
  });

  group('elenco dell\'archivio', () {
    // 🪤 Il server dichiara UTF-8 e manda Windows-1252: decodificata come
    // UTF-8, «modalità» diventa «modalit�» e la ricerca non la trova più.
    test('decodifica Windows-1252, apostrofi tipografici compresi', () {
      expect(decodificaCp1252([0x6D, 0x6F, 0x64, 0x61, 0x6C, 0x69, 0x74, 0xE0]), 'modalità');
      expect(decodificaCp1252([0x92]), '’');
    });

    test('voci, numero, data, tipo e totale dalla pagina vera', () {
      final p = parseElenco(decodificaCp1252(_byte('elenco_2025.html')));
      expect(p.totale, 184);
      expect(p.voci, hasLength(12));

      final dl = p.voci.first;
      expect(dl.titolo, startsWith('Decreto - Legge 29 dicembre 2025 n.161 - Disposizioni urgenti'));
      expect(dl.titolo, contains('modalità'));
      expect(dl.tipo, 'Decreto-Legge');
      expect(dl.numero, 161);
      expect(dl.data, DateTime.utc(2025, 12, 29));
      expect(dl.url,
          'https://www.consigliograndeegenerale.sm/on-line/home/archivio-leggi-decreti-e-regolamenti/documento17156024.html');
      expect(dl.chiaveAtto, 'o:2025/161');
      expect(dl.cita, isEmpty);

      final dd = p.voci.firstWhere((v) => v.numero == 159);
      expect(dd.tipo, 'Decreto Delegato');
      expect(dd.cita, ['o:2025/101']);

      // L'errata corrige non ha numero, ma cita l'atto che corregge: è così
      // che quell'atto risulta «richiamato da».
      final ec = p.voci.firstWhere((v) => v.tipo == 'Errata corrige');
      expect(ec.numero, isNull);
      expect(ec.cita, ['o:2025/146']);
    });

    test("l'URL d'elenco porta l'intervallo come lo costruisce la pagina", () {
      final u = urlElenco(dal: 1990, al: 1994, pagina: 2);
      expect(u.queryParameters['P0_data_ordered'], '[19900101 TO 19941231]');
      expect(u.queryParameters['indicericerca'], '-1');
      expect(u.queryParameters['P0_pagina'], '2');
    });
  });

  group('testi coordinati', () {
    test("l'indice elenca le categorie", () {
      final cat = parseIndiceCoordinati(decodificaCp1252(_byte('indice_coordinati.html')));
      expect(cat.length, greaterThanOrEqualTo(30));
      expect(cat.first.url, contains('testi-coordinati/docCat.'));
    });

    test('una categoria: titoli, documenti e data di aggiornamento', () {
      final voci = parseCategoriaCoordinati(
          decodificaCp1252(_byte('categoria_coordinati.html')), 'Organizzazione PA');
      expect(voci, isNotEmpty);
      expect(voci.every((v) => v.coordinato && v.tipo == 'Testo coordinato'), isTrue);
      expect(voci.every((v) => v.url.contains('/on-line/documento')), isTrue);
      final dd = voci.firstWhere((v) => v.titolo.contains('n.162'));
      expect(dd.cita, ['o:2021/162']);
      expect(dd.aggiornatoAl, DateTime.utc(2024, 4, 15));
      expect(dd.toAtto()['anno'], isNull);
    });

    test('le forme della data di aggiornamento', () {
      expect(aggiornatoAl('(aggiornato al 26 settembre 2025)'), DateTime.utc(2025, 9, 26));
      expect(aggiornatoAl('(aggiornamento a maggio 2026)'), DateTime.utc(2026, 5, 1));
      expect(aggiornatoAl('(Aggiornato 31 ottobre 2022)'), DateTime.utc(2022, 10, 31));
      expect(aggiornatoAl("(aggiornato all'11 aprile 2024)"), DateTime.utc(2024, 4, 11));
      expect(aggiornatoAl('(aggiornata al 12 ottobre 2022)'), DateTime.utc(2022, 10, 12));
    });
  });

  group('brani', () {
    test('decreto-legge del 2025: preambolo e articolo unico', () {
      final b = spezza(_fixture('dl_2025_161.txt'));
      expect(b.map((x) => x.etichetta), ['Preambolo', 'Articolo Unico']);
      expect(b[1].testo, contains('reclutamento'));
      expect(b.map((x) => x.ordine), [0, 1]);
    });

    // Gli atti ribattuti degli anni Sessanta: un articolo per riga, nessuna
    // riga vuota fra uno e l'altro.
    test('decreto del 1960: gli articoli senza righe vuote', () {
      final b = spezza(_fixture('decreto_1960_31.txt'));
      expect(b.map((x) => x.etichetta), ['Preambolo', 'Art. 1', 'Art. 2', 'Art. 3']);
      expect(b[1].testo, contains('colombaccio'));
      expect(b[1].testo, isNot(startsWith('Art.')));
    });

    test('ratifica: allegato a parte, articoli della convenzione, niente perso', () {
      final testo = _fixture('atto_lungo.txt');
      final b = spezza(testo);
      final etichette = b.map((x) => x.etichetta).toList();
      expect(etichette.take(3), ['Preambolo', 'Articolo Unico', 'Allegato A']);
      expect(etichette, containsAll(['Art. 1', 'Art. 2', 'Art. 3', 'Art. 4']));
      expect(b.every((x) => x.testo.length <= maxCaratteriBrano), isTrue);
      // Nessun brano si perde per strada: il testo dei brani copre quello
      // dell'atto (a meno di spazi e a capo).
      String s(String t) => t.replaceAll(RegExp(r'\s+'), '');
      final tot = b.fold<int>(0, (n, x) => n + s(x.testo).length);
      expect(tot / s(pulisci(testo)).length, greaterThan(0.95));
    });

    test('«Articolo 5 della Legge…» a inizio riga è un rimando, non un articolo', () {
      final b = spezza('Art. 1\nIl comma 2 è sostituito.\n'
          'Articolo 5 della Legge 25 luglio 2025 n.101 è abrogato.\n');
      expect(b.map((x) => x.etichetta), ['Art. 1']);
    });

    test('la rubrica fra parentesi entra nell\'etichetta', () {
      final b = spezza('Art. 3\n(Abrogazioni)\n1. È abrogato il Decreto…\n');
      expect(b.single.etichetta, 'Art. 3 (Abrogazioni)');
    });

    test('un articolo lungo si spezza in parti etichettate', () {
      final par = List.filled(120, 'Il contribuente presenta la dichiarazione entro il termine.').join(' ');
      final b = spezza('Art. 7\n$par\n');
      expect(b.length, greaterThan(1));
      expect(b.first.etichetta, 'Art. 7');
      expect(b[1].etichetta, 'Art. 7 (segue)');
    });

    test('le pagine di sole cifre (tabelle di bilancio) si scartano', () {
      final tabella = List.generate(200, (i) => '${1000 + i} 12.345,67 8.901,23').join('\n');
      final b = spezza('Art. 1\nApprovato il bilancio.\n\nALLEGATO A\n$tabella\n');
      // L'allegato fatto di sole cifre non entra: nessuno chiede
      // all'assistente la riga 1.042 del bilancio, e riempirebbe il database.
      expect(b.map((x) => x.etichetta), ['Art. 1']);
    });
  });
}
