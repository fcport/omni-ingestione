// Il testo di un atto, spezzato in BRANI: uno per articolo, i lunghi in più
// parti. È l'unità che Omni-AI cerca e cita — «Art. 5» invece di un PDF intero.
//
// Il testo arriva da `pdftotext` (modalità di lettura, non `-layout`): righe
// spezzate dove le spezza la pagina, righe vuote fra i paragrafi quasi sempre,
// MA non negli atti ribattuti degli anni Sessanta, dove ogni articolo è una
// riga sola senza riga vuota prima. Per questo l'inizio di un articolo si
// riconosce dalla RIGA, non dal paragrafo.

/// Un brano: la sua posizione nell'atto, l'etichetta e il testo.
class Brano {
  const Brano(this.ordine, this.etichetta, this.testo);
  final int ordine;
  final String? etichetta;
  final String testo;

  Map<String, dynamic> toJson() =>
      {'ordine': ordine, 'etichetta': etichetta, 'testo': testo};
}

/// Il tetto di un brano. Un articolo più lungo si spezza in parti: un brano
/// enorme annacqua il punteggio full-text (la parola cercata pesa meno in
/// mezzo a cinque pagine) e l'estratto che arriva al modello non è più
/// «l'articolo» ma un pezzo a caso.
const maxCaratteriBrano = 3000;

/// Tetti per atto: la legge di bilancio è fatta di centinaia di pagine di
/// tabelle, che nessuno chiede all'assistente e che riempirebbero il database.
const maxBraniAtto = 400;
const maxCaratteriAtto = 800000;

final _reArticolo = RegExp(
  r'^(?:Art\.|Art\s|ART\.|ART\s|Articolo|ARTICOLO)\s*'
  r'(\d+(?:\s*-?\s*(?:bis|ter|quater|quinquies|sexies|septies|octies|novies|decies))?|unico)\b'
  r'\.?\s*(.*)$',
  caseSensitive: false,
);

/// Le parole che, subito dopo «Articolo 5», dicono che è un RIMANDO a un
/// articolo e non la sua intestazione: «Articolo 5 della Legge…».
final _reRimando = RegExp(
  r'^(della|del|dello|dei|delle|di|comma|commi|lettera|e\s+\d|,)',
  caseSensitive: false,
);

// «ALLEGATO A», «Allegato "A" al Decreto Consiliare 20 maggio 2025 n.73»,
// «Allegato 1 - Tabella dei compensi». Una riga corta: un allegato citato in
// mezzo a un periodo («di cui all'Allegato A, che…») sta in una riga lunga, o
// non ne è l'inizio.
final _reAllegato = RegExp(
  r'''^(?:ALLEGATO|Allegato)\s*["“]?([A-Z0-9]{1,4})?["”]?(?=[\s.,:;)\-–]|$)''',
);

/// Spezza [testo] in brani.
List<Brano> spezza(String testo) {
  final righe = pulisci(testo).split('\n');

  final blocchi = <_Blocco>[_Blocco(null)];
  String? precedente;
  for (var i = 0; i < righe.length; i++) {
    final r = righe[i].trim();
    final testa = _intestazione(r, precedente);
    if (testa != null) {
      var etichetta = testa.etichetta;
      var resto = testa.resto;
      // La rubrica fra parentesi sulla riga dopo («Art. 3» / «(Abrogazioni)»)
      // fa parte dell'etichetta: al reranker dice di cosa parla l'articolo.
      if (resto.isEmpty) {
        final dopo = _prossimaPiena(righe, i + 1);
        if (dopo != null &&
            righe[dopo].trim().startsWith('(') &&
            righe[dopo].trim().length <= 160 &&
            righe[dopo].trim().endsWith(')')) {
          etichetta = '$etichetta ${righe[dopo].trim()}';
          i = dopo;
        }
      }
      blocchi.add(_Blocco(etichetta)..aggiungi(resto));
    } else if (r.length <= 140 && _reAllegato.hasMatch(r)) {
      final sigla = _reAllegato.firstMatch(r)!.group(1);
      blocchi.add(_Blocco(sigla == null ? 'Allegato' : 'Allegato $sigla')..aggiungi(r));
    } else {
      blocchi.last.aggiungi(r);
    }
    precedente = r;
  }

  // Un atto senza nessun articolo (errata corrige, decreti reggenziali sui
  // risultati elettorali, ordinanze) resta un blocco solo, senza etichetta.
  final haArticoli = blocchi.length > 1;
  if (haArticoli && blocchi.first.vuoto) blocchi.removeAt(0);
  if (haArticoli && blocchi.isNotEmpty && blocchi.first.etichetta == null) {
    blocchi.first.etichetta = 'Preambolo';
  }

  final out = <Brano>[];
  var totale = 0;
  for (final b in blocchi) {
    final parti = _parti(b.testo);
    for (var p = 0; p < parti.length; p++) {
      final t = parti[p];
      if (t.isEmpty || _soloNumeri(t)) continue;
      if (out.length >= maxBraniAtto || totale + t.length > maxCaratteriAtto) {
        return out;
      }
      final etichetta = b.etichetta == null
          ? null
          : (p == 0 ? b.etichetta : '${b.etichetta} (segue)');
      out.add(Brano(out.length, etichetta, t));
      totale += t.length;
    }
  }
  return out;
}

/// Pulizia del testo di `pdftotext`: salti pagina, numeri di pagina isolati,
/// spazi multipli, «a capo» di troppo.
String pulisci(String grezzo) {
  return grezzo
      .replaceAll('\r\n', '\n')
      .replaceAll('\f', '\n')
      .replaceAll(' ', ' ')
      .split('\n')
      .map((r) => r.replaceAll(RegExp(r'[ \t]+'), ' ').trimRight())
      // Un numero da solo su una riga è il numero di pagina: nei testi di legge
      // un comma non è mai fatto solo di cifre.
      .where((r) => !RegExp(r'^\s*-?\s*\d{1,4}\s*-?\s*$').hasMatch(r))
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

class _Testa {
  const _Testa(this.etichetta, this.resto);
  final String etichetta;
  final String resto;
}

_Testa? _intestazione(String riga, String? precedente) {
  final m = _reArticolo.firstMatch(riga);
  if (m == null) return null;
  final resto = m.group(2)!.trim();
  if (_reRimando.hasMatch(resto)) return null;
  // Una riga che comincia con «Art. 5» a metà di una frase («…previsto
  // dall'» / «Art. 5 della legge») non è un'intestazione: lo è quando la riga
  // prima chiude un periodo, è vuota o è corta come un titolo.
  final p = precedente?.trim() ?? '';
  // Il titolo dell'atto in maiuscolo («RATIFICA DELLA CONVENZIONE EUROPEA…»)
  // è lungo e non chiude con un punto, ma dopo di lui viene un articolo.
  final maiuscola = p.isNotEmpty && p == p.toUpperCase() && p != p.toLowerCase();
  final chiude = p.isEmpty ||
      RegExp(r'''[.;:!?)"»'’_]$''').hasMatch(p) ||
      p.length < 70 ||
      maiuscola;
  if (!chiude) return null;
  final numero = m.group(1)!.replaceAll(RegExp(r'\s+'), ' ').replaceAll(' -', '-').trim();
  final etichetta = numero.toLowerCase() == 'unico'
      ? 'Articolo Unico'
      : 'Art. ${numero.toLowerCase()}';
  return _Testa(etichetta, resto.replaceFirst(RegExp(r'^[-–.]\s*'), ''));
}

int? _prossimaPiena(List<String> righe, int da) {
  for (var j = da; j < righe.length && j < da + 3; j++) {
    if (righe[j].trim().isNotEmpty) return j;
  }
  return null;
}

class _Blocco {
  _Blocco(this.etichetta);
  String? etichetta;
  final _righe = <String>[];

  void aggiungi(String riga) => _righe.add(riga);

  bool get vuoto => _righe.every((r) => r.trim().isEmpty);

  /// I paragrafi (separati da righe vuote) con le righe interne ricucite.
  String get testo {
    final paragrafi = <String>[];
    final corrente = <String>[];
    void chiudi() {
      if (corrente.isNotEmpty) paragrafi.add(corrente.join(' '));
      corrente.clear();
    }

    for (final r in _righe) {
      if (r.trim().isEmpty) {
        chiudi();
      } else {
        corrente.add(r.trim());
      }
    }
    chiudi();
    return paragrafi.join('\n\n').trim();
  }
}

/// Il testo di un blocco in parti da al massimo [maxCaratteriBrano]: si taglia
/// fra i paragrafi, e solo se un paragrafo da solo sfora, fra le frasi.
List<String> _parti(String testo) {
  if (testo.length <= maxCaratteriBrano) return [testo];
  final pezzi = <String>[];
  for (final par in testo.split('\n\n')) {
    if (par.length <= maxCaratteriBrano) {
      pezzi.add(par);
    } else {
      pezzi.addAll(_perFrasi(par));
    }
  }
  final out = <String>[];
  final sb = StringBuffer();
  for (final p in pezzi) {
    if (sb.isNotEmpty && sb.length + p.length + 2 > maxCaratteriBrano) {
      out.add(sb.toString());
      sb.clear();
    }
    if (sb.isNotEmpty) sb.write('\n\n');
    sb.write(p);
  }
  if (sb.isNotEmpty) out.add(sb.toString());
  return out;
}

List<String> _perFrasi(String par) {
  final out = <String>[];
  var resto = par;
  while (resto.length > maxCaratteriBrano) {
    var taglio = resto.lastIndexOf('. ', maxCaratteriBrano);
    if (taglio < maxCaratteriBrano ~/ 2) taglio = resto.lastIndexOf(' ', maxCaratteriBrano);
    if (taglio <= 0) taglio = maxCaratteriBrano;
    out.add(resto.substring(0, taglio + 1).trim());
    resto = resto.substring(taglio + 1).trim();
  }
  if (resto.isNotEmpty) out.add(resto);
  return out;
}

/// Le pagine di tabelle (bilanci, allegati contabili): più cifre che parole.
bool _soloNumeri(String t) {
  if (t.length < 400) return false;
  final cifre = RegExp(r'\d').allMatches(t).length;
  final lettere = RegExp(r'\p{L}', unicode: true).allMatches(t).length;
  return cifre > (cifre + lettere) * 0.4;
}
