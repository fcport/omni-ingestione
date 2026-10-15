// Le pagine dell'Archivio Leggi, Decreti e Regolamenti del Consiglio Grande e
// Generale (consigliograndeegenerale.sm), lette senza browser.
//
// DUE COSE DA SAPERE PRIMA DI TOCCARE QUESTO FILE.
//
// 1. 🪤 IL SITO MENTE SULLA CODIFICA. L'header dice `charset=UTF-8`, i byte sono
//    Windows-1252: «modalità» arriva come `modalit\xE0`. Decodificata come
//    UTF-8, ogni lettera accentata diventa «�» — e un titolo con «�» non lo
//    trova più nessuna ricerca full-text. Si decodifica a mano ([decodificaCp1252]),
//    ignorando l'header.
//
// 2. L'ELENCO SI CHIEDE PER INTERVALLO DI DATE. Il modulo della pagina ha i
//    campi «anno iniziale / finale», ma il server non li legge: è il JavaScript
//    della pagina (`controlla()`) a tradurli in `P0_data_ordered=[aaaammgg TO
//    aaaammgg]` e a mettere `indicericerca=-1`. Senza quei due parametri la
//    ricerca senza anno risponde ZERO risultati, con un 200. Le pagine arrivano
//    fino a 300 voci (`P0_paginazione`).

import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'riferimenti.dart';

const origineArchivio = 'https://www.consigliograndeegenerale.sm';
const paginaArchivio =
    '$origineArchivio/on-line/home/archivio-leggi-decreti-e-regolamenti.html';
const paginaCoordinati = '$origineArchivio/on-line/home/testi-coordinati.html';

/// Le voci per pagina: il massimo che il server accetta senza fare storie.
const vociPerPagina = 300;

// I caratteri 0x80-0x9F di Windows-1252, che Latin-1 lascerebbe come controlli
// invisibili: virgolette curve, trattini, l'apostrofo tipografico di
// «all’esportazione».
const _cp1252 = {
  0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026,
  0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160,
  0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019,
  0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
  0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153,
  0x9E: 0x017E, 0x9F: 0x0178,
};

/// Decodifica byte Windows-1252 — con dentro, a tratti, UTF-8 vero.
///
/// 🪤 Il sito è Windows-1252, ma alcuni titoli sono stati salvati nel CMS come
/// UTF-8: «40° anniversario» arriva come `34 30 C2 B0`, che letto in
/// Windows-1252 diventa «40Â° anniversario», e «all’esportazione» diventa
/// «allâ€™esportazione». Al primo giro erano 214 titoli su 6.600. Qui una
/// sequenza UTF-8 VALIDA (primo byte C2-F4 seguito dal numero giusto di byte
/// 80-BF) si legge come UTF-8, tutto il resto come Windows-1252. Nell'italiano
/// scritto in Windows-1252 una lettera accentata («è», E8) non è mai seguita da
/// byte di continuazione, quindi non ci sono falsi positivi.
String decodificaCp1252(List<int> byte) {
  final sb = StringBuffer();
  var i = 0;
  while (i < byte.length) {
    final n = _lunghezzaUtf8(byte, i);
    if (n > 1) {
      sb.write(utf8.decode(byte.sublist(i, i + n)));
      i += n;
      continue;
    }
    sb.writeCharCode(_cp1252[byte[i]] ?? byte[i]);
    i++;
  }
  return sb.toString();
}

/// La lunghezza della sequenza UTF-8 multibyte valida che comincia in [i], o 0.
int _lunghezzaUtf8(List<int> b, int i) {
  final c = b[i];
  final int n;
  if (c >= 0xC2 && c <= 0xDF) {
    n = 2;
  } else if (c >= 0xE0 && c <= 0xEF) {
    n = 3;
  } else if (c >= 0xF0 && c <= 0xF4) {
    n = 4;
  } else {
    return 0;
  }
  if (i + n > b.length) return 0;
  for (var k = 1; k < n; k++) {
    if (b[i + k] < 0x80 || b[i + k] > 0xBF) return 0;
  }
  try {
    utf8.decode(b.sublist(i, i + n));
    return n;
  } on FormatException {
    return 0;
  }
}

/// L'URL della pagina [pagina] (da 1) dell'elenco degli atti fra il 1° gennaio
/// di [dal] e il 31 dicembre di [al].
Uri urlElenco({required int dal, required int al, int pagina = 1}) {
  return Uri.parse(paginaArchivio).replace(queryParameters: {
    'P0_path': '/home/tomcat/indicizzazione/indexleggi',
    'P0_paginazione': '$vociPerPagina',
    'P0_pagina': '$pagina',
    'P0_orderBy': 'index_lucene,data_ordered,numero',
    'P0_order': 'asc,desc,desc',
    'P0_operatorMustBe': 'yes',
    'P0_title': '',
    'P0_tipo': '',
    'P0_numero': '',
    'P0_anno': '',
    'P0_data_gg': '',
    'P0_data_mm': '',
    'P0_data_aa': '',
    'P0_document': '',
    'P0_data_ordered': '[${dal}0101 TO ${al}1231]',
    'indicericerca': '-1',
  });
}

/// Un atto come lo elenca l'archivio, prima di scaricarne il testo.
class VoceArchivio {
  const VoceArchivio({
    required this.titolo,
    required this.url,
    required this.tipo,
    this.numero,
    this.data,
    this.coordinato = false,
    this.categoria,
    this.aggiornatoAl,
  });

  final String titolo;
  final String url;
  final String tipo;
  final int? numero;
  final DateTime? data;
  final bool coordinato;
  final String? categoria;
  final DateTime? aggiornatoAl;

  int? get anno => data?.year;

  /// La chiave di numerazione (vedi `riferimenti.dart`). I testi coordinati non
  /// ne hanno una: non sono un atto, sono la lettura aggiornata di uno o più.
  String? get chiaveAtto => coordinato ? null : chiave(tipo, anno, numero);

  /// Gli atti nominati nel titolo, esclusa la voce stessa.
  List<String> get cita => chiaviCitate(titolo, propria: chiaveAtto);

  Map<String, dynamic> toAtto({int? caratteri}) => {
        'dedup_key': url,
        'url': url,
        'tipo': tipo,
        'numero': numero,
        'anno': coordinato ? null : anno,
        'data': _iso(data),
        'titolo': titolo,
        'chiave': chiaveAtto,
        'cita': cita,
        'coordinato': coordinato,
        'categoria': categoria,
        'aggiornato_al': _iso(aggiornatoAl),
        'caratteri': caratteri,
      };
}

String? _iso(DateTime? d) => d == null
    ? null
    : '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';

/// Una pagina dell'elenco: le voci e il totale che il server dichiara — il
/// totale serve a sapere se abbiamo letto tutto, o se il parser ha perso righe
/// per strada.
class PaginaElenco {
  const PaginaElenco(this.voci, this.totale);
  final List<VoceArchivio> voci;
  final int? totale;
}

final _reTotale = RegExp(r'Risultati trovati:\s*(?:<[^>]+>\s*)*(\d+)');
final _reData = RegExp(r'(\d{2})/(\d{2})/(\d{4})');

/// Legge una pagina dell'elenco già decodificata.
PaginaElenco parseElenco(String pagina) {
  final doc = html.parse(pagina);
  final voci = <VoceArchivio>[];
  for (final card in doc.querySelectorAll('div[id^=card_]')) {
    final titolo = _testo(card.querySelector('h3'));
    final link = card.querySelector('a[href*=documento]');
    final href = link?.attributes['href'];
    if (titolo.isEmpty || href == null) continue;

    // «Decreto Delegato numero 160 del 24/12/2025», con degli &nbsp; in mezzo.
    // A volte il tipo manca («numero 12 del…» senza niente davanti): lo dice
    // il titolo, che comincia sempre con la designazione dell'atto.
    // Il `div.fl` NON è dentro la card: è il fratello che la segue
    // (`<div id="card_…">…</div><div class="fl">…`).
    final fl = _fratelloFl(card);
    final riga = _testo(fl);
    final numero = int.tryParse(_testo(fl?.querySelector('a')));
    final m = _reData.firstMatch(riga);
    final data = m == null
        ? null
        : DateTime.utc(
            int.parse(m.group(3)!), int.parse(m.group(2)!), int.parse(m.group(1)!));
    var tipo = riga.split(RegExp(r'\s+(numero|del)\s')).first.trim();
    if (tipo.isEmpty || RegExp(r'^(numero|del)\b').hasMatch(tipo)) {
      tipo = tipoDaTitolo(titolo);
    }

    voci.add(VoceArchivio(
      titolo: titolo,
      url: Uri.parse(origineArchivio).resolve(href).toString(),
      tipo: normalizzaTipo(tipo),
      numero: numero,
      data: data,
    ));
  }
  final t = _reTotale.firstMatch(pagina);
  return PaginaElenco(voci, t == null ? null : int.parse(t.group(1)!));
}

Element? _fratelloFl(Element card) {
  var e = card.nextElementSibling;
  while (e != null && !(e.id).startsWith('card_')) {
    if (e.localName == 'div' && e.classes.contains('fl')) return e;
    e = e.nextElementSibling;
  }
  return null;
}

/// Il tipo dalla designazione in testa al titolo («DECRETO CONSILIARE 22
/// dicembre 2025 n.157 - …» → «Decreto Consiliare»).
String tipoDaTitolo(String titolo) {
  final t = tipoInTesta(titolo);
  if (t != null) return t;
  if (RegExp(r'^errata', caseSensitive: false).hasMatch(titolo)) return 'Errata corrige';
  return 'Atto';
}

/// Una sola grafia per tipo: l'archivio scrive «Decreto - Legge»,
/// «Decreto-Legge», «Legge costituzionale», «DECRETO CONSILIARE».
String normalizzaTipo(String grezzo) {
  final t = grezzo.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
  if (RegExp(r'^decreto\s*-?\s*legge').hasMatch(t)) return 'Decreto-Legge';
  if (t.startsWith('errata')) return 'Errata corrige';
  if (t.contains('revisione') && t.contains('costituz')) {
    return 'Legge di Revisione Costituzionale';
  }
  return t
      .split(' ')
      .where((p) => p.isNotEmpty)
      .map((p) => p[0].toUpperCase() + p.substring(1))
      .join(' ');
}

// ---------------------------------------------------------------------------
// Testi coordinati
// ---------------------------------------------------------------------------

/// Una categoria dell'indice dei testi coordinati («2 - Normativa Fiscale e
/// Tributaria»).
class CategoriaCoordinati {
  const CategoriaCoordinati(this.nome, this.url);
  final String nome;
  final String url;
}

/// L'indice delle categorie.
List<CategoriaCoordinati> parseIndiceCoordinati(String pagina) {
  final doc = html.parse(pagina);
  final viste = <String>{};
  final out = <CategoriaCoordinati>[];
  for (final a in doc.querySelectorAll('a[href*="testi-coordinati/docCat."]')) {
    final href = a.attributes['href']!;
    final url = Uri.parse(origineArchivio).resolve(href).toString();
    if (!viste.add(url)) continue;
    out.add(CategoriaCoordinati(_testo(a), url));
  }
  return out;
}

final _reAggiornato = RegExp(
  r'''aggiorna(?:t[oa]|mento)\w*\s+(?:al\s+|all[’']\s*|a\s+)?(?:(\d{1,2})\s+)?([a-zA-Z]+)\s+(\d{4})''',
  caseSensitive: false,
);

/// La data di aggiornamento dal titolo di un testo coordinato: «(aggiornato al
/// 26 settembre 2025)», «(aggiornamento a maggio 2026)», «(Aggiornato 31
/// ottobre 2022)», «(aggiornato all'11 aprile 2024)». Il solo mese vale il
/// primo del mese.
DateTime? aggiornatoAl(String titolo) {
  final m = _reAggiornato.firstMatch(titolo);
  if (m == null) return null;
  final mese = meseItaliano(m.group(2)!);
  if (mese == null) return null;
  return DateTime.utc(int.parse(m.group(3)!), mese, int.tryParse(m.group(1) ?? '') ?? 1);
}

/// Le righe di una categoria: titolo + link al documento.
List<VoceArchivio> parseCategoriaCoordinati(String pagina, String categoria) {
  final doc = html.parse(pagina);
  final out = <VoceArchivio>[];
  for (final tr in doc.querySelectorAll('tr')) {
    final celle = tr.querySelectorAll('td');
    if (celle.length < 2) continue;
    final titolo = _testo(celle.first);
    final href = celle[1].querySelector('a[href*=documento]')?.attributes['href'];
    if (titolo.isEmpty || href == null) continue;
    out.add(VoceArchivio(
      titolo: titolo,
      url: Uri.parse(origineArchivio).resolve(href).toString(),
      tipo: 'Testo coordinato',
      coordinato: true,
      categoria: categoria,
      aggiornatoAl: aggiornatoAl(titolo),
      data: aggiornatoAl(titolo),
    ));
  }
  return out;
}

String _testo(Element? e) =>
    (e?.text ?? '').replaceAll(' ', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
