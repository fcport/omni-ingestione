// Runner dell'ingestione Omni: legge una Fonte, normalizza, deduplica e
// consegna le righe all'app attraverso il **ponte**.
//
// Uso (dry-run su una fixture, nessuna scrittura):
//   dart run bin/ingest.dart --formato rss --tipo notizia --fonte 1 \
//     --fixture test/fixtures/notizie.rss.xml
//
// Scrittura reale: `--push`, con le variabili d'ambiente
//   SUPABASE_URL   (l'host del progetto, non un segreto)
//   INGEST_TOKEN   (il segreto: autorizza il ponte, e nient'altro)
//
// PERCHÉ IL PONTE E NON IL DATABASE. Questo repo è pubblico — è il motivo per
// cui esiste: su repo pubblico le GitHub Actions sono illimitate, e a luglio
// 2026 l'ingestione è rimasta ferma undici giorni perché i minuti del piano
// privato erano esauriti. Un repo pubblico però non può custodire la service
// role key di Supabase, che bypassa RLS e apre l'intero database. Il token qui
// dentro sa fare tre cose: chiedere le Fonti attive, consegnare righe di
// Notizie/Eventi, scrivere una riga di diagnostica. Nessuna quarta.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:omni_ingestione/documento_grezzo.dart';
import 'package:omni_ingestione/html_extractor.dart';
import 'package:omni_ingestione/normalizzatore.dart';
import 'package:omni_ingestione/rss_parser.dart';

Future<void> main(List<String> argv) async {
  final args = _Args.parse(argv);

  final String grezzo;
  try {
    grezzo = await _leggiSorgente(args);
  } catch (e) {
    await _registraEsito(args, esito: 'errore', errore: '$e');
    _errore('$e', 1);
  }

  final List<DocumentoGrezzo> documenti;
  if (args.formato == 'rss') {
    documenti = const RssParser().parse(grezzo);
  } else {
    final sel = args.selettori;
    if (sel == null) _errore('--formato html richiede --selettori <json>', 64);
    documenti = const HtmlExtractor().estrai(
      grezzo,
      SelettoriHtml.fromMap(sel),
      baseUrl: args.base ?? args.url,
    );
  }

  const normalizzatore = Normalizzatore();
  final tabella = args.tipo == 'notizia' ? 'notizia' : 'evento';
  final righe = args.tipo == 'notizia'
      ? normalizzatore.notizie(
          documenti,
          fonteId: args.fonte,
          adesso: DateTime.now(),
        )
      : normalizzatore.eventi(documenti, fonteId: args.fonte);

  if (!args.push) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(righe));
    stderr.writeln(
      '[dry-run] ${righe.length} righe normalizzate da '
      '${documenti.length} documenti (nessuna scrittura).',
    );
    return;
  }

  final Map<String, dynamic> scritto;
  try {
    scritto = await _consegna(tabella, righe);
  } catch (e) {
    await _registraEsito(args, esito: 'errore', errore: '$e');
    _errore('$e', 1);
  }

  final nuove = scritto['nuove'] as int?;
  await _registraEsito(
    args,
    esito: 'ok',
    documenti: documenti.length,
    righe: righe.length,
    nuove: nuove,
  );
  stderr.writeln(
    'Consegnate ${righe.length} righe su "$tabella" '
    '(${nuove ?? '?'} nuove su ${documenti.length} nel feed).',
  );
}

Future<String> _leggiSorgente(_Args args) async {
  if (args.fixture != null) return File(args.fixture!).readAsStringSync();
  if (args.url != null) return _fetchUrl(args.url!);
  _errore('Serve --fixture <path> oppure --url <feed-url>', 64);
}

/// GET con header da browser: parecchie testate rispondono 403 allo User-Agent
/// di default di Dart.
Future<String> _fetchUrl(String url) async {
  final resp = await http.get(
    Uri.parse(url),
    headers: const {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0 Safari/537.36',
      'Accept':
          'application/rss+xml, application/xml, text/xml, text/html;q=0.9, */*;q=0.8',
    },
  );
  if (resp.statusCode >= 300) {
    throw StateError('Fetch fallito (${resp.statusCode}) da $url');
  }
  return resp.body;
}

/// L'unico punto in cui questo repo scrive qualcosa. Il ponte risponde con
/// quante righe erano davvero nuove: il numero che dice se fra un giro e l'altro
/// il feed si è rinnovato per intero — cioè se stiamo perdendo notizie.
Future<Map<String, dynamic>> _consegna(
  String tabella,
  List<Map<String, dynamic>> righe,
) async {
  if (righe.isEmpty) return {'scritte': 0, 'nuove': 0};
  final resp = await _ponte({
    'azione': 'righe',
    'tabella': tabella,
    'righe': righe,
  });
  if (resp == null) throw StateError('Ponte non configurato');
  if (resp.statusCode >= 300) {
    throw StateError('Consegna fallita (${resp.statusCode}): ${resp.body}');
  }
  return jsonDecode(resp.body) as Map<String, dynamic>;
}

/// La traccia del giro. **Non fallisce mai il job**: se la diagnostica non si
/// scrive, l'ingestione ha comunque fatto il suo lavoro.
Future<void> _registraEsito(
  _Args args, {
  required String esito,
  int? documenti,
  int? righe,
  int? nuove,
  String? errore,
}) async {
  if (!args.push) return; // dry-run: non si sporca il registro
  try {
    await _ponte({
      'azione': 'esito',
      'fonte_id': args.fonte,
      'tipo': args.tipo,
      'esito': esito,
      'documenti': documenti,
      'n_righe': righe,
      'nuove': nuove,
      // Il messaggio per esteso può contenere pezzi di pagina: basta la prima
      // riga, che è quella che dice cos'è successo.
      'errore': errore?.split('\n').first,
    });
  } catch (_) {
    // Il registro è diagnostica, non produzione.
  }
}

Future<http.Response?> _ponte(Map<String, dynamic> corpo) async {
  final url = Platform.environment['SUPABASE_URL'];
  final token = Platform.environment['INGEST_TOKEN'];
  if (url == null || token == null) return null;
  return http.post(
    Uri.parse('$url/functions/v1/ingestione-ponte'),
    headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    },
    body: jsonEncode(corpo),
  );
}

Never _errore(String messaggio, int codice) {
  stderr.writeln('Errore: $messaggio');
  exit(codice);
}

class _Args {
  _Args({
    required this.formato,
    required this.tipo,
    required this.fonte,
    this.fixture,
    this.url,
    this.base,
    this.selettori,
    this.push = false,
  });

  final String formato; // rss | html
  final String tipo; // notizia | evento
  final int fonte;
  final String? fixture;
  final String? url;
  final String? base; // base per risolvere URL relativi (default: url)
  final Map<String, dynamic>? selettori;
  final bool push;

  static _Args parse(List<String> argv) {
    final m = <String, String>{};
    var push = false;
    for (var i = 0; i < argv.length; i++) {
      final a = argv[i];
      if (a == '--push') {
        push = true;
      } else if (a.startsWith('--') && i + 1 < argv.length) {
        m[a.substring(2)] = argv[++i];
      }
    }
    final formato = m['formato'];
    final tipo = m['tipo'];
    if (formato != 'rss' && formato != 'html') {
      _errore('--formato deve essere rss|html', 64);
    }
    // Niente `istituzionale` qui: quel canale scrive su
    // `documento_istituzionale`, che il ponte non ammette, e resta nel repo
    // privato dove ha la service role key.
    if (tipo != 'notizia' && tipo != 'evento') {
      _errore('--tipo deve essere notizia|evento', 64);
    }
    return _Args(
      formato: formato!,
      tipo: tipo!,
      fonte: int.tryParse(m['fonte'] ?? '') ?? 0,
      fixture: m['fixture'],
      url: m['url'],
      base: m['base'],
      selettori: m['selettori'] == null
          ? null
          : jsonDecode(m['selettori']!) as Map<String, dynamic>,
      push: push,
    );
  }
}
