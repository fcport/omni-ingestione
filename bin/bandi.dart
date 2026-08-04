// Runner dei bandi pubblici di reclutamento (gov.sm).
//
// Legge la pagina "Concorsi pubblici e selezioni" del portale della PA
// sammarinese e ne estrae i bandi con i rispettivi allegati PDF. La logica di
// parsing sta in `lib/bandi_parser.dart` (pura, testata su fixture): questo file
// fa solo I/O, come `bin/ingest.dart`.
//
// Uso:
//   dart run bin/bandi.dart                      # ultimi 10 dal sito, tabella
//   dart run bin/bandi.dart --limit 25 --json    # JSON su stdout
//   dart run bin/bandi.dart --fixture test/fixtures/bandi.html
//
// Scrittura reale (è ciò che fa il cron notturno):
//   dart run bin/bandi.dart --limit 30 --push
// con SUPABASE_URL e INGEST_TOKEN nell'ambiente. I bandi entrano SEMPRE in
// revisione: il cron riempie la coda, non pubblica. Se gov.sm cambia
// impaginazione il parser degrada in silenzio, e la revisione umana è l'unico
// punto in cui ce ne accorgiamo prima del cittadino.
//
// I PDF NON vengono scaricati: si emettono i link al server della Fonte. È la
// scelta a rischio legale minimo (nessuna ridistribuzione di atti della PA) ed
// è anche il requisito Play Store: le informazioni istituzionali devono
// mostrare la fonte e portare all'originale.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:omni_ingestione/bandi_parser.dart';
import 'package:omni_ingestione/bando_grezzo.dart';
import 'package:omni_ingestione/ponte.dart';

const _urlDefault =
    'https://www.gov.sm/pub2/GovSM/Bandi-Pubblici-di-Reclutamento/'
    'Concorsi-pubblici-e-selezioni.html';

/// Pseudo-fonte del registro: i bandi non hanno una riga in `fonte` (gov.sm è
/// cablata qui, non configurabile a DB), ma la traccia in `ingestione_esito`
/// serve lo stesso — è l'unico posto da cui si vede che il giro è passato.
const _tipoRegistro = 'bando';

Future<void> main(List<String> argv) async {
  final args = _Args.parse(argv);

  final String grezzo;
  try {
    grezzo = args.fixture != null
        ? File(args.fixture!).readAsStringSync()
        : await _fetchUrl(args.url);
  } catch (e) {
    await _registra(args, esito: 'errore', errore: '$e');
    stderr.writeln('Errore: $e');
    exit(1);
  }

  final bandi = const BandiParser().estrai(
    grezzo,
    baseUrl: args.url,
    limit: args.limit,
  );

  if (bandi.isEmpty) {
    const messaggio =
        'Nessun bando estratto: la Fonte ha cambiato struttura o non risponde';
    await _registra(args, esito: 'errore', documenti: 0, errore: messaggio);
    stderr.writeln(
      'Nessun bando estratto. Se la Fonte ha cambiato struttura, '
      'aggiornare BandiParser e la fixture test/fixtures/bandi.html.',
    );
    exit(1);
  }

  if (args.push) {
    final ({int importati, int aggiornati}) esito;
    try {
      esito = await _push(bandi);
    } catch (e) {
      await _registra(
        args,
        esito: 'errore',
        documenti: bandi.length,
        errore: '$e',
      );
      stderr.writeln('Errore: $e');
      exit(1);
    }
    await _registra(
      args,
      esito: 'ok',
      documenti: bandi.length,
      righe: bandi.length,
      nuove: esito.importati,
    );
    stderr.writeln(
      '${esito.importati} nuovi bandi in revisione, '
      '${esito.aggiornati} aggiornati.',
    );
    return;
  }

  if (args.json) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'fonte': args.url,
        'count': bandi.length,
        'items': bandi.map(_toMap).toList(),
      }),
    );
  } else {
    _stampa(bandi);
  }
  stderr.writeln('${bandi.length} bandi da ${args.fixture ?? args.url}');
}

/// Forma attesa da `importa_bandi_cron`. È diversa da [_toMap]: quella è
/// l'output leggibile del `--json`, questa deve combaciare con i nomi delle
/// colonne letti dalla RPC (`url`, non `url_dettaglio`).
Map<String, dynamic> _toRpcMap(BandoGrezzo b) => {
  'titolo': b.titolo,
  'url': b.url,
  'repertorio': b.repertorio,
  'descrizione': b.descrizione,
  'data_emissione': b.dataEmissione?.toIso8601String().substring(0, 10),
  'scadenza_testo': b.scadenza,
  'scadenza_il': b.scadenzaIl?.toIso8601String(),
  // Distingue il dato letto dal campo dedicato da quello dedotto dalla prosa:
  // in revisione i dedotti vanno guardati per primi.
  'scadenza_origine': b.scadenzaIl == null
      ? null
      : (b.scadenza != null ? 'campo' : 'prosa'),
  'scaduto': b.scaduto,
  'allegati': [
    for (final a in b.allegati) {'nome': a.nome, 'url': a.url},
  ],
};

Map<String, dynamic> _toMap(BandoGrezzo b) => {
  'titolo': b.titolo,
  'repertorio': b.repertorio,
  'data_emissione': b.dataEmissione?.toUtc().toIso8601String(),
  'scadenza': b.scadenza,
  'scadenza_il': b.scadenzaIl?.toIso8601String(),
  'scaduto': b.scaduto,
  'descrizione': b.descrizione,
  'url_dettaglio': b.url,
  'allegati': [
    for (final a in b.allegati) {'nome': a.nome, 'url': a.url},
  ],
};

void _stampa(List<BandoGrezzo> bandi) {
  for (final b in bandi) {
    final stato = b.scaduto ? 'SCADUTO' : 'aperto';
    final data = b.dataEmissione == null
        ? '?'
        : '${b.dataEmissione!.day.toString().padLeft(2, '0')}/'
              '${b.dataEmissione!.month.toString().padLeft(2, '0')}/'
              '${b.dataEmissione!.year}';
    stdout.writeln('• ${b.titolo}');
    stdout.writeln('  $data · ${b.repertorio ?? 'senza repertorio'} · $stato');
    if (b.scadenza != null) stdout.writeln('  scadenza: ${b.scadenza}');
    for (final a in b.allegati) {
      stdout.writeln('  PDF ${a.nome}');
      stdout.writeln('      ${a.url}');
    }
    stdout.writeln('');
  }
}

/// Consegna i bandi al ponte, azione `bandi` → RPC `importa_bandi_cron`, che li
/// mette in coda di revisione.
///
/// È una RPC diversa da quella dell'admin: `importa_bandi` è gated da
/// `is_admin()`, che legge l'email dal JWT, e un job non ce l'ha. Lì il gate è
/// la GRANT — quella funzione è eseguibile solo dal service_role, che sta dentro
/// il ponte e non qui — invece di allentare il controllo su quella dell'admin.
Future<({int importati, int aggiornati})> _push(List<BandoGrezzo> bandi) async {
  final resp = await ponte({
    'azione': 'bandi',
    'bandi': [for (final b in bandi) _toRpcMap(b)],
  });
  if (resp == null) {
    stderr.writeln('Errore: mancano SUPABASE_URL / INGEST_TOKEN');
    exit(78);
  }
  if (resp.statusCode >= 300) {
    throw StateError('Import fallito (${resp.statusCode}): ${resp.body}');
  }
  final riga = jsonDecode(resp.body) as Map<String, dynamic>;
  return (
    importati: (riga['importati'] as num?)?.toInt() ?? 0,
    aggiornati: (riga['aggiornati'] as num?)?.toInt() ?? 0,
  );
}

/// La traccia del giro, come per il feed. **Non fallisce mai il job**: se la
/// diagnostica non si scrive, l'import ha comunque fatto il suo lavoro.
Future<void> _registra(
  _Args args, {
  required String esito,
  int? documenti,
  int? righe,
  int? nuove,
  String? errore,
}) async {
  if (!args.push) return; // dry-run: non si sporca il registro
  try {
    await ponte({
      'azione': 'esito',
      'fonte_id': null, // gov.sm non ha una riga in `fonte`
      'tipo': _tipoRegistro,
      'esito': esito,
      'documenti': documenti,
      'n_righe': righe,
      'nuove': nuove,
      'errore': errore?.split('\n').first,
    });
  } catch (_) {
    // Il registro è diagnostica, non produzione.
  }
}

/// GET con header da browser: gov.sm risponde 403 allo User-Agent di default
/// di Dart. Stessa ragione e stessi header di `bin/ingest.dart`.
Future<String> _fetchUrl(String url) async {
  final resp = await http.get(
    Uri.parse(url),
    headers: const {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0 Safari/537.36',
      'Accept': 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8',
    },
  );
  if (resp.statusCode >= 300) {
    throw StateError('Fetch fallito (${resp.statusCode}) da $url');
  }
  return resp.body;
}

class _Args {
  _Args({
    required this.url,
    required this.limit,
    this.fixture,
    this.json = false,
    this.push = false,
  });

  final String url;
  final int limit;
  final String? fixture;
  final bool json;
  final bool push;

  static _Args parse(List<String> argv) {
    final m = <String, String>{};
    var json = false;
    var push = false;
    for (var i = 0; i < argv.length; i++) {
      final a = argv[i];
      if (a == '--json') {
        json = true;
      } else if (a == '--push') {
        push = true;
      } else if (a.startsWith('--') && i + 1 < argv.length) {
        m[a.substring(2)] = argv[++i];
      }
    }
    return _Args(
      url: m['url'] ?? _urlDefault,
      limit: int.tryParse(m['limit'] ?? '') ?? 10,
      fixture: m['fixture'],
      json: json,
      push: push,
    );
  }
}
