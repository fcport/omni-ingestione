/// Documento grezzo estratto da una Fonte (RSS o HTML), prima della
/// normalizzazione. È l'input puro della pipeline di ingestione (seam #2):
/// nessuna dipendenza da Flutter o dalla rete, così è testabile su fixture.
///
/// [data] è `null` quando la Fonte non espone una data: la regola di scarto
/// degli Eventi senza data (PRD US-24) vive nel [Normalizzatore], non qui.
class DocumentoGrezzo {
  const DocumentoGrezzo({
    required this.titolo,
    required this.url,
    this.testo,
    this.immagine,
    this.data,
    this.luogo,
  });

  final String titolo;
  final String url;

  /// Corpo grezzo della Fonte. Non viene mai pubblicato integralmente:
  /// il [Normalizzatore] ne ricava solo un estratto (copyright, PRD US-17).
  final String? testo;
  final String? immagine;
  final DateTime? data;
  final String? luogo;
}
