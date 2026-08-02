/// Parser di date tollerante per la pipeline di ingestione. Le Fonti espongono
/// formati eterogenei: ISO 8601 (Atom), RFC 822 (RSS `pubDate`), o testo
/// italiano negli HTML ("10 luglio 2026", "10/07/2026"). Ritorna `null` se non
/// riesce a interpretare la stringa — segnale che la data è assente.
///
/// Funzione pura: nessuna dipendenza da `intl`/locale, così gira anche fuori
/// da Flutter (runner da riga di comando).
DateTime? parseData(String? grezzo) {
  if (grezzo == null) return null;
  final s = grezzo.trim();
  if (s.isEmpty) return null;

  // 1. ISO 8601 (gestisce anche l'offset). DateTime.parse → UTC quando indicato.
  final iso = DateTime.tryParse(s);
  if (iso != null) return iso;

  // 2. RFC 822 usato da RSS: "Wed, 24 Jun 2026 09:30:00 +0000".
  final rfc = RegExp(
    r'(\d{1,2})\s+([A-Za-z]{3,})\s+(\d{4})(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?',
  ).firstMatch(s);
  if (rfc != null) {
    final mese = _mese(rfc.group(2)!);
    if (mese != null) {
      // UTC: l'offset RFC non viene risolto, ma così il giorno di calendario
      // resta stabile in qualsiasi timezone (le date-only non slittano).
      return DateTime.utc(
        int.parse(rfc.group(3)!),
        mese,
        int.parse(rfc.group(1)!),
        int.tryParse(rfc.group(4) ?? '') ?? 0,
        int.tryParse(rfc.group(5) ?? '') ?? 0,
        int.tryParse(rfc.group(6) ?? '') ?? 0,
      );
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
