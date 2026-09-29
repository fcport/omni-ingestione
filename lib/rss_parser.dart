import 'package:xml/xml.dart';

import 'documento_grezzo.dart';
import 'parser_data.dart';

/// Estrae [DocumentoGrezzo] da un feed RSS 2.0 (la maggior parte delle testate
/// sanmarinesi espone RSS; lo privilegiamo allo scraping — più stabile e
/// rispettoso del copyright). Puro: riceve la stringa XML, niente rete.
class RssParser {
  const RssParser();

  /// Un documento per ogni `<item>`. Gli item privi di titolo o link vengono
  /// ignorati (non normalizzabili).
  List<DocumentoGrezzo> parse(String xmlGrezzo) {
    final doc = XmlDocument.parse(xmlGrezzo);
    final out = <DocumentoGrezzo>[];
    for (final item in doc.findAllElements('item')) {
      final titolo = _testo(item, 'title');
      final link = _testo(item, 'link');
      if (titolo == null || link == null) continue;
      out.add(
        DocumentoGrezzo(
          titolo: titolo,
          url: link,
          testo: _testo(item, 'description'),
          immagine: _immagine(item),
          // Il `pubDate` è un istante: il fuso si applica (vedi `parseData`).
          data: parseData(_testo(item, 'pubDate'), rispettaFuso: true),
        ),
      );
    }
    return out;
  }

  String? _testo(XmlElement item, String tag) {
    final el = item.findElements(tag);
    if (el.isEmpty) return null;
    final t = el.first.innerText.trim();
    return t.isEmpty ? null : t;
  }

  /// Cerca l'immagine in `enclosure`, `media:content`/`media:thumbnail`,
  /// `image` e, come ultimo ripiego, la prima `<img>` nel corpo HTML
  /// (`content:encoded` o `description`) — molti feed WordPress (es. Giornale SM)
  /// non espongono enclosure/media ma includono la foto inline nell'articolo.
  String? _immagine(XmlElement item) {
    for (final tag in ['enclosure', 'media:content', 'media:thumbnail']) {
      final el = item.findElements(tag);
      if (el.isNotEmpty) {
        final url = el.first.getAttribute('url');
        if (url != null && url.isNotEmpty) return url;
      }
    }
    final image = item.findElements('image');
    if (image.isNotEmpty) {
      final t = image.first.innerText.trim();
      if (t.isNotEmpty) return t;
    }
    for (final tag in ['content:encoded', 'description']) {
      final el = item.findElements(tag);
      if (el.isEmpty) continue;
      final src = _primaImgHtml(el.first.innerText);
      if (src != null) return src;
    }
    return null;
  }

  /// Prima `src` di un `<img>` nel frammento HTML, ignorando i placeholder
  /// `data:` (es. immagini lazy-load codificate inline).
  static final _imgSrc = RegExp(
    r'''<img[^>]+src\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  );

  String? _primaImgHtml(String html) {
    for (final m in _imgSrc.allMatches(html)) {
      final src = m.group(1)?.trim();
      if (src == null || src.isEmpty || src.startsWith('data:')) continue;
      return src;
    }
    return null;
  }
}
