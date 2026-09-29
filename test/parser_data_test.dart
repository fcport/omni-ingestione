import 'package:test/test.dart';
import 'package:omni_ingestione/parser_data.dart';
import 'package:omni_ingestione/rss_parser.dart';

void main() {
  group('parseData con rispettaFuso (pubDate delle Notizie)', () {
    test('San Marino RTV scrive +0200: è due ore prima in UTC', () {
      expect(
        parseData('Tue, 29 Sep 2026 10:56:00 +0200', rispettaFuso: true),
        DateTime.utc(2026, 9, 29, 8, 56),
      );
    });

    test('le testate che scrivono +0000 non cambiano', () {
      expect(
        parseData('Tue, 29 Sep 2026 09:15:16 +0000', rispettaFuso: true),
        DateTime.utc(2026, 9, 29, 9, 15, 16),
      );
    });

    test('in inverno +0100, e il giorno può cambiare', () {
      expect(
        parseData('Sun, 1 Nov 2026 00:30:00 +0100', rispettaFuso: true),
        DateTime.utc(2026, 10, 31, 23, 30),
      );
    });

    test('offset coi due punti, negativo, o per nome', () {
      expect(
        parseData('Tue, 29 Sep 2026 10:00:00 -05:00', rispettaFuso: true),
        DateTime.utc(2026, 9, 29, 15),
      );
      expect(
        parseData('Tue, 29 Sep 2026 10:00:00 GMT', rispettaFuso: true),
        DateTime.utc(2026, 9, 29, 10),
      );
      expect(
        parseData('Tue, 29 Sep 2026 10:00:00 CEST', rispettaFuso: true),
        DateTime.utc(2026, 9, 29, 8),
      );
    });

    test('un fuso che non si riconosce lascia la data com\'è scritta', () {
      expect(
        parseData('Tue, 29 Sep 2026 10:00:00 XYZ', rispettaFuso: true),
        DateTime.utc(2026, 9, 29, 10),
      );
    });
  });

  group('parseData senza rispettaFuso (Eventi: orario di parete)', () {
    test('l\'offset si ignora, come prima', () {
      expect(
        parseData('Tue, 29 Sep 2026 10:56:00 +0200'),
        DateTime.utc(2026, 9, 29, 10, 56),
      );
    });

    test('le date in italiano non cambiano', () {
      expect(parseData('27 Luglio 2026'), DateTime.utc(2026, 7, 27));
      expect(parseData('27/07/2026'), DateTime.utc(2026, 7, 27));
    });
  });

  test('il parser RSS applica il fuso del pubDate', () {
    const xml = '''<?xml version="1.0"?><rss><channel><item>
<title>Notizia RTV</title><link>https://www.sanmarinortv.sm/news/x</link>
<pubDate>Tue, 29 Sep 2026 10:56:00 +0200</pubDate>
</item></channel></rss>''';
    expect(
      const RssParser().parse(xml).single.data,
      DateTime.utc(2026, 9, 29, 8, 56),
    );
  });
}
