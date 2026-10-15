// Runner della NORMATIVA: leggi, decreti e regolamenti di San Marino
// dall'Archivio del Consiglio Grande e Generale, più i testi coordinati, nelle
// tabelle `atto_normativo` / `atto_normativo_brano` di Omni — la base che
// Omni-AI cita quando gli si chiede cosa dice una legge.
//
// Uso:
//   dart run bin/normativa.dart                       # dry-run: ultimi 2 anni
//   dart run bin/normativa.dart --dal 1600 --coordinati --push
//   dart run bin/normativa.dart --dal 2025 --al 2025 --max-nuovi 3   # prova
//
// Opzioni:
//   --dal / --al    intervallo di anni dell'archivio (default: l'anno scorso
//                   e quest'anno). Si legge dal più recente al più vecchio,
//                   così un giro interrotto ha comunque preso le novità.
//   --coordinati    anche i testi coordinati (e il ritiro di quelli superati)
//   --max-nuovi N   quanti atti NUOVI scaricare al massimo in questo giro
//   --minuti M      tempo massimo del giro: allo scadere si chiude pulito, e il
//                   giro dopo riparte da dove si era fermato (gli atti già in
//                   tabella si saltano)
//   --pausa MS      attesa fra un download e l'altro (default 1200)
//   --push          scrive davvero, attraverso il ponte (SUPABASE_URL,
//                   INGEST_TOKEN); senza, stampa cosa farebbe
//
// UN ATTO NON SI RI-SCARICA. Un atto pubblicato non cambia (le correzioni sono
// atti a sé, le «errata corrige»): il giro chiede al ponte gli URL che ci sono
// già e scarica solo gli altri. Il primo giro sull'archivio intero (11.165 atti
// al 15 ottobre 2026) è un lavoro di ore; dal secondo in poi sono una
// quarantina di pagine d'elenco e i pochi atti nuovi.
//
// IL RITMO. È il sito di un'istituzione piccola, non una CDN: un download alla
// volta, con una pausa, e un User-Agent che dice chi siamo.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:omni_ingestione/normativa/archivio_parser.dart';
import 'package:omni_ingestione/normativa/brani.dart';
import 'package:omni_ingestione/normativa/testo_pdf.dart';
import 'package:omni_ingestione/ponte.dart';

const _userAgent =
    'OmniIngestione/1.0 (+https://omni.sm; gualandi.g@pm.me) Dart';

/// Quanti anni per richiesta d'elenco. Dagli anni Ottanta gli atti sono ~200
/// l'anno e cinque anni stanno in quattro pagine; prima sono poche decine, e
/// una finestra lunga evita decine di richieste che tornano vuote.
int _anniPerFinestra(int al) => al >= 1980 ? 5 : 40;

Future<void> main(List<String> argv) async {
  final a = _Args.parse(argv);
  final inizio = DateTime.now();
  bool scaduto() =>
      a.minuti != null && DateTime.now().difference(inizio).inMinutes >= a.minuti!;

  final client = http.Client();
  final errori = <String>[];
  var elencati = 0, tentati = 0, scritti = 0, nuovi = 0, senzaTesto = 0;

  // Gli URL già in tabella: si saltano.
  final noti = a.push ? await _noti() : <String>{};
  stdout.writeln('Atti già in tabella: ${noti.length}');

  Future<void> lavora(VoceArchivio v) async {
    tentati++;
    try {
      final byte = await _scarica(client, v.url);
      final testo = await testoDocumento(byte);
      var brani = spezza(testo);
      final caratteri = brani.fold<int>(0, (s, b) => s + b.testo.length);
      if (caratteri < minCaratteriTesto) {
        senzaTesto++;
        // Una scansione o un PDF vuoto: l'atto entra lo stesso, cercabile per
        // titolo, e il cittadino arriva al documento col riferimento.
        brani = [Brano(0, null, v.titolo)];
      }
      if (!a.push) {
        stdout.writeln('  · ${v.titolo.length > 90 ? v.titolo.substring(0, 90) : v.titolo}'
            ' — ${brani.length} brani, $caratteri car., cita ${v.cita}');
        scritti++;
        return;
      }
      final r = await ponte({
        'azione': 'atto',
        'atto': v.toAtto(caratteri: caratteri),
        'brani': [for (final b in brani) b.toJson()],
      });
      if (r == null || r.statusCode != 200) {
        throw HttpException('ponte ${r?.statusCode}: ${r?.body}');
      }
      scritti++;
      if ((jsonDecode(r.body) as Map)['nuovo'] == true) nuovi++;
    } catch (e) {
      errori.add('${v.url}: $e');
      stderr.writeln('  ⚠ ${v.titolo}: $e');
    }
    await Future<void>.delayed(Duration(milliseconds: a.pausa));
  }

  // --- Archivio ---------------------------------------------------------------
  var fermato = false;
  for (var al = a.al; al >= a.dal && !fermato;) {
    final dal = (al - _anniPerFinestra(al) + 1).clamp(a.dal, al);
    final List<VoceArchivio> voci;
    try {
      final (lette, totale) = await _elenco(client, dal, al);
      voci = lette;
      // Il conto non torna: il parser ha perso delle righe o la paginazione è
      // cambiata. Si lavora quello che c'è, ma il giro lo deve dire.
      if (totale != null && lette.length < totale) {
        errori.add('elenco $dal-$al: lette ${lette.length} voci su $totale');
      }
    } catch (e) {
      errori.add('elenco $dal-$al: $e');
      stderr.writeln('⚠ elenco $dal-$al: $e');
      al = dal - 1;
      continue;
    }
    elencati += voci.length;
    final daFare = voci.where((v) => !noti.contains(v.url)).toList();
    stdout.writeln('→ $dal-$al: ${voci.length} atti, ${daFare.length} da scaricare');
    for (final v in daFare) {
      if (tentati >= a.maxNuovi || scaduto()) {
        fermato = true;
        break;
      }
      await lavora(v);
      noti.add(v.url);
    }
    al = dal - 1;
  }

  // --- Testi coordinati -------------------------------------------------------
  if (a.coordinati && !scaduto()) {
    try {
      final vigenti = await _coordinati(client);
      stdout.writeln('→ testi coordinati: ${vigenti.length}');
      for (final v in vigenti.where((v) => !noti.contains(v.url))) {
        if (scaduto()) break;
        await lavora(v);
      }
      // Il ritiro dei superati vuole l'elenco COMPLETO: con un elenco
      // sospettosamente corto (pagina cambiata, parser cieco) non si tocca
      // niente. Il database ha la sua rete (rifiuta di togliere più di metà),
      // questa è la prima.
      if (a.push && vigenti.length >= 20) {
        final r = await ponte({
          'azione': 'coordinati_vigenti',
          'vigenti': [for (final v in vigenti) v.url],
        });
        stdout.writeln('  ritirati i superati: ${r?.body}');
      } else if (vigenti.length < 20) {
        errori.add('testi coordinati: solo ${vigenti.length} in elenco');
      }
    } catch (e) {
      errori.add('testi coordinati: $e');
      stderr.writeln('⚠ testi coordinati: $e');
    }
  }

  client.close();
  final minuti = DateTime.now().difference(inizio).inMinutes;
  stdout.writeln('Fatto in $minuti min: $elencati atti in elenco, $scritti scritti '
      '($nuovi nuovi, $senzaTesto senza testo), ${errori.length} errori.');

  if (a.push) {
    await ponte({
      'azione': 'esito',
      'tipo': 'normativa',
      'esito': errori.isEmpty ? 'ok' : 'errore',
      'documenti': elencati,
      'n_righe': scritti,
      'nuove': nuovi,
      'errore': errori.isEmpty ? null : '${errori.length} errori; il primo: ${errori.first}',
    });
  }

  final summary = Platform.environment['GITHUB_STEP_SUMMARY'];
  if (summary != null) {
    File(summary).writeAsStringSync(
      '### Normativa\n- $elencati atti in elenco, $scritti scritti ($nuovi nuovi, '
      '$senzaTesto senza testo)\n- ${errori.length} errori\n'
      '${errori.take(20).map((e) => '  - $e\n').join()}',
      mode: FileMode.append,
    );
  }

  // Qualche PDF che non si scarica è fisiologico su migliaia; un giro che
  // sbaglia più di uno su venti, o che non riesce a leggere l'elenco, no.
  final troppi = errori.length > 3 && errori.length * 20 > scritti;
  final elencoRotto = errori.any((e) => e.startsWith('elenco') || e.startsWith('testi coordinati'));
  exit(troppi || elencoRotto ? 1 : 0);
}

Future<Set<String>> _noti() async {
  final r = await ponte({'azione': 'atti_noti'});
  if (r == null || r.statusCode != 200) {
    stderr.writeln('Il ponte non ha restituito gli atti noti: ${r?.statusCode} ${r?.body}');
    exit(1);
  }
  return {for (final u in (jsonDecode(r.body) as Map)['url'] as List) u as String};
}

/// Tutte le voci di un intervallo, pagina dopo pagina, finché non tornano
/// quante il server dice di averne.
Future<(List<VoceArchivio>, int?)> _elenco(http.Client c, int dal, int al) async {
  final voci = <VoceArchivio>[];
  final viste = <String>{};
  int? totale;
  for (var pagina = 1; pagina <= 60; pagina++) {
    final byte = await _scarica(c, urlElenco(dal: dal, al: al, pagina: pagina).toString());
    final p = parseElenco(decodificaCp1252(byte));
    totale ??= p.totale;
    var aggiunte = 0;
    for (final v in p.voci) {
      if (viste.add(v.url)) {
        voci.add(v);
        aggiunte++;
      }
    }
    if (aggiunte == 0 || totale == null || voci.length >= totale) break;
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }
  return (voci, totale);
}

Future<List<VoceArchivio>> _coordinati(http.Client c) async {
  final indice = parseIndiceCoordinati(decodificaCp1252(await _scarica(c, paginaCoordinati)));
  final out = <VoceArchivio>[];
  final viste = <String>{};
  for (final cat in indice) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final voci = parseCategoriaCoordinati(decodificaCp1252(await _scarica(c, cat.url)), cat.nome);
    for (final v in voci) {
      if (viste.add(v.url)) out.add(v);
    }
  }
  return out;
}

/// GET con tre tentativi e attese crescenti: un 5xx o un timeout passeggero
/// su migliaia di download capita, e non deve costare l'atto.
Future<List<int>> _scarica(http.Client c, String url) async {
  Object? ultimo;
  for (final attesa in const [0, 3, 10]) {
    if (attesa > 0) await Future<void>.delayed(Duration(seconds: attesa));
    try {
      final r = await c
          .get(Uri.parse(url), headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 60));
      if (r.statusCode == 200) return r.bodyBytes;
      ultimo = 'HTTP ${r.statusCode}';
      if (r.statusCode == 404) break;
    } catch (e) {
      ultimo = e;
    }
  }
  throw HttpException('$ultimo', uri: Uri.parse(url));
}

class _Args {
  _Args({
    required this.dal,
    required this.al,
    required this.coordinati,
    required this.maxNuovi,
    required this.minuti,
    required this.pausa,
    required this.push,
  });

  final int dal;
  final int al;
  final bool coordinati;
  final int maxNuovi;
  final int? minuti;
  final int pausa;
  final bool push;

  static _Args parse(List<String> argv) {
    String? val(String nome) {
      final i = argv.indexOf(nome);
      return i >= 0 && i + 1 < argv.length ? argv[i + 1] : null;
    }

    final anno = DateTime.now().year;
    return _Args(
      dal: int.tryParse(val('--dal') ?? '') ?? anno - 1,
      al: int.tryParse(val('--al') ?? '') ?? anno,
      coordinati: argv.contains('--coordinati'),
      maxNuovi: int.tryParse(val('--max-nuovi') ?? '') ?? 1 << 30,
      minuti: int.tryParse(val('--minuti') ?? ''),
      pausa: int.tryParse(val('--pausa') ?? '') ?? 1200,
      push: argv.contains('--push'),
    );
  }
}
