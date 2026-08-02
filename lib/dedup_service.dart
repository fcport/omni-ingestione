/// Deduplica PURA di Notizie/Eventi per la pipeline di ingestione (seam #2 del
/// PRD): "stessa data + titolo molto simile ⇒ un solo record".
///
/// Funzione pura, niente rete: testabile con fixture. Espone sia la generazione
/// di una `dedup_key` normalizzata (backstop sul vincolo unique a DB) sia la
/// deduplica fuzzy di un batch in memoria.
class DedupService {
  const DedupService({this.soglia = 0.82});

  /// Soglia di similarità (0..1) oltre la quale due titoli, a parità di giorno,
  /// sono considerati lo stesso contenuto.
  final double soglia;

  /// Chiave di deduplica deterministica: titolo normalizzato + giorno (data).
  /// Stessa chiave ⇒ stesso record (usata anche dal vincolo unique a DB).
  String chiaveDedup(String titolo, DateTime data) {
    final g =
        '${data.year.toString().padLeft(4, '0')}-${data.month.toString().padLeft(2, '0')}-${data.day.toString().padLeft(2, '0')}';
    return '${normalizzaTitolo(titolo)}|$g';
  }

  /// Normalizza un titolo: minuscolo, accenti rimossi, punteggiatura via,
  /// spazi compattati. Base sia per la chiave sia per la similarità.
  String normalizzaTitolo(String titolo) {
    final senzaAccenti = _rimuoviAccenti(titolo.toLowerCase());
    final soloAlfaNum = senzaAccenti.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
    return soloAlfaNum.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Set<String> _parole(String titolo) =>
      normalizzaTitolo(titolo).split(' ').where((t) => t.isNotEmpty).toSet();

  /// Similarità di Jaccard sui token (parole) dei titoli normalizzati: 0..1.
  double similarita(String titoloA, String titoloB) {
    final a = _parole(titoloA);
    final b = _parole(titoloB);
    if (a.isEmpty && b.isEmpty) return 1;
    if (a.isEmpty || b.isEmpty) return 0;
    return a.intersection(b).length / a.union(b).length;
  }

  /// Quanta parte del titolo **più corto** compare anche nell'altro: 0..1.
  /// A 1 uno dei due è l'altro *più qualcosa*.
  double contenimento(String titoloA, String titoloB) {
    final a = _parole(titoloA);
    final b = _parole(titoloB);
    if (a.isEmpty || b.isEmpty) return 0;
    final corto = a.length <= b.length ? a : b;
    return a.intersection(b).length / corto.length;
  }

  /// Quante parole deve avere il titolo più corto perché il **contenimento**
  /// valga come prova.
  ///
  /// Sotto le tre parole non prova niente: «Concerto» è contenuto in «Concerto
  /// di Natale» senza essere lo stesso evento. A tre o più, che un titolo sia
  /// interamente dentro l'altro **e nello stesso giorno** è un caso che si
  /// spiega quasi solo con la stessa cosa raccontata due volte.
  static const paroleMinimePerContenimento = 3;

  /// True se i due elementi sono duplicati: stesso giorno e titoli simili.
  ///
  /// Tre prove, in ordine di forza: titolo normalizzato identico, contenimento
  /// pieno, Jaccard ≥ [soglia].
  ///
  /// **Il contenimento è nato da un caso vero.** «Cena al Tramonto Corianino
  /// 2026» (San Marino RTV) e «CENA AL TRAMONTO CORIANINO» (Eventi San Marino)
  /// sono lo stesso evento e Jaccard li dà a **0,800**, appena sotto la soglia
  /// di 0,82: una parola in più su cinque basta a farli passare per due cose
  /// diverse. Abbassare la soglia sarebbe stato il rimedio sbagliato — porta
  /// dentro i falsi accoppiamenti *ovunque*, per rimediare a un caso che ha una
  /// forma precisa: **un titolo è l'altro con un pezzo in più** (l'anno,
  /// l'edizione, il nome del locale).
  bool sonoDuplicati(
    String titoloA,
    DateTime dataA,
    String titoloB,
    DateTime dataB,
  ) {
    if (!_stessoGiorno(dataA, dataB)) return false;
    if (normalizzaTitolo(titoloA) == normalizzaTitolo(titoloB)) return true;
    final corto = _parole(titoloA).length <= _parole(titoloB).length
        ? _parole(titoloA)
        : _parole(titoloB);
    if (corto.length >= paroleMinimePerContenimento &&
        contenimento(titoloA, titoloB) == 1) {
      return true;
    }
    return similarita(titoloA, titoloB) >= soglia;
  }

  /// Deduplica un batch mantenendo la prima occorrenza di ogni gruppo di
  /// duplicati. [titolo] e [data] estraggono i campi dall'elemento generico.
  List<T> deduplica<T>(
    List<T> items, {
    required String Function(T) titolo,
    required DateTime Function(T) data,
  }) => deduplicaTenendo(
    items,
    titolo: titolo,
    data: data,
    meglio: (tenuto, _) => tenuto,
  );

  /// Come [deduplica], ma fra due doppioni tiene quello che [meglio] sceglie
  /// invece del primo arrivato.
  ///
  /// Serve quando i doppioni vengono da **fonti diverse**: lì «il primo» è
  /// l'ordine di query, cioè il caso. Fra due racconti dello stesso evento uno
  /// ha la locandina e l'altro no, e tenere quello sbagliato è una perdita
  /// visibile in vetrina.
  ///
  /// L'ordine della lista è preservato: il vincitore prende il posto del primo
  /// del suo gruppo, non va in fondo.
  List<T> deduplicaTenendo<T>(
    List<T> items, {
    required String Function(T) titolo,
    required DateTime Function(T) data,
    required T Function(T tenuto, T candidato) meglio,
  }) {
    final tenuti = <T>[];
    for (final item in items) {
      final i = tenuti.indexWhere(
        (t) => sonoDuplicati(titolo(t), data(t), titolo(item), data(item)),
      );
      if (i < 0) {
        tenuti.add(item);
      } else {
        tenuti[i] = meglio(tenuti[i], item);
      }
    }
    return tenuti;
  }

  bool _stessoGiorno(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _rimuoviAccenti(String s) {
    const mappa = {
      'à': 'a',
      'á': 'a',
      'â': 'a',
      'ä': 'a',
      'ã': 'a',
      'è': 'e',
      'é': 'e',
      'ê': 'e',
      'ë': 'e',
      'ì': 'i',
      'í': 'i',
      'î': 'i',
      'ï': 'i',
      'ò': 'o',
      'ó': 'o',
      'ô': 'o',
      'ö': 'o',
      'õ': 'o',
      'ù': 'u',
      'ú': 'u',
      'û': 'u',
      'ü': 'u',
      'ç': 'c',
      'ñ': 'n',
    };
    final sb = StringBuffer();
    for (final ch in s.split('')) {
      sb.write(mappa[ch] ?? ch);
    }
    return sb.toString();
  }
}
