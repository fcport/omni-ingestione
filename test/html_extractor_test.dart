import 'dart:io';

import 'package:test/test.dart';
import 'package:omni_ingestione/html_extractor.dart';

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
  late String htmlGrezzo;

  setUpAll(() {
    htmlGrezzo = File('test/fixtures/eventi.html').readAsStringSync();
  });

  test('estrae una card per ogni item, mappando i selettori', () {
    final docs = const HtmlExtractor().estrai(htmlGrezzo, _selettori);
    expect(docs.length, 4);

    final primo = docs.first;
    expect(primo.titolo, 'Sagra della piadina a Borgo');
    expect(primo.luogo, 'Piazza Grande');
    expect(primo.url, 'https://example.sm/eventi/piadina');
    expect(primo.immagine, 'https://example.sm/img/piadina.jpg');
    expect(primo.data, DateTime.utc(2026, 7, 10));
  });

  test('una card senza selettore data ha data null', () {
    final docs = const HtmlExtractor().estrai(htmlGrezzo, _selettori);
    final mostra = docs.firstWhere((d) => d.titolo.startsWith('Mostra'));
    expect(mostra.data, isNull);
  });

  test('risolve link e immagini relativi contro baseUrl', () {
    const html =
        '<article class="ev"><a href="/eventi/x"><div class="t">Festa</div>'
        '<img src="/img/x.jpg"></a></article>';
    const sel = SelettoriHtml(
      item: 'article.ev',
      titolo: '.t',
      link: 'a',
      immagine: 'img',
    );

    final relativi = const HtmlExtractor().estrai(html, sel);
    expect(relativi.first.url, '/eventi/x'); // senza base resta relativo

    final assoluti = const HtmlExtractor().estrai(
      html,
      sel,
      baseUrl: 'https://www.sanmarinortv.sm/eventi',
    );
    expect(assoluti.first.url, 'https://www.sanmarinortv.sm/eventi/x');
    expect(assoluti.first.immagine, 'https://www.sanmarinortv.sm/img/x.jpg');
  });

  test('legge l\'immagine da un data-attribute quando la Fonte è lazy', () {
    // Le Fonti con lazy loading mettono in `src` un segnaposto uguale per
    // tutti e l'immagine vera in un data-attribute: senza `@`, ogni scheda
    // arriverebbe col placeholder.
    const html =
        '<article class="ev"><div class="t">Concerto</div>'
        '<img src="/assets/lazy.png" data-lazy="/img/vera.jpg"></article>';

    final placeholder = const HtmlExtractor().estrai(
      html,
      const SelettoriHtml(item: 'article.ev', titolo: '.t', immagine: 'img'),
    );
    expect(placeholder.first.immagine, '/assets/lazy.png');

    final vera = const HtmlExtractor().estrai(
      html,
      const SelettoriHtml(
        item: 'article.ev',
        titolo: '.t',
        immagine: 'img@data-lazy',
      ),
      baseUrl: 'https://www.usc.sm/eventi-san-marino/',
    );
    expect(vera.first.immagine, 'https://www.usc.sm/img/vera.jpg');
  });

  test('legge il titolo da un attributo (testo visibile troncato)', () {
    const html =
        '<article class="ev" data-title="Titolo completo non troncato">'
        '<div class="t">Titolo compl…</div></article>';

    // `.t` legge il testo troncato; `@data-title` l'attributo pieno dell'item.
    final troncato = const HtmlExtractor().estrai(
      html,
      const SelettoriHtml(item: 'article.ev', titolo: '.t'),
    );
    expect(troncato.first.titolo, 'Titolo compl…');

    final pieno = const HtmlExtractor().estrai(
      html,
      const SelettoriHtml(item: 'article.ev', titolo: '@data-title'),
    );
    expect(pieno.first.titolo, 'Titolo completo non troncato');
  });
}
