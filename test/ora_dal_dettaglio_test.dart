import 'package:omni_ingestione/documento_grezzo.dart';
import 'package:omni_ingestione/ora_dal_dettaglio.dart';
import 'package:test/test.dart';

/// Il dettaglio di San Marino RTV com'è davvero (2026-11-10): l'ora sta solo
/// qui, dopo «QUANDO», e nel contenitore c'è anche un link con dei numeri.
const _paginaRtv = '''
<html><body><div class="bg-event cell">
  MUSICA
  <h1>Movies - The Show (Teatro Nuovo)</h1>
  <br>Teatro Nuovo di Dogana<br>
  <br><a href="https://www.vivaticket.com/it/ticket/movies-the-show/318481">https://www.vivaticket.com/it/ticket/movies-the-show/318481</a>
  <br><br><strong>QUANDO</strong>
  <br>
      9 gen 2027
      21:00
</div></body></html>''';

const _cfg = ConfigDettaglio(contenitore: '.bg-event', etichetta: 'QUANDO', max: 2);

DocumentoGrezzo _ev(String titolo, DateTime data) => DocumentoGrezzo(
      titolo: titolo,
      url: 'https://www.sanmarinortv.sm/eventi/${titolo.toLowerCase()}',
      data: data,
    );

void main() {
  group('oraDalDettaglio', () {
    test('legge l\'ora dopo «QUANDO» nella pagina RTV', () {
      expect(oraDalDettaglio(_paginaRtv, _cfg), DateTime.utc(2027, 1, 9, 21));
    });

    test('senza ora nel dettaglio → null, non mezzanotte', () {
      final pagina = _paginaRtv.replaceFirst('21:00', '');
      expect(oraDalDettaglio(pagina, _cfg), isNull);
    });

    test('contenitore o etichetta assenti → null', () {
      expect(oraDalDettaglio('<html></html>', _cfg), isNull);
      expect(
        oraDalDettaglio(_paginaRtv.replaceFirst('QUANDO', 'DOVE'), _cfg),
        isNull,
      );
    });

    test('config: senza contenitore non c\'è dettaglio', () {
      expect(ConfigDettaglio.daMappa(null), isNull);
      expect(ConfigDettaglio.daMappa({'etichetta': 'QUANDO'}), isNull);
      final c = ConfigDettaglio.daMappa(
          {'contenitore': '.bg-event', 'etichetta': 'QUANDO', 'max': 5})!;
      expect(c.max, 5);
    });
  });

  group('arricchisciOra', () {
    test('ora già in DB: si riusa, e il dettaglio non si apre', () async {
      // Il guaio che evita: l'upsert del giro riporterebbe a mezzanotte l'ora
      // trovata ai giri prima.
      final doc = _ev('Concerto', DateTime.utc(2026, 11, 20));
      final aperti = <String>[];
      final out = await arricchisciOra(
        [doc],
        cfg: _cfg,
        noti: (chiavi) async => {chiavi.single: DateTime.utc(2026, 11, 20, 21)},
        scarica: (url) async {
          aperti.add(url);
          return _paginaRtv;
        },
      );
      expect(out.single.data, DateTime.utc(2026, 11, 20, 21));
      expect(aperti, isEmpty);
    });

    test('nuovo: si apre il dettaglio e si prende l\'ora dello stesso giorno',
        () async {
      final out = await arricchisciOra(
        [_ev('Movies', DateTime.utc(2027, 1, 9))],
        cfg: _cfg,
        noti: (_) async => {},
        scarica: (_) async => _paginaRtv,
      );
      expect(out.single.data, DateTime.utc(2027, 1, 9, 21));
    });

    test('un\'ora di un ALTRO giorno nel dettaglio non si prende', () async {
      final out = await arricchisciOra(
        [_ev('Movies', DateTime.utc(2027, 1, 10))],
        cfg: _cfg,
        noti: (_) async => {},
        scarica: (_) async => _paginaRtv,
      );
      expect(out.single.data, DateTime.utc(2027, 1, 10));
    });

    test('tetto per giro: i nuovi prima, dal più vicino', () async {
      final aperti = <String>[];
      final docs = [
        _ev('Vecchio', DateTime.utc(2026, 11, 12)), // in DB senza ora
        _ev('Lontano', DateTime.utc(2026, 12, 30)),
        _ev('Vicino', DateTime.utc(2026, 11, 15)),
        _ev('Medio', DateTime.utc(2026, 11, 25)),
      ];
      await arricchisciOra(
        docs,
        cfg: _cfg,
        noti: (chiavi) async => {
          for (final k in chiavi)
            if (k.startsWith('vecchio')) k: DateTime.utc(2026, 11, 12),
        },
        scarica: (url) async {
          aperti.add(url.split('/').last);
          return '<html></html>';
        },
        giro: 0,
      );
      expect(aperti, ['vicino', 'medio']);
    });

    test('quelli in DB senza ora girano: giri diversi, eventi diversi',
        () async {
      // Una mostra senza orario nemmeno nel dettaglio non deve occupare il
      // tetto a ogni giro.
      final docs = [
        for (var g = 1; g <= 6; g++) _ev('Mostra$g', DateTime.utc(2026, 11, g)),
      ];
      Future<List<String>> giro(int n) async {
        final aperti = <String>[];
        await arricchisciOra(
          docs,
          cfg: _cfg,
          noti: (chiavi) async => {
            for (final k in chiavi) k: DateTime.utc(2026, 11, 1),
          },
          scarica: (url) async {
            aperti.add(url.split('/').last);
            return '<html></html>';
          },
          giro: n,
        );
        return aperti;
      }

      final visti = {...await giro(0), ...await giro(1), ...await giro(2)};
      expect(visti, hasLength(6));
    });

    test('un dettaglio che fallisce lascia l\'evento com\'era', () async {
      final doc = _ev('Rotto', DateTime.utc(2026, 11, 20));
      final out = await arricchisciOra(
        [doc],
        cfg: _cfg,
        noti: (_) async => {},
        scarica: (_) async => throw StateError('403'),
      );
      expect(out.single.data, DateTime.utc(2026, 11, 20));
    });

    test('chi ha già l\'ora dall\'elenco non si tocca', () async {
      final doc = _ev('Con ora', DateTime.utc(2026, 11, 20, 18, 30));
      var chiesto = false;
      final out = await arricchisciOra(
        [doc],
        cfg: _cfg,
        noti: (_) async {
          chiesto = true;
          return {};
        },
        scarica: (_) async => _paginaRtv,
      );
      expect(identical(out.single, doc), isTrue);
      expect(chiesto, isFalse);
    });
  });
}
