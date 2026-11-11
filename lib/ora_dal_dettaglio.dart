import 'package:html/parser.dart' as html;

import 'dedup_service.dart';
import 'documento_grezzo.dart';
import 'parser_data.dart';

/// Come trovare l'ora nella pagina di DETTAGLIO di un Evento, per le Fonti
/// che nell'elenco danno solo il giorno. Viene da `fonte.config.dettaglio`:
///
/// ```json
/// "dettaglio": { "contenitore": ".bg-event", "etichetta": "QUANDO", "max": 8 }
/// ```
///
/// Nasce per San Marino RTV (2026-11-10): nell'elenco l'ora c'era in 1 evento
/// su 38, e 45 eventi su 46 arrivavano in app «senza ora» — mentre la pagina
/// del singolo evento dice «QUANDO 9 gen 2027 21:00».
class ConfigDettaglio {
  const ConfigDettaglio({
    required this.contenitore,
    this.etichetta,
    this.max = 8,
  });

  /// Selettore CSS dell'elemento che contiene la data.
  final String contenitore;

  /// Se c'è, la data si cerca nel testo che la SEGUE (il «QUANDO» di RTV:
  /// nel contenitore c'è anche il resto della scheda, numeri compresi).
  final String? etichetta;

  /// Quante pagine di dettaglio aprire al massimo per giro. Le testate ci
  /// hanno già bloccato quando le richieste sono raddoppiate (agosto 2026):
  /// meglio qualche giro in più per coprire tutto che un 403.
  final int max;

  static ConfigDettaglio? daMappa(Map<String, dynamic>? m) {
    final contenitore = m?['contenitore'];
    if (contenitore is! String || contenitore.isEmpty) return null;
    return ConfigDettaglio(
      contenitore: contenitore,
      etichetta: m!['etichetta'] as String?,
      max: (m['max'] as num?)?.toInt() ?? 8,
    );
  }
}

bool _senzaOra(DateTime d) => d.hour == 0 && d.minute == 0;
bool _stessoGiorno(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// La data con l'ora letta da una pagina di dettaglio, o `null`.
DateTime? oraDalDettaglio(String pagina, ConfigDettaglio cfg) {
  final el = html.parse(pagina).querySelector(cfg.contenitore);
  var testo = el?.text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (testo == null || testo.isEmpty) return null;
  final etichetta = cfg.etichetta;
  if (etichetta != null) {
    final i = testo.indexOf(etichetta);
    if (i < 0) return null;
    testo = testo.substring(i + etichetta.length);
  }
  final d = parseData(testo);
  return d == null || _senzaOra(d) ? null : d;
}

/// Dà l'ora agli Eventi che dall'elenco arrivano col solo giorno.
///
/// Per ognuno, nell'ordine:
/// 1. se in DB c'è già **con un'ora** ([noti], `dedup_key` → `data_inizio`),
///    si riusa quella. Non è un'ottimizzazione: senza, l'upsert del giro
///    riporterebbe a mezzanotte l'ora trovata ai giri prima;
/// 2. altrimenti è un candidato: si apre la pagina di dettaglio, ma al
///    massimo [ConfigDettaglio.max] per giro. Prima quelli che in DB non ci
///    sono ancora (i nuovi, dal più vicino); poi quelli che ci sono ma senza
///    ora, **a rotazione** su [giro]. La rotazione non è un vezzo: un evento
///    che l'ora non ce l'ha nemmeno nel dettaglio (una mostra, una giornata
///    intera) resterebbe candidato per sempre, e i primi in ordine di data
///    occuperebbero il tetto a ogni giro lasciando fuori gli altri.
///
/// Un dettaglio che non si scarica o non ha l'ora lascia l'Evento com'era.
Future<List<DocumentoGrezzo>> arricchisciOra(
  List<DocumentoGrezzo> documenti, {
  required ConfigDettaglio cfg,
  required Future<Map<String, DateTime>> Function(List<String> chiavi) noti,
  required Future<String> Function(String url) scarica,
  int? giro,
  DedupService dedup = const DedupService(),
  void Function(String)? log,
}) async {
  String chiave(DocumentoGrezzo d) => dedup.chiaveDedup(d.titolo, d.data!);
  final senzaOra = documenti
      .where((d) => d.data != null && _senzaOra(d.data!) && d.url.isNotEmpty)
      .toList();
  if (senzaOra.isEmpty) return documenti;

  final inDb = await noti(senzaOra.map(chiave).toSet().toList());

  final nuovaData = <DocumentoGrezzo, DateTime>{};
  final nuovi = <DocumentoGrezzo>[];
  final daRiprovare = <DocumentoGrezzo>[];
  for (final d in senzaOra) {
    final db = inDb[chiave(d)];
    if (db == null) {
      nuovi.add(d);
    } else if (!_senzaOra(db) && _stessoGiorno(db, d.data!)) {
      nuovaData[d] = db;
    } else {
      daRiprovare.add(d);
    }
  }
  nuovi.sort((a, b) => a.data!.compareTo(b.data!));
  daRiprovare.sort((a, b) => chiave(a).compareTo(chiave(b)));
  if (daRiprovare.isNotEmpty) {
    final da = ((giro ?? DateTime.now().toUtc().hour) * cfg.max) %
        daRiprovare.length;
    daRiprovare.setAll(0, [
      ...daRiprovare.sublist(da),
      ...daRiprovare.sublist(0, da),
    ]);
  }
  final candidati = [...nuovi, ...daRiprovare];

  var aperti = 0, trovati = 0;
  for (final d in candidati.take(cfg.max)) {
    aperti++;
    try {
      final ora = oraDalDettaglio(await scarica(d.url), cfg);
      if (ora != null && _stessoGiorno(ora, d.data!)) {
        nuovaData[d] = ora;
        trovati++;
      }
    } catch (e) {
      log?.call('  (dettaglio non letto: ${d.url} — $e)');
    }
  }
  log?.call(
    '  ora dal dettaglio: ${nuovaData.length - trovati} già in DB, '
    '$trovati trovate su $aperti pagine aperte, '
    '${candidati.length - aperti} rimandate al prossimo giro',
  );

  return [
    for (final d in documenti)
      if (nuovaData[d] case final data?)
        DocumentoGrezzo(
          titolo: d.titolo,
          url: d.url,
          testo: d.testo,
          immagine: d.immagine,
          data: data,
          luogo: d.luogo,
        )
      else
        d,
  ];
}
