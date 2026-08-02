import 'dart:io';

import 'package:test/test.dart';
import 'package:omni_ingestione/rss_parser.dart';

void main() {
  late String xml;

  setUpAll(() {
    xml = File('test/fixtures/notizie.rss.xml').readAsStringSync();
  });

  test('estrae un documento per item valido, ignora quelli senza link', () {
    final docs = const RssParser().parse(xml);
    // 4 item nel feed, ma l'ultimo è privo di <link> → 3 documenti.
    expect(docs.length, 3);
  });

  test('mappa titolo, link, immagine (enclosure) e pubDate', () {
    final d = const RssParser().parse(xml).first;
    expect(d.titolo, 'Approvata la nuova legge di bilancio');
    expect(d.url, 'https://example.sm/notizie/bilancio');
    expect(d.immagine, 'https://example.sm/img/bilancio.jpg');
    expect(d.data, isNotNull);
    expect(d.data!.year, 2026);
    expect(d.data!.month, 6);
    expect(d.data!.day, 24);
  });

  test('senza enclosure prende la prima <img> reale da content:encoded', () {
    // 2° item: nessun enclosure/media, foto inline nel corpo. Il placeholder
    // data: va saltato, deve vincere la jpg vera.
    final d = const RssParser().parse(xml)[1];
    expect(d.titolo, 'Lavori sulla Superstrada: deviazioni a Dogana');
    expect(d.immagine, 'https://example.sm/img/superstrada.jpg');
  });
}
