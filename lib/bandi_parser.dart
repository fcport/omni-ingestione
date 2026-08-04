import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'bando_grezzo.dart';
import 'parser_data.dart';
import 'parser_scadenza.dart';

/// Estrae i [BandoGrezzo] dalla pagina "Concorsi pubblici e selezioni" del
/// portale della PA sammarinese (gov.sm).
///
/// Puro: riceve la stringa HTML, niente rete — stessa regola di
/// [HtmlExtractor], così i test girano su fixture.
///
/// Perché non basta [HtmlExtractor] con dei selettori da `config`: lì ogni
/// campo è **un** selettore CSS che punta a **un** elemento. Qui i campi sono
/// coppie etichetta/valore in blocchi fratelli (`<p><strong>Repertorio</strong>
/// </p><p>4/2026/CP</p>`) senza classi che li distinguano, e gli allegati sono
/// una lista a cardinalità variabile. Serve una lettura posizionale, non per
/// selettore.
///
/// Nota sull'HTML della Fonte: è malformato (tag `<p>` non bilanciati, es.
/// `<p>\n</p><p><strong>Repertorio</strong></p>`). Non tentare di leggerlo a
/// regex sugli elementi: il parser HTML5 di `package:html` lo normalizza in un
/// albero corretto, ed è su quello che lavoriamo.
class BandiParser {
  const BandiParser();

  /// Etichette riconosciute → campo di destinazione.
  ///
  /// La Fonte non è coerente e le varianti non sono indovinabili: questo elenco
  /// viene dallo spoglio di **tutti** i `<strong>` delle 78 schede pubblicate
  /// (2023→2026). "Scadenza domande" ricorre 50 volte, "Scadenza" 33, le altre
  /// 2 a testa. Aggiungerne una qui è sempre meglio che lasciare che il ripiego
  /// euristico sulla prosa la peschi da solo.
  static const Map<String, String> _etichette = {
    'repertorio': 'repertorio',
    'scadenza': 'scadenza',
    'scadenza domande': 'scadenza',
    'scadenza presentazione domande': 'scadenza',
    'termine presentazione domande': 'scadenza',
    'termine di presentazione delle domande': 'scadenza',
    'termine per la presentazione delle domande': 'scadenza',
    'data emissione bando': 'data_emissione',
  };

  /// [baseUrl] serve a rendere assoluti i link relativi. [limit] cappa il
  /// risultato ai bandi più recenti (la pagina ne espone ~78, in ordine di
  /// pubblicazione decrescente).
  List<BandoGrezzo> estrai(
    String htmlGrezzo, {
    String? baseUrl,
    int limit = 10,
  }) {
    final doc = html.parse(htmlGrezzo);
    final base = baseUrl == null ? null : Uri.tryParse(baseUrl);
    final out = <BandoGrezzo>[];

    for (final nodo in doc.querySelectorAll('.accordion')) {
      final titoloGrezzo =
          _testo(nodo, '.accordion__title') ?? _testo(nodo, '.accordion__subject');
      if (titoloGrezzo == null) continue;

      // La pagina di dettaglio è l'identificatore stabile: senza, il bando non
      // è linkabile e non ha dedup_key. Meglio saltarlo che pubblicarlo monco.
      final dettaglio = _urlDettaglio(nodo, base);
      if (dettaglio == null) continue;

      final campi = _campi(nodo);
      final descrizione = _descrizione(nodo, titoloGrezzo);

      // Su ~1 bando su 3 la Fonte non compila il campo "Scadenza" e il termine
      // resta annegato nella prosa ("...e sino alle ore 14:00 di giovedì 21
      // maggio 2026"), spesso oltre il primo paragrafo: il ripiego guarda tutto
      // il testo del bando, non la sola [descrizione].
      //
      // Il rischio è agganciare una data che scadenza non è (durata del
      // servizio, decorrenza). Lo argina la forma richiesta da
      // parseScadenzaBando: servono **ora e data insieme** ("ore 14:00 di
      // giovedì 21 maggio 2026"), che nella prosa compare solo per i termini di
      // presentazione. "con decorrenza dall'8 giugno 2026 e durata fino al 5
      // settembre 2026" non ha orari e viene ignorata.
      final scadenza = campi['scadenza'];
      final scadenzaIl = parseScadenzaBando(scadenza) ??
          parseScadenzaBando(_comprimi(nodo.text), daProsa: true);

      out.add(
        BandoGrezzo(
          titolo: _senzaScaduto(titoloGrezzo),
          url: dettaglio,
          allegati: _allegati(nodo, base),
          repertorio: campi['repertorio'],
          dataEmissione: parseData(campi['data_emissione']),
          scadenza: scadenza,
          scadenzaIl: scadenzaIl,
          scaduto: _reScaduto.hasMatch(titoloGrezzo),
          descrizione: descrizione,
        ),
      );
      if (out.length >= limit) break;
    }
    return out;
  }

  /// Coppie etichetta/valore lette in ordine di documento. I campi non hanno
  /// classi proprie: l'unico legame fra "Repertorio" e "4/2026/CP" è che sono
  /// blocchi consecutivi. Si guarda quindi solo ai blocchi **foglia** (quelli
  /// che non ne contengono altri), altrimenti un contenitore restituirebbe il
  /// testo di tutti i figli e sfaserebbe l'accoppiamento.
  Map<String, String> _campi(Element nodo) {
    final blocchi = <String>[];
    for (final el in nodo.querySelectorAll('p, div')) {
      if (el.querySelector('p, div') != null) continue;
      final t = _comprimi(el.text);
      if (t.isNotEmpty) blocchi.add(t);
    }

    final campi = <String, String>{};
    for (var i = 0; i < blocchi.length - 1; i++) {
      final campo = _etichette[_chiave(blocchi[i])];
      if (campo == null || campi.containsKey(campo)) continue;
      final valore = blocchi[i + 1];
      // Due etichette di fila = valore mancante, non prenderlo.
      if (_etichette.containsKey(_chiave(valore))) continue;
      // Il link al manuale IOL segue le etichette su quasi ogni bando.
      if (_reManuale.hasMatch(valore)) continue;
      campi[campo] = valore;
    }
    return campi;
  }

  /// Allegati PDF, deduplicati per URL e nell'ordine di pagina. Il manuale IOL
  /// è boilerplate ripetuto su ogni bando, non un allegato del bando.
  List<AllegatoBando> _allegati(Element nodo, Uri? base) {
    final out = <AllegatoBando>[];
    final visti = <String>{};
    for (final a in nodo.querySelectorAll('a')) {
      final href = a.attributes['href']?.trim();
      if (href == null || !href.toLowerCase().contains('.pdf')) continue;
      final nome = _comprimi(a.text);
      if (nome.isEmpty || _reManuale.hasMatch(nome)) continue;
      final url = _assoluto(href, base);
      if (url == null || !visti.add(url)) continue;
      out.add(AllegatoBando(nome: nome, url: url));
    }
    return out;
  }

  String? _urlDettaglio(Element nodo, Uri? base) {
    for (final a in nodo.querySelectorAll('a')) {
      if (_comprimi(a.text).toLowerCase() != 'visualizza') continue;
      final href = a.attributes['href']?.trim();
      if (href == null || href.isEmpty) continue;
      return _assoluto(href, base);
    }
    return null;
  }

  /// Primo blocco di prosa abbastanza lungo da essere una descrizione. Su alcuni
  /// bandi la Fonte non ne mette una e ripete il titolo: in quel caso è `null`,
  /// così la UI non mostra due volte la stessa riga.
  String? _descrizione(Element nodo, String titoloGrezzo) {
    for (final el in nodo.querySelectorAll('p')) {
      if (el.querySelector('p, div') != null) continue;
      final t = _comprimi(el.text);
      if (t.length <= 80) continue;
      if (t == titoloGrezzo || t == _senzaScaduto(titoloGrezzo)) continue;
      if (_etichette.containsKey(_chiave(t))) continue;
      return t;
    }
    return null;
  }

  String? _testo(Element nodo, String selettore) {
    final t = nodo.querySelector(selettore)?.text;
    if (t == null) return null;
    final c = _comprimi(t);
    return c.isEmpty ? null : c;
  }

  String? _assoluto(String raw, Uri? base) {
    final u = Uri.tryParse(raw);
    if (u == null) return null;
    if (u.hasScheme) return raw;
    if (base == null) return null;
    return base.resolveUri(u).toString();
  }

  String _chiave(String s) => s.toLowerCase().replaceAll(':', '').trim();

  String _senzaScaduto(String titolo) =>
      _comprimi(titolo.replaceAll(_reScaduto, ' '));

  String _comprimi(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').trim();

  static final RegExp _reScaduto = RegExp(r'-\s*SCADUT[OA]\s*-', caseSensitive: false);
  static final RegExp _reManuale = RegExp('manuale', caseSensitive: false);
}
