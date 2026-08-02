import 'package:html/parser.dart' show parseFragment;

import 'dedup_service.dart';
import 'documento_grezzo.dart';

/// Cuore della pipeline di ingestione (seam #2): trasforma i [DocumentoGrezzo]
/// in righe pronte per le tabelle `notizia`/`evento`, applicando le regole di
/// dominio. Puro e testabile; riusa [DedupService] (già testato).
///
/// Regole (PRD):
///  - Mai testo integrale: solo titolo/estratto/immagine/link (US-16/17).
///  - Eventi senza data → **scartati** (US-24).
///  - Stessa data + titolo simile → **un solo record** (US-19/23).
class Normalizzatore {
  const Normalizzatore({
    this.dedup = const DedupService(),
    this.lunghezzaEstratto = 280,
    this.mesiMax = 2,
  });

  final DedupService dedup;

  /// Lunghezza massima dell'estratto in caratteri (oltre, si tronca con "…").
  final int lunghezzaEstratto;

  /// Finestra temporale delle Notizie: si scartano quelle più vecchie di
  /// [mesiMax] mesi, così il DB non si riempie di archivio inutile.
  final int mesiMax;

  /// Righe `notizia` pronte all'insert. Le Notizie senza data ereditano
  /// [adesso] (la colonna `data` è NOT NULL); restano deduplicate per giorno.
  /// Le Notizie più vecchie di [mesiMax] mesi vengono **scartate**.
  List<Map<String, dynamic>> notizie(
    List<DocumentoGrezzo> documenti, {
    required int fonteId,
    required DateTime adesso,
  }) {
    final soglia = DateTime(adesso.year, adesso.month - mesiMax, adesso.day);
    final recenti = documenti.where(
      (d) => !(d.data ?? adesso).isBefore(soglia),
    );
    final unici = dedup.deduplica<DocumentoGrezzo>(
      recenti.toList(),
      titolo: (d) => d.titolo,
      data: (d) => d.data ?? adesso,
    );
    return [
      for (final d in unici)
        () {
          final data = d.data ?? adesso;
          return <String, dynamic>{
            'titolo': d.titolo,
            'estratto': _estratto(d.testo),
            'immagine': d.immagine,
            'url': d.url,
            'data': data.toUtc().toIso8601String(),
            'fonte_id': fonteId,
            'dedup_key': dedup.chiaveDedup(d.titolo, data),
          };
        }(),
    ];
  }

  /// Righe `evento` pronte all'insert. **Scarta** i documenti senza data
  /// (US-24) prima di deduplicare.
  List<Map<String, dynamic>> eventi(
    List<DocumentoGrezzo> documenti, {
    required int fonteId,
  }) {
    final conData = documenti.where((d) => d.data != null).toList();
    final unici = dedup.deduplica<DocumentoGrezzo>(
      conData,
      titolo: (d) => d.titolo,
      data: (d) => d.data!,
    );
    return [
      for (final d in unici)
        <String, dynamic>{
          'titolo': d.titolo,
          'data_inizio': d.data!.toUtc().toIso8601String(),
          'luogo': d.luogo,
          'descrizione': _estratto(d.testo),
          'immagine': d.immagine,
          'url': d.url,
          'fonte_id': fonteId,
          'dedup_key': dedup.chiaveDedup(d.titolo, d.data!),
        },
    ];
  }

  /// Ricava un estratto sicuro dal corpo grezzo: rimuove i tag HTML, compatta
  /// gli spazi e tronca. Garantisce che non venga mai pubblicato il testo
  /// integrale.
  String? _estratto(String? testo) {
    if (testo == null) return null;
    // parseFragment rimuove i tag E decodifica le entità HTML (&#8220; → “).
    final senzaTag = parseFragment(testo).text ?? '';
    final pulito = senzaTag.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (pulito.isEmpty) return null;
    if (pulito.length <= lunghezzaEstratto) return pulito;
    return '${pulito.substring(0, lunghezzaEstratto).trimRight()}…';
  }
}
