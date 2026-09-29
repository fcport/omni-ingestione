/// Parser di date tollerante per la pipeline di ingestione. Le Fonti espongono
/// formati eterogenei: ISO 8601 (Atom), RFC 822 (RSS `pubDate`), o testo
/// italiano negli HTML ("10 luglio 2026", "10/07/2026"). Ritorna `null` se non
/// riesce a interpretare la stringa — segnale che la data è assente.
///
/// Funzione pura: nessuna dipendenza da `intl`/locale, così gira anche fuori
/// da Flutter (runner da riga di comando).
///
/// Con [rispettaFuso] l'offset di una data RFC 822 («+0200», «GMT», «CEST») si
/// applica e il risultato è l'**istante** vero, in UTC. Serve ai `pubDate` delle
/// Notizie: la card dice «2 ore fa», che è un conto sull'istante. San Marino RTV
/// scrive `+0200` e le altre testate `+0000`, e finché l'offset si buttava le
/// notizie RTV risultavano uscite due ore dopo (in inverno una) — il 2026-09-29
/// 94 su 219 avevano una data nel futuro. Spento (default) resta il
/// comportamento di prima, che gli Eventi vogliono: la loro data è l'orario di
/// parete, e le date-only non devono slittare di giorno.
DateTime? parseData(String? grezzo, {bool rispettaFuso = false}) {
  if (grezzo == null) return null;
  final s = grezzo.trim();
  if (s.isEmpty) return null;

  // 1. ISO 8601 (gestisce anche l'offset). DateTime.parse → UTC quando indicato.
  final iso = DateTime.tryParse(s);
  if (iso != null) return iso;

  // 2. RFC 822 usato da RSS: "Wed, 24 Jun 2026 09:30:00 +0000".
  final rfc = RegExp(
    r'(\d{1,2})\s+([A-Za-z]{3,})\s+(\d{4})(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\s*([+-]\d{2}:?\d{2}|[A-Za-z]{1,4})\b)?)?',
  ).firstMatch(s);
  if (rfc != null) {
    final mese = _mese(rfc.group(2)!);
    if (mese != null) {
      // UTC: senza [rispettaFuso] l'offset RFC non viene risolto, così il
      // giorno di calendario resta stabile in qualsiasi timezone (le date-only
      // non slittano).
      final parete = DateTime.utc(
        int.parse(rfc.group(3)!),
        mese,
        int.parse(rfc.group(1)!),
        int.tryParse(rfc.group(4) ?? '') ?? 0,
        int.tryParse(rfc.group(5) ?? '') ?? 0,
        int.tryParse(rfc.group(6) ?? '') ?? 0,
      );
      final offset = rispettaFuso ? _offset(rfc.group(7)) : null;
      return offset == null ? parete : parete.subtract(offset);
    }
  }

  // 3. Numerico: dd/MM/yyyy o dd-MM-yyyy.
  final num = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$').firstMatch(s);
  if (num != null) {
    return DateTime.utc(
      int.parse(num.group(3)!),
      int.parse(num.group(2)!),
      int.parse(num.group(1)!),
    );
  }

  return null;
}

/// L'offset di un fuso RFC 822: numerico («+0200», «-05:00») o un nome noto.
/// Null se manca o non si riconosce: in quel caso la data resta com'è scritta.
Duration? _offset(String? fuso) {
  if (fuso == null) return null;
  final numerico = RegExp(r'^([+-])(\d{2}):?(\d{2})$').firstMatch(fuso);
  if (numerico != null) {
    final d = Duration(
      hours: int.parse(numerico.group(2)!),
      minutes: int.parse(numerico.group(3)!),
    );
    return numerico.group(1) == '-' ? -d : d;
  }
  return _fusiNoti[fuso.toUpperCase()];
}

const Map<String, Duration> _fusiNoti = {
  'Z': Duration.zero,
  'UT': Duration.zero,
  'UTC': Duration.zero,
  'GMT': Duration.zero,
  'CET': Duration(hours: 1),
  'CEST': Duration(hours: 2),
};

/// Numero del mese da un nome inglese o italiano (anche abbreviato). `null` se
/// non riconosciuto.
int? _mese(String nome) {
  final n = nome.toLowerCase();
  for (final entry in _mesi.entries) {
    if (n.startsWith(entry.key)) return entry.value;
  }
  return null;
}

// Prefissi sufficienti a distinguere ogni mese (gen/feb/mar… e jan/feb/mar…).
const Map<String, int> _mesi = {
  'gen': 1,
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'mag': 5,
  'may': 5,
  'giu': 6,
  'jun': 6,
  'lug': 7,
  'jul': 7,
  'ago': 8,
  'aug': 8,
  'set': 9,
  'sep': 9,
  'ott': 10,
  'oct': 10,
  'nov': 11,
  'dic': 12,
  'dec': 12,
};
