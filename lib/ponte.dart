// L'unico punto da cui questo repo tocca il database di Omni.
//
// Questo repo è pubblico — è il motivo per cui esiste: su repo pubblico le
// GitHub Actions sono illimitate, e a luglio 2026 l'ingestione è rimasta ferma
// undici giorni perché i minuti del piano privato erano esauriti. Un repo
// pubblico però non può custodire la service role key di Supabase, che bypassa
// RLS e apre l'intero database: i dati dei cittadini, i voti della Piazza, le
// chat del Mercatino.
//
// Al suo posto c'è un token che autorizza **cinque azioni nominate e nient'altro**
// (Edge Function `ingestione-ponte`, nel repo privato):
//   fonti    → l'elenco delle Fonti attive
//   righe    → upsert su notizia | evento | documento_istituzionale
//   bandi    → la RPC `importa_bandi_cron`, quella sola
//   esito    → una riga di diagnostica in `ingestione_esito`
//   sorgente → scarica il feed di una Fonte attiva dall'IP di Supabase, quando
//              la testata rifiuta gli IP dei runner (`fonte_id`, non un URL:
//              l'indirizzo lo decide il database)
//
// Se il token trapela il danno è «ci inseriscono contenuti finti»: brutto,
// riparabile, circoscritto. Non è «il database dei cittadini è di chiunque».

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// POST al ponte. Restituisce `null` — e non lancia — quando l'ambiente non è
/// configurato: è la condizione normale di un dry-run in locale, dove il
/// chiamante decide se è un errore o no.
Future<http.Response?> ponte(Map<String, dynamic> corpo) async {
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
