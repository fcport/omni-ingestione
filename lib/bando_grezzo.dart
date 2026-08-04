/// Bando pubblico di reclutamento estratto da una Fonte istituzionale, prima
/// della normalizzazione. Stesso ruolo di [DocumentoGrezzo] per Notizie/Eventi:
/// input puro della pipeline di ingestione, nessuna dipendenza da Flutter o
/// dalla rete, così è testabile su fixture.
///
/// A differenza di un Evento, un bando porta con sé **una lista di allegati
/// PDF** (il bando vero e proprio più i suoi allegati e le eventuali rettifiche)
/// che restano ospitati sul sito della PA: Omni linka, non ridistribuisce.
class BandoGrezzo {
  const BandoGrezzo({
    required this.titolo,
    required this.url,
    required this.allegati,
    this.repertorio,
    this.dataEmissione,
    this.scadenza,
    this.scadenzaIl,
    this.scaduto = false,
    this.descrizione,
  });

  /// Titolo del bando, ripulito dal suffisso "- SCADUTO -" (che diventa
  /// [scaduto]).
  final String titolo;

  /// Pagina di dettaglio sul sito della Fonte. È anche la `dedup_key`: è
  /// l'unico identificatore stabile, perché il [repertorio] manca su alcuni
  /// bandi (selezioni senza numero di repertorio).
  final String url;

  final List<AllegatoBando> allegati;

  /// Numero di repertorio, es. `4/2026/CP`. Assente su parte dei bandi.
  final String? repertorio;

  final DateTime? dataEmissione;

  /// Scadenza **come la scrive la Fonte**, es. "entro le ore 18:00 di lunedì
  /// 22 giugno 2026". Resta il campo autorevole da mostrare al cittadino:
  /// [scadenzaIl] è un di più, non un sostituto.
  final String? scadenza;

  /// [scadenza] interpretata, in **UTC**, oppure `null` quando l'interpretazione
  /// non è certa. Serve a ordinare i bandi e a dire "scade fra 3 giorni".
  ///
  /// Non usarla per **nascondere** un bando: la Fonte a volte proroga con una
  /// "Rettifica" allegata in PDF senza aggiornare il testo della pagina, quindi
  /// una data passata non prova che il bando sia chiuso. Per quello c'è
  /// [scaduto], che è ciò che la PA dichiara.
  final DateTime? scadenzaIl;

  /// Dichiarato dalla Fonte nel titolo, non calcolato da noi: alcuni bandi
  /// restano marcati aperti oltre la data, altri sono chiusi in anticipo.
  final bool scaduto;

  final String? descrizione;
}

/// Allegato PDF di un bando. [url] è sempre assoluto e punta al server della
/// Fonte.
class AllegatoBando {
  const AllegatoBando({required this.nome, required this.url});

  final String nome;
  final String url;
}
