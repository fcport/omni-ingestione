import 'package:html/parser.dart' show parseFragment;

import 'documento_grezzo.dart';

/// Estrae Eventi dall'API REST di WordPress (`/wp-json/wp/v2/<tipo>`) quando le
/// date stanno nei campi **ACF**, non nel post.
///
/// Nasce per Visit Rimini, che pubblica gli eventi come custom post type con
/// una `acf` fatta così:
///
/// ```json
/// { "data_inizio": "20261001", "data_fine": "20261004",
///   "data_ricorrente": [{"data": "20260812"}, {"data": "20260819"}],
///   "event_dove": "Piazza Cavour, Rimini",
///   "event_quando": "dall'1 al 4 ottobre",
///   "event_ingresso": "Libero" }
/// ```
///
/// **Perché non un parser HTML.** Le altre due strade riminesi hanno la data in
/// testo libero — `riminiturismo.it` scrive «Estate 2026» nel campo periodo — e
/// una data che non è una data non può finire in un `timestamptz not null`
/// senza inventarsela. Qui invece il formato è `YYYYMMDD` su tutti e 100 gli
/// eventi campionati il 2026-08-10: è l'unica delle tre fonti che si può
/// ingerire senza indovinare niente.
class WpEventiParser {
  const WpEventiParser({
    this.giorniAvanti = 30,
    this.maxOccorrenze = 4,
    this.immagini = const <int, String>{},
  });

  /// Quanto lontano guardare. Serve contro le ricorrenze lunghe: una mostra
  /// aperta tutti i mercoledì fino a dicembre sono venti righe che oggi non
  /// guarda nessuno, e che spingerebbero fuori dalla lista le serate di domani.
  final int giorniAvanti;

  /// Quante repliche al massimo tenere di uno stesso Evento, anche dentro
  /// l'orizzonte. Con 9 date nello stesso mese — capita, sono le visite guidate
  /// — un Evento solo occuperebbe metà del segmento con lo stesso titolo
  /// ripetuto, e il feed diventerebbe l'agenda di quel museo.
  final int maxOccorrenze;

  /// `featured_media` → URL dell'immagine, risolte a parte con una sola
  /// chiamata a `/wp/v2/media?include=…`. Vuota = Eventi senza locandina.
  final Map<int, String> immagini;

  /// Una riga **per occorrenza**, non per Evento.
  ///
  /// È la differenza fra «Visite guidate al Fellini Museum» che compare una
  /// volta con una data qualsiasi delle nove, e la stessa visita che compare
  /// nel giorno in cui uno può andarci. `dedup_key` è `titolo|giorno`, quindi
  /// le occorrenze non si annullano fra loro: si sommano, come devono.
  List<DocumentoGrezzo> parse(
    List<dynamic> posts, {
    required DateTime adesso,
  }) {
    final oggi = DateTime.utc(adesso.year, adesso.month, adesso.day);
    final limite = oggi.add(Duration(days: giorniAvanti));
    final documenti = <DocumentoGrezzo>[];

    for (final grezzo in posts) {
      if (grezzo is! Map) continue;
      final post = grezzo.cast<String, dynamic>();
      final acf = post['acf'];
      if (acf is! Map) continue;
      final campi = acf.cast<String, dynamic>();

      final titolo = _testo(_dentro(post['title'], 'rendered'));
      final url = (post['link'] as String?)?.trim() ?? '';
      if (titolo.isEmpty || url.isEmpty) continue;

      final date = _date(campi)
          .where((d) => !d.isBefore(oggi) && !d.isAfter(limite))
          .toList()
        ..sort();
      if (date.isEmpty) continue;

      final media = (post['featured_media'] as num?)?.toInt();
      for (final data in date.take(maxOccorrenze)) {
        documenti.add(
          DocumentoGrezzo(
            titolo: titolo,
            url: url,
            data: data,
            luogo: _pulito(campi['event_dove']),
            testo: _descrizione(campi),
            immagine: media == null ? null : immagini[media],
          ),
        );
      }
    }
    return documenti;
  }

  /// Le date di un Evento, da entrambe le forme che ACF usa.
  ///
  /// I due campi si escludono in pratica ma **non** per contratto (71 eventi su
  /// 100 avevano solo `data_inizio`, 29 solo `data_ricorrente`): si leggono
  /// tutti e due e si uniscono, così una Fonte che un giorno li compilasse
  /// entrambi non perde metà del calendario in silenzio.
  ///
  /// Di un intervallo si tiene **solo l'inizio**: `DocumentoGrezzo` non ha una
  /// data di fine e il Normalizzatore non scriverebbe `data_fine` comunque. La
  /// conseguenza, dichiarata: una mostra cominciata la settimana scorsa e
  /// aperta ancora per un mese **non compare**, perché il suo inizio è passato.
  /// Vale già per le Fonti sammarinesi; sistemarlo è un lavoro sul modello, non
  /// su questo parser.
  List<DateTime> _date(Map<String, dynamic> acf) {
    final date = <DateTime>{};

    final inizio = _data(acf['data_inizio']);
    if (inizio != null) date.add(inizio);

    final ricorrenti = acf['data_ricorrente'];
    if (ricorrenti is List) {
      for (final r in ricorrenti) {
        if (r is Map) date.addAll([?_data(r.cast<String, dynamic>()['data'])]);
      }
    }
    return date.toList();
  }

  /// `20260812` → mezzanotte UTC del 12 agosto 2026.
  ///
  /// UTC e non locale, e non è un dettaglio: `DateTime.parse` su una data senza
  /// ora la interpreta nel fuso della macchina, e il `toUtc()` a valle la
  /// sposterebbe **al giorno prima alle 22:00** in estate. È lo stesso inciampo
  /// costato una data sbagliata sugli eventi di usc.sm.
  DateTime? _data(dynamic grezzo) {
    final s = grezzo?.toString().trim() ?? '';
    if (s.length != 8 || int.tryParse(s) == null) return null;
    final anno = int.parse(s.substring(0, 4));
    final mese = int.parse(s.substring(4, 6));
    final giorno = int.parse(s.substring(6, 8));
    if (mese < 1 || mese > 12 || giorno < 1 || giorno > 31) return null;
    final d = DateTime.utc(anno, mese, giorno);
    // Postgres non ha il 31 febbraio, e nemmeno DateTime.utc: normalizza invece
    // di rifiutare (31/02 diventa 03/03). Un giorno che scivola è un dato
    // falso, quindi si scarta.
    if (d.month != mese || d.day != giorno) return null;
    return d;
  }

  /// La descrizione: le parole della Fonte, non le nostre.
  ///
  /// Non c'è un campo descrizione nella risposta snella (il `content` del post
  /// pesa dieci volte e non serve: dell'Evento in lista interessano orario e
  /// ingresso). Si compone da `event_quando` — che dice cose che la sola data
  /// non dice, «i mercoledì alle 21:30» — e `event_ingresso`.
  String? _descrizione(Map<String, dynamic> acf) {
    final parti = <String>[
      ?_pulito(acf['event_quando']),
      if (_pulito(acf['event_ingresso']) case final i?) 'Ingresso: $i',
    ];
    return parti.isEmpty ? null : parti.join(' — ');
  }

  /// Testo ripulito, o `null` se non è rimasto niente. ACF restituisce stringhe
  /// vuote e `false` al posto dei campi non compilati, non `null`.
  String? _pulito(dynamic grezzo) {
    if (grezzo is! String) return null;
    final s = _testo(grezzo);
    return s.isEmpty ? null : s;
  }

  /// Via i tag e le entità: i titoli WordPress arrivano con `&#8220;` dentro, e
  /// finirebbero così com'è scritto sulla card.
  String _testo(String? grezzo) {
    if (grezzo == null) return '';
    return (parseFragment(grezzo).text ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  dynamic _dentro(dynamic mappa, String chiave) =>
      mappa is Map ? mappa.cast<String, dynamic>()[chiave] : null;
}
