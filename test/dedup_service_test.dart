import 'package:test/test.dart';
import 'package:omni_ingestione/dedup_service.dart';

/// Mini record per testare la deduplica generica.
class _Doc {
  const _Doc(this.titolo, this.data);
  final String titolo;
  final DateTime data;
}

void main() {
  const service = DedupService();

  group('normalizzaTitolo', () {
    test('minuscolo, accenti e punteggiatura rimossi, spazi compattati', () {
      expect(
        service.normalizzaTitolo('  Città di San Marino: la NOTÍZIA! '),
        'citta di san marino la notizia',
      );
    });
  });

  group('sonoDuplicati', () {
    test('stessa data + titoli quasi identici ⇒ duplicati', () {
      expect(
        service.sonoDuplicati(
          'Sagra della piadina a Borgo Maggiore',
          DateTime(2026, 7, 10),
          'Sagra della piadina a Borgo Maggiore!',
          DateTime(2026, 7, 10, 18, 30),
        ),
        isTrue,
      );
    });

    test('stessa data ma titoli diversi ⇒ non duplicati', () {
      expect(
        service.sonoDuplicati(
          'Concerto in piazza',
          DateTime(2026, 7, 10),
          'Mostra di pittura al museo',
          DateTime(2026, 7, 10),
        ),
        isFalse,
      );
    });

    test('titoli identici ma date diverse ⇒ non duplicati', () {
      expect(
        service.sonoDuplicati(
          'Sagra della piadina',
          DateTime(2026, 7, 10),
          'Sagra della piadina',
          DateTime(2026, 7, 11),
        ),
        isFalse,
      );
    });
  });

  group('chiaveDedup', () {
    test('stesso titolo normalizzato + stesso giorno ⇒ stessa chiave', () {
      final k1 = service.chiaveDedup('Sagra della Piadina!', DateTime(2026, 7, 10, 9));
      final k2 = service.chiaveDedup('sagra della piadina', DateTime(2026, 7, 10, 20));
      expect(k1, k2);
      expect(k1, 'sagra della piadina|2026-07-10');
    });
  });

  group('deduplica (batch)', () {
    test('collassa i duplicati mantenendo la prima occorrenza', () {
      final docs = [
        _Doc('Sagra della piadina a Borgo', DateTime(2026, 7, 10)),
        _Doc('Concerto in piazza', DateTime(2026, 7, 10)),
        _Doc('Sagra della piadina a Borgo!', DateTime(2026, 7, 10)), // dup #1
        _Doc('Sagra della piadina a Borgo', DateTime(2026, 7, 11)), // altra data
      ];
      final out = service.deduplica<_Doc>(
        docs,
        titolo: (d) => d.titolo,
        data: (d) => d.data,
      );
      expect(out.length, 3);
      expect(out[0].titolo, 'Sagra della piadina a Borgo');
      expect(out[1].titolo, 'Concerto in piazza');
      expect(out[2].data.day, 11);
    });
  });
}
