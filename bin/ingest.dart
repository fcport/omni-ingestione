// Runner dell'ingestione Omni: legge una Fonte, normalizza, deduplica e
// consegna le righe all'app attraverso il **ponte** (`lib/ponte.dart`, che è
// anche il posto dove è spiegato perché il ponte esiste).
//
// Uso (dry-run su una fixture, nessuna scrittura):
//   dart run bin/ingest.dart --formato rss --tipo notizia --fonte 1 \
//     --fixture test/fixtures/notizie.rss.xml
//
// Scrittura reale: `--push`, con le variabili d'ambiente
//   SUPABASE_URL   (l'host del progetto, non un segreto)
//   INGEST_TOKEN   (il segreto: autorizza il ponte, e nient'altro)
//
// Canale ISTITUZIONALE (la base di conoscenza che Omni-AI cita al cittadino):
// crawl della pagina-indice → segue i link di dettaglio → estrae il full-text →
// upsert in `documento_istituzionale`. Struttura e tabella diverse dai feed,
// quindi percorso separato:
//   dart run bin/ingest.dart --formato html --tipo istituzionale --fonte 8 \
//     --url https://host/indice \
//     --selettori '{"link":"a.atto","titolo":"h1","testo":"article","max":20}' --push
//
// `--base` serve quando i link di dettaglio sono relativi a una cartella diversa
// da quella dell'indice (vedi il Consiglio Grande e Generale in
// `tool/ingest_istituzionale.sh`).
//
// ⚠️ TRANELLO NEI SELETTORI, SU WINDOWS: il carattere `^` **non sopravvive alla
// riga di comando** — `div[id^=article_]` arriva al programma come
// `div[id=article_]`, che non matcha niente, e il crawl ripiega in silenzio sui
// fallback (h1 / paragrafi del body) restituendo il titolo del sito al posto di
// quello del documento. Su Linux (i runner) il `^` passa: si finisce a testare
// in locale una cosa diversa da quella che gira in produzione. Usare `*=` al
// posto di `^=`.

import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:omni_ingestione/documento_grezzo.dart';
import 'package:omni_ingestione/html_extractor.dart';
import 'package:omni_ingestione/normalizzatore.dart';
import 'package:omni_ingestione/parser_data.dart';
import 'package:omni_ingestione/ponte.dart';
import 'package:omni_ingestione/rss_parser.dart';

Future<void> main(List<String> argv) async {
  final args = _Args.parse(argv);

  if (args.tipo == 'istituzionale') {
    await _ingestIstituzionale(args);
    return;
  }

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

/// Crawl istituzionale: pagina-indice → link di dettaglio → full-text.
///
/// Bounded a `selettori.max` voci (atti recenti, niente archivio storico). I
/// selettori vengono dalla `config` della Fonte; il runner è tollerante: salta
/// le voci senza titolo/corpo invece di fallire l'intero job.
///
/// A differenza della versione che stava nel repo privato, questa **lascia
/// sempre una traccia in `ingestione_esito`**. Non è un dettaglio: l'ingestione
/// istituzionale è rimasta rotta dal 13 luglio al 4 agosto 2026 (404 sull'indice
/// del Congresso di Stato) e nessuno se n'è accorto, perché l'unico segnale era
/// un run rosso su GitHub e `documento_istituzionale` vuota non fa rumore.
Future<void> _ingestIstituzionale(_Args args) async {
  final sel = args.selettori;
  if (sel == null) {
    _errore('--tipo istituzionale richiede --selettori <json>', 64);
  }
  final linkSel = sel['link'] as String?;
  if (linkSel == null) _errore('selettori.link mancante', 64);

  final String indiceHtml;
  try {
    indiceHtml = await _leggiSorgente(args);
  } catch (e) {
    await _registraEsito(args, esito: 'errore', errore: '$e');
    _errore('$e', 1);
  }

  final base = Uri.tryParse(args.base ?? args.url ?? '');
  final indice = html.parse(indiceHtml);

  // Link di dettaglio unici, nell'ordine di pagina, cappati a `max`.
  final max = (sel['max'] as num?)?.toInt() ?? 20;
  final visti = <String>{};
  final urls = <String>[];
  for (final a in indice.querySelectorAll(linkSel)) {
    final href = a.attributes['href']?.trim();
    if (href == null || href.isEmpty) continue;
    final assoluto = _assoluto(href, base);
    if (assoluto == null || !visti.add(assoluto)) continue;
    urls.add(assoluto);
    if (urls.length >= max) break;
  }

  final righe = <Map<String, dynamic>>[];
  for (final url in urls) {
    try {
      final pagina = html.parse(await _fetchUrl(url));
      final titolo =
          _testoDi(pagina.documentElement, sel['titolo'] as String?) ??
          _testoDi(pagina.documentElement, 'h1') ??
          _testoDi(pagina.documentElement, 'title');
      final contenuto = _corpo(pagina, sel['testo'] as String?);
      if (titolo == null || contenuto == null || contenuto.length < 40) {
        stderr.writeln('  (salto: titolo/corpo non estratto) $url');
        continue;
      }
      final dataTesto = _testoDi(pagina.documentElement, sel['data'] as String?);
      final data = dataTesto == null ? null : parseData(dataTesto);
      righe.add({
        'fonte_id': args.fonte,
        'titolo': titolo,
        'url': url,
        'tipo_atto': sel['tipo_atto'] as String?,
        'data': data?.toUtc().toIso8601String(),
        // Cap di sicurezza: lo snippet a query time lo fa ts_headline.
        'contenuto': contenuto.length > 8000
            ? contenuto.substring(0, 8000)
            : contenuto,
        'dedup_key': url,
      });
    } catch (e) {
      stderr.writeln('  (errore su $url: $e)');
    }
  }

  if (!args.push) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(righe));
    stderr.writeln(
      '[dry-run] ${righe.length} documenti da ${urls.length} link '
      '(nessuna scrittura).',
    );
    return;
  }

  // Zero righe da un indice che ha risposto 200 è un guasto silenzioso: la
  // pagina esiste ma i selettori non pescano più niente. Va nel registro come
  // errore, non come giro riuscito con zero risultati.
  if (righe.isEmpty) {
    await _registraEsito(
      args,
      esito: 'errore',
      documenti: urls.length,
      righe: 0,
      errore: urls.isEmpty
          ? 'nessun link di dettaglio: selettore "$linkSel" non pesca più'
          : 'nessun documento estratto da ${urls.length} link',
    );
    _errore(
      'Nessun documento estratto da ${urls.length} link: '
      'la Fonte ha cambiato struttura?',
      1,
    );
  }

  final Map<String, dynamic> scritto;
  try {
    scritto = await _consegna('documento_istituzionale', righe);
  } catch (e) {
    await _registraEsito(
      args,
      esito: 'errore',
      documenti: urls.length,
      righe: righe.length,
      errore: '$e',
    );
    _errore('$e', 1);
  }

  final nuove = scritto['nuove'] as int?;
  await _registraEsito(
    args,
    esito: 'ok',
    documenti: urls.length,
    righe: righe.length,
    nuove: nuove,
  );
  stderr.writeln(
    'Consegnati ${righe.length} documenti istituzionali '
    '(${nuove ?? '?'} nuovi, da ${urls.length} link).',
  );
}

String? _assoluto(String raw, Uri? base) {
  final u = Uri.tryParse(raw);
  if (u == null) return null;
  if (u.hasScheme) return raw;
  if (base == null) return null;
  return base.resolveUri(u).toString();
}

/// Testo di un elemento individuato da [selettore] (lista CSS ammessa); null se
/// assente o vuoto.
String? _testoDi(Element? radice, String? selettore) {
  if (radice == null || selettore == null) return null;
  final el = radice.querySelector(selettore);
  final t = el?.text.trim();
  return (t == null || t.isEmpty) ? null : _comprimi(t);
}

/// Corpo dell'atto: l'elemento [selettore] se c'è, altrimenti i paragrafi di
/// main/article/body come fallback.
String? _corpo(Document doc, String? selettore) {
  final mirato = _testoDi(doc.documentElement, selettore);
  if (mirato != null && mirato.length >= 40) return mirato;
  final contenitore =
      doc.querySelector('main') ?? doc.querySelector('article') ?? doc.body;
  if (contenitore == null) return null;
  final paragrafi = contenitore
      .querySelectorAll('p')
      .map((p) => p.text.trim())
      .where((t) => t.isNotEmpty);
  final testo = _comprimi(paragrafi.join('\n'));
  return testo.isEmpty ? null : testo;
}

String _comprimi(String s) => s.replaceAll(RegExp(r'[ \t]+'), ' ').trim();

/// L'unico punto in cui questo repo scrive qualcosa. Il ponte risponde con
/// quante righe erano davvero nuove: il numero che dice se fra un giro e l'altro
/// il feed si è rinnovato per intero — cioè se stiamo perdendo notizie.
Future<Map<String, dynamic>> _consegna(
  String tabella,
  List<Map<String, dynamic>> righe,
) async {
  if (righe.isEmpty) return {'scritte': 0, 'nuove': 0};
  final resp = await ponte({
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
    await ponte({
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
    if (tipo != 'notizia' && tipo != 'evento' && tipo != 'istituzionale') {
      _errore('--tipo deve essere notizia|evento|istituzionale', 64);
    }
    // Il canale istituzionale crawla una pagina-indice: da un RSS non ci sono
    // link di dettaglio da seguire, e il flag passerebbe silenziosamente per poi
    // non estrarre nulla.
    if (tipo == 'istituzionale' && formato != 'html') {
      _errore('--tipo istituzionale richiede --formato html', 64);
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
