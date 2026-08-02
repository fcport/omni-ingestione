import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'documento_grezzo.dart';
import 'parser_data.dart';

/// Selettori CSS per estrarre i documenti da una pagina HTML. Vengono dalla
/// colonna `config` (jsonb) della Fonte, così aggiungere una Fonte di scraping
/// non richiede codice nuovo.
class SelettoriHtml {
  const SelettoriHtml({
    required this.item,
    required this.titolo,
    this.link,
    this.data,
    this.luogo,
    this.immagine,
    this.testo,
  });

  /// Selettore di ogni scheda/card (es. `article.evento`).
  final String item;
  final String titolo;
  final String? link; // <a href>
  final String? data;
  final String? luogo;
  final String? immagine; // <img src>
  final String? testo;

  factory SelettoriHtml.fromMap(Map<String, dynamic> m) => SelettoriHtml(
    item: m['item'] as String,
    titolo: m['titolo'] as String,
    link: m['link'] as String?,
    data: m['data'] as String?,
    luogo: m['luogo'] as String?,
    immagine: m['immagine'] as String?,
    testo: m['testo'] as String?,
  );
}

/// Estrae [DocumentoGrezzo] da una pagina HTML applicando i [SelettoriHtml].
/// Puro: riceve la stringa HTML, niente rete. Privilegiare sempre RSS dove c'è.
class HtmlExtractor {
  const HtmlExtractor();

  /// [baseUrl] (opzionale) è l'URL della pagina sorgente: serve a risolvere i
  /// link e le immagini **relativi** (es. `/eventi/x` → `https://host/eventi/x`)
  /// in URL assoluti, altrimenti l'app non potrebbe aprirli. Gli URL già
  /// assoluti restano invariati.
  List<DocumentoGrezzo> estrai(
    String htmlGrezzo,
    SelettoriHtml sel, {
    String? baseUrl,
  }) {
    final doc = html.parse(htmlGrezzo);
    final base = baseUrl == null ? null : Uri.tryParse(baseUrl);
    final out = <DocumentoGrezzo>[];
    for (final nodo in doc.querySelectorAll(sel.item)) {
      final titolo = _campo(nodo, sel.titolo);
      if (titolo == null) continue;
      out.add(
        DocumentoGrezzo(
          titolo: titolo,
          url: _assoluto(_url(nodo, sel.link, 'href'), base) ?? '',
          testo: _campo(nodo, sel.testo),
          immagine: _assoluto(_url(nodo, sel.immagine, 'src'), base),
          data: parseData(_campo(nodo, sel.data)),
          luogo: _campo(nodo, sel.luogo),
        ),
      );
    }
    return out;
  }

  /// Risolve [raw] contro [base] se è un URL relativo. Senza [base] o se [raw]
  /// è già assoluto/non parsabile, lo restituisce invariato.
  String? _assoluto(String? raw, Uri? base) {
    if (raw == null || base == null) return raw;
    final u = Uri.tryParse(raw);
    if (u == null || u.hasScheme) return raw;
    return base.resolveUri(u).toString();
  }

  /// Legge un campo testuale. Il [selettore] può puntare al **testo** di un
  /// elemento (`.title`) oppure a un suo **attributo** con la sintassi
  /// `selettore@attributo` (es. `a@title`). Con la sola `@attributo` (CSS vuoto)
  /// legge l'attributo dell'item stesso (es. `@data-title`), utile quando il
  /// testo visibile è troncato dalla Fonte ma il titolo pieno è in un attributo.
  String? _campo(Element nodo, String? selettore) {
    if (selettore == null) return null;
    final at = selettore.indexOf('@');
    if (at >= 0) {
      final css = selettore.substring(0, at);
      final attr = selettore.substring(at + 1);
      final el = css.isEmpty ? nodo : nodo.querySelector(css);
      final v = el?.attributes[attr]?.trim();
      return (v == null || v.isEmpty) ? null : v;
    }
    final el = nodo.querySelector(selettore);
    final t = el?.text.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  /// URL da un `href`/`src`, con l'[attributo] di default dell'elemento —
  /// oppure da un attributo esplicito con la sintassi `selettore@attributo`.
  ///
  /// Serve alle Fonti con **lazy loading**: lì `src` è un placeholder grigio
  /// uguale per tutti (`lazy.png`) e l'immagine vera sta in un data-attribute
  /// (`img@data-lazy`). Senza questa via d'uscita ogni scheda arriverebbe col
  /// segnaposto al posto della foto, che è peggio di nessuna immagine.
  String? _url(Element nodo, String? selettore, String attributo) {
    if (selettore == null) return null;
    if (selettore.contains('@')) return _campo(nodo, selettore);
    final el = nodo.querySelector(selettore);
    final v = el?.attributes[attributo]?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }
}
