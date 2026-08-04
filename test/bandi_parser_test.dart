import 'dart:io';

import 'package:omni_ingestione/bandi_parser.dart';
import 'package:test/test.dart';

/// Fixture: pagina reale di gov.sm scaricata il 20/07/2026, tagliata ai primi
/// 12 bandi. Il markup è quello vero, tag `<p>` malformati compresi: è la
/// ragione per cui il parser lavora sull'albero HTML5 e non a regex.
const _base =
    'https://www.gov.sm/pub2/GovSM/Bandi-Pubblici-di-Reclutamento/'
    'Concorsi-pubblici-e-selezioni.html';

void main() {
  late String htmlGrezzo;

  setUpAll(() {
    htmlGrezzo = File('test/fixtures/bandi.html').readAsStringSync();
  });

  test('estrae i campi del primo bando', () {
    final bandi = const BandiParser().estrai(htmlGrezzo, baseUrl: _base);

    final primo = bandi.first;
    expect(primo.titolo, startsWith('BANDO DI CONCORSO PUBBLICO N.4/2026/CP'));
    expect(primo.repertorio, '4/2026/CP');
    expect(primo.dataEmissione, DateTime.utc(2026, 5, 21));
    expect(primo.scadenza, 'entro le ore 18:00 di lunedì 22 giugno 2026');
    // 18:00 a San Marino in giugno (CEST) = 16:00 UTC.
    expect(primo.scadenzaIl, DateTime.utc(2026, 6, 22, 16, 0));
    expect(primo.scaduto, isTrue);
    expect(primo.allegati.length, 3);
    expect(primo.allegati.first.nome, 'BANDO n.4/2026/CP OPSPTEC - UTCC-AASLP');
    expect(
      primo.allegati.first.url,
      endsWith('BANDO%20n.4_2026_CP%20-%20OPSPTEC%20UTCC_AASLP.pdf'),
    );
  });

  test('il suffisso "- SCADUTO -" diventa un flag, non resta nel titolo', () {
    final bandi = const BandiParser().estrai(htmlGrezzo, baseUrl: _base);
    expect(bandi.every((b) => b.scaduto), isTrue);
    expect(
      bandi.every((b) => !b.titolo.toUpperCase().contains('SCADUT')),
      isTrue,
      reason: 'il titolo mostrato al cittadino non deve contenere "SCADUTO"',
    );
  });

  test('ogni bando ha url di dettaglio e allegati assoluti e .pdf', () {
    final bandi = const BandiParser().estrai(htmlGrezzo, baseUrl: _base);

    for (final b in bandi) {
      expect(b.titolo, isNotEmpty);
      expect(b.url, startsWith('https://'));
      expect(b.allegati, isNotEmpty, reason: '${b.titolo}: nessun PDF');
      for (final a in b.allegati) {
        expect(a.nome, isNotEmpty);
        expect(a.url, startsWith('https://'));
        expect(a.url.toLowerCase(), contains('.pdf'));
      }
    }
  });

  test('scarta il manuale IOL, che è boilerplate ripetuto su ogni bando', () {
    final bandi = const BandiParser().estrai(htmlGrezzo, baseUrl: _base);
    final nomi = bandi.expand((b) => b.allegati).map((a) => a.nome.toLowerCase());
    expect(nomi.any((n) => n.contains('manuale')), isFalse);
  });

  test('limit cappa il risultato ai bandi più recenti', () {
    const parser = BandiParser();
    expect(parser.estrai(htmlGrezzo, baseUrl: _base).length, 10);
    expect(parser.estrai(htmlGrezzo, baseUrl: _base, limit: 3).length, 3);
    expect(parser.estrai(htmlGrezzo, baseUrl: _base, limit: 99).length, 12);
  });

  test('i campi assenti sulla Fonte restano null, non stringhe vuote', () {
    final bandi = const BandiParser().estrai(htmlGrezzo, baseUrl: _base);

    // Il bando animatori non espone repertorio né scadenza strutturata.
    final animatori = bandi.firstWhere((b) => b.titolo.contains('ANIMATORI'));
    expect(animatori.repertorio, isNull);
    expect(animatori.scadenza, isNull);
    expect(animatori.dataEmissione, DateTime.utc(2026, 5, 12));

    // Il termine però c'è, sepolto nella prosa fra due date: "a partire dalle
    // ore 14:00 di giovedì 14 maggio 2026 e sino alle ore 14:00 di giovedì 21
    // maggio 2026". Deve vincere il 21, non il 14.
    expect(
      animatori.scadenzaIl,
      DateTime.utc(2026, 5, 21, 12, 0),
      reason: 'prendere il 14 maggio dichiarerebbe scaduto un bando '
          'aperto ancora per una settimana',
    );

    for (final b in bandi) {
      expect(b.repertorio, anyOf(isNull, isNotEmpty));
      expect(b.scadenza, anyOf(isNull, isNotEmpty));
      expect(b.descrizione, anyOf(isNull, isNotEmpty));
    }
  });

  test('senza baseUrl i link relativi vengono scartati, non emessi rotti', () {
    final bandi = const BandiParser().estrai(htmlGrezzo);
    for (final b in bandi) {
      expect(b.url, startsWith('https://'));
      for (final a in b.allegati) {
        expect(a.url, startsWith('https://'));
      }
    }
  });
}
