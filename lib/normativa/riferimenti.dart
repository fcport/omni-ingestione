// Le chiavi degli atti normativi sammarinesi e le citazioni nei titoli.
//
// Una CHIAVE è `<famiglia>:<anno>/<numero>`. La famiglia esiste perché la
// numerazione dell'archivio NON è unica:
//   o → leggi ordinarie, decreti delegati, decreti-legge, decreti consiliari e
//       reggenziali: condividono UNA progressione annuale (nel 2025, il 158 è
//       una legge e il 159 un decreto delegato);
//   q → leggi qualificate, numerate per conto loro;
//   c → leggi costituzionali (e di revisione costituzionale);
//   r → regolamenti.
// «Legge Qualificata 3 agosto 2018 n.3» e «Legge 2018 n.3» sono due atti
// diversi: senza famiglia, il grafo delle modifiche li confonderebbe.
//
// La stessa funzione calcola la chiave dell'atto e quella degli atti che il suo
// titolo cita, così le due combaciano per costruzione: è il contratto con
// `cerca_normativa` (colonna `chiave` contro `cita`), che da qui ricava
// «richiamato da» — l'avviso che un testo è stato toccato dopo.

const _mesi = {
  'gennaio': 1,
  'febbraio': 2,
  'marzo': 3,
  'aprile': 4,
  'maggio': 5,
  'giugno': 6,
  'luglio': 7,
  'agosto': 8,
  'settembre': 9,
  'ottobre': 10,
  'novembre': 11,
  'dicembre': 12,
};

/// Il numero di un mese italiano scritto per esteso, o `null`.
int? meseItaliano(String nome) => _mesi[nome.toLowerCase()];

/// La famiglia di numerazione di un tipo d'atto, o `null` se il tipo non ha
/// numerazione (errata corrige, testi coordinati, notifiche…).
String? famiglia(String tipo) {
  final t = tipo.toLowerCase();
  if (t.contains('costituz')) return 'c';
  if (t.contains('qualificat')) return 'q';
  if (t.startsWith('regolamento')) return 'r';
  if (t.startsWith('legge') || t.startsWith('decreto')) return 'o';
  return null;
}

/// La chiave di un atto, o `null` se manca un pezzo.
String? chiave(String tipo, int? anno, int? numero) {
  final f = famiglia(tipo);
  if (f == null || anno == null || numero == null) return null;
  return '$f:$anno/$numero';
}

// Il tipo come compare nei titoli. L'ordine conta: le forme lunghe prima, o
// «Legge Qualificata» verrebbe letta come «Legge».
const _tipo =
    r'(Legge\s+(?:di\s+)?Revisione\s+Costituzionale|Legge\s+Costituzionale|'
    r'Legge\s+Qualificata|Legge|Decreto\s*-?\s*Legge|Decreto\s+Delegato|'
    r'Decreto\s+Consiliare|Decreto\s+Reggenziale|Decreto|Regolamento)';

/// «Legge 25 luglio 2025 n.101», «Decreto Delegato 22 marzo 2011, n. 50».
final _conData = RegExp(
  '$_tipo\\s+(\\d{1,2})[°º]?\\s+([a-zA-Z]+)\\s+(\\d{4})\\s*,?\\s*'
  r'(?:n\.|n°|nr\.?|numero)\s*(\d+)',
  caseSensitive: false,
);

/// «Legge Qualificata n.186/2005», «Decreto Delegato n. 50/2011».
final _conBarra = RegExp(
  '$_tipo\\s+(?:n\\.|n°|nr\\.?|numero)\\s*(\\d+)\\s*/\\s*(\\d{4})',
  caseSensitive: false,
);

/// Un atto nominato in un testo: tipo così come scritto, anno, numero e — se
/// c'era — la data.
class Citazione {
  const Citazione(this.tipo, this.anno, this.numero, [this.data]);
  final String tipo;
  final int anno;
  final int numero;
  final DateTime? data;

  String? get chiaveAtto => chiave(tipo, anno, numero);
}

/// Tutti gli atti nominati in [testo], nell'ordine in cui compaiono.
List<Citazione> citazioni(String testo) {
  final trovate = <(int, Citazione)>[];
  for (final m in _conData.allMatches(testo)) {
    final mese = meseItaliano(m.group(3)!);
    if (mese == null) continue;
    final anno = int.parse(m.group(4)!);
    trovate.add((
      m.start,
      Citazione(
        _spazi(m.group(1)!),
        anno,
        int.parse(m.group(5)!),
        DateTime.utc(anno, mese, int.parse(m.group(2)!)),
      ),
    ));
  }
  for (final m in _conBarra.allMatches(testo)) {
    trovate.add((
      m.start,
      Citazione(
        _spazi(m.group(1)!),
        int.parse(m.group(3)!),
        int.parse(m.group(2)!),
      ),
    ));
  }
  trovate.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final t in trovate) t.$2];
}

/// Le chiavi degli atti che [titolo] cita, senza ripetizioni e SENZA l'atto
/// stesso: il titolo di un atto comincia quasi sempre con la propria
/// designazione («Decreto Delegato 24 dicembre 2025 n.159 - Modifica della
/// Legge…»), e un atto che «richiama» sé stesso direbbe che è stato modificato
/// da sé.
List<String> chiaviCitate(String titolo, {String? propria}) {
  final viste = <String>{};
  for (final c in citazioni(titolo)) {
    final k = c.chiaveAtto;
    if (k != null && k != propria) viste.add(k);
  }
  return viste.toList();
}

final _inTesta = RegExp('^\\s*$_tipo\\b', caseSensitive: false);

/// Il tipo d'atto con cui comincia [titolo], o `null`.
String? tipoInTesta(String titolo) {
  final m = _inTesta.firstMatch(titolo);
  return m == null ? null : _spazi(m.group(1)!);
}

String _spazi(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
