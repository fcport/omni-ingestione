/// Interpreta le scadenze dei bandi pubblici di gov.sm, che la Fonte scrive in
/// un'unica forma discorsiva:
///
///     entro le ore 18:00 di lunedì 22 giugno 2026
///
/// Verificato su tutte le 49 scadenze esposte dalla pagina (2023→2026): il
/// formato non varia, cambiano solo il separatore dell'ora (`14:15` / `14.15`),
/// le maiuscole ("Giovedì 19 Ottobre") e una coda opzionale ("a mezzo del
/// servizio tNotice").
///
/// Funzione pura, nessuna dipendenza da `intl`: gira anche nel runner da riga
/// di comando e in Flutter web.
library;

/// Ora legale in vigore a San Marino per l'istante **locale** [l], secondo la
/// regola UE: dall'ultima domenica di marzo (02:00) all'ultima domenica di
/// ottobre (03:00).
bool _oraLegale(DateTime l) {
  if (l.month < 3 || l.month > 10) return false;
  if (l.month > 3 && l.month < 10) return true;
  final domenica = _ultimaDomenica(l.year, l.month);
  return l.month == 3
      ? (l.day > domenica || (l.day == domenica && l.hour >= 2))
      : (l.day < domenica || (l.day == domenica && l.hour < 3));
}

/// Giorno dell'ultima domenica di [mese] in [anno].
int _ultimaDomenica(int anno, int mese) {
  final ultimo = DateTime.utc(anno, mese + 1, 0).day;
  final giorno = DateTime.utc(anno, mese, ultimo).weekday; // 7 = domenica
  return ultimo - (giorno % 7);
}

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

/// `ore HH:MM <raccordo> D mese YYYY`.
///
/// Il raccordo fra ora e giorno cambia da bando a bando — "di lunedì", "del
/// giorno venerdì", oppure niente — quindi si ammettono fino a 3 parole di
/// riempimento. Il tetto serve: senza, la regex scavalcherebbe mezza frase e
/// aggancerebbe una data che con la scadenza non c'entra.
final _reScadenza = RegExp(
  r"ore\s+(\d{1,2})[:.](\d{2})\s+(?:[a-zàèéìòù'’]+\s+){0,3}(\d{1,2})\s+([a-zàèéìòù]+)\s+(\d{4})",
  caseSensitive: false,
);

/// Interpreta la scadenza [testo] e la restituisce in **UTC**, oppure `null` se
/// non è riconoscibile senza ambiguità.
///
/// L'orario nella Fonte è ora locale sammarinese: viene convertito a UTC
/// applicando l'offset giusto (CET +1 / CEST +2). Salvarlo come se fosse già
/// UTC sposterebbe una scadenza delle 18:00 alle 20:00.
///
/// [daProsa] va acceso quando [testo] è il corpo del bando invece del campo
/// "Scadenza". Cambia il livello di prova richiesto: nel campo dedicato
/// qualunque data **è** la scadenza, nella prosa no — lì una data può essere la
/// decorrenza del servizio, la data di una rettifica o un orario di sportello.
/// Con [daProsa] si accetta solo una data introdotta da un marcatore di termine
/// ultimo ("entro", "non oltre", "sino a") e solo se ne resta **una sola**:
/// meglio nessuna scadenza che una sbagliata, perché una scadenza sbagliata
/// nasconde al cittadino un'opportunità di lavoro ancora aperta.
DateTime? parseScadenzaBando(String? testo, {bool daProsa = false}) {
  if (testo == null) return null;

  var trovate = _reScadenza.allMatches(testo).toList();
  if (trovate.isEmpty) return null;

  if (daProsa) {
    trovate = trovate.where((m) => _introdottaDaTermine(testo, m.start)).toList();
    if (trovate.length != 1) return null;
  }

  // Nel campo dedicato più date significano finestra "dalle… alle…": vince
  // quella preceduta dal marcatore di termine ultimo.
  final match = trovate.length == 1
      ? trovate.first
      : trovate.where((m) => _introdottaDaTermine(testo, m.start)).lastOrNull;
  if (match == null) return null;

  final mese = _mesi[match.group(4)!.toLowerCase()];
  if (mese == null) return null;

  final ora = int.parse(match.group(1)!);
  final minuti = int.parse(match.group(2)!);
  if (ora > 23 || minuti > 59) return null;

  final locale = DateTime(
    int.parse(match.group(5)!),
    mese,
    int.parse(match.group(3)!),
    ora,
    minuti,
  );
  // Giorno inesistente (es. 31 febbraio): DateTime normalizza in silenzio,
  // quindi si controlla che non sia slittato.
  if (locale.month != mese || locale.day != int.parse(match.group(3)!)) {
    return null;
  }

  final offset = _oraLegale(locale) ? 2 : 1;
  return DateTime.utc(
    locale.year,
    locale.month,
    locale.day,
    locale.hour,
    locale.minute,
  ).subtract(Duration(hours: offset));
}

/// Vero se la data che inizia a [inizio] è introdotta da un marcatore di
/// **termine ultimo**, e non di apertura dei termini.
///
/// Si guardano solo i 60 caratteri che la precedono: "entro" a tre righe di
/// distanza non dice nulla su questa data. È la differenza fra "a partire dalle
/// ore 14:00 di giovedì 14 maggio" (apertura, da scartare) e "sino alle ore
/// 14:00 di giovedì 21 maggio" (scadenza).
bool _introdottaDaTermine(String testo, int inizio) {
  final da = inizio - 60 < 0 ? 0 : inizio - 60;
  return _reTermine.hasMatch(testo.substring(da, inizio));
}

final _reTermine = RegExp(
  r'(entro|non\s+oltre|sino\s+a|fino\s+a)',
  caseSensitive: false,
);

extension _UltimoODefault<T> on Iterable<T> {
  T? get lastOrNull => isEmpty ? null : last;
}
