# Omni — ingestione dei contenuti pubblici di San Marino

Legge le fonti sammarinesi, normalizza quello che pubblicano, toglie i doppioni
e lo consegna all'app [Omni](https://omnism.it).

Cinque canali, cadenze diverse, tutti su GitHub Actions:

| Canale | Quando | Cosa porta |
|---|---|---|
| Notizie (RSS) | ogni ora, 7–23 | gli articoli delle testate |
| Eventi (scraping) | ogni ora, 7–23 | i calendari degli eventi |
| Bandi (gov.sm) | ogni notte | concorsi e selezioni, in coda di revisione |
| Istituzionale | ogni notte | atti e comunicati, per l'assistente Omni-AI |
| Normativa | ogni notte | leggi, decreti, regolamenti e testi coordinati, per Omni-AI |

Bandi e istituzionale sono arrivati qui il 2026-08-04, dal repo privato. Non per
i minuti — insieme ne facevano una trentina al mese — ma perché i parser
vivevano in due posti: due copie da tenere allineate, e due posti dove guardare
quando qualcosa si rompe. L'ingestione istituzionale è rimasta rotta tre
settimane senza che nessuno se ne accorgesse.

## Perché questo repo è pubblico, e l'app no

Le GitHub Actions sono **illimitate sui repo pubblici** e contate su quelli
privati. Dal **21 al 31 luglio 2026** l'ingestione è rimasta ferma undici
giorni: i 2.000 minuti del piano erano esauriti e i job non partivano nemmeno.
L'app ha mostrato notizie ferme per una settimana e mezza, e nessuno se n'è
accorto finché il contatore mensile non si è azzerato da solo il 1° agosto.

Qui dentro non c'è niente di segreto: sono parser di RSS e HTML. **Quali**
testate leggiamo, con quali selettori, sta nel database — non nel codice.

## Come tocca il database: il ponte

Questo repo **non ha le chiavi del database**. Non ha la `service role key` di
Supabase, che bypassa RLS e aprirebbe tutto: i dati dei cittadini, i voti della
Piazza, le chat del Mercatino. I secret di un repo pubblico sono tecnicamente
protetti — non finiscono nei log, i fork non li ricevono — ma è una superficie
d'errore troppo larga per una chiave che apre ogni porta.

Al suo posto c'è un `INGEST_TOKEN` che parla con una Edge Function, il **ponte**,
che sa fare quattro cose e nient'altro:

| Azione | Cosa fa |
|---|---|
| `fonti` | restituisce le Fonti attive da leggere |
| `righe` | upsert su `notizia`, `evento`, `documento_istituzionale` — solo quelle |
| `bandi` | la RPC che mette i bandi in coda di revisione, quella sola |
| `esito` | scrive una riga di diagnostica nel registro |
| `sorgente` | scarica il feed di una Fonte attiva dall'IP di Supabase |
| `atti_noti` | gli URL degli atti normativi già in tabella |
| `atto` | un atto normativo e i suoi brani, in una transazione |
| `coordinati_vigenti` | ritira i testi coordinati superati da una versione nuova |

Le azioni sono **nominate**: non esiste un'azione `rpc` con il nome della
funzione a parametro, né una tabella scelta liberamente dal chiamante. Sarebbe
di nuovo la chiave del database, con un passaggio in più.

Se il token trapela, il danno è «ci inseriscono contenuti finti»: brutto,
riparabile, circoscritto. Non è «il database è di chiunque». Con una avvertenza:
`documento_istituzionale` è ciò che l'assistente cita al cittadino come fonte
ufficiale, quindi lì ruotare il token non basta — va guardato anche cosa c'è
finito dentro.

## Come gira

```bash
# Dry-run su una fixture: nessuna scrittura, stampa le righe normalizzate
dart run bin/ingest.dart --formato rss --tipo notizia --fonte 1 \
  --fixture test/fixtures/notizie.rss.xml

# Sul serio, su una Fonte vera
export SUPABASE_URL=https://<progetto>.supabase.co
export INGEST_TOKEN=<il token>
dart run bin/ingest.dart --formato rss --tipo notizia --fonte 3 \
  --url https://esempio.sm/feed/ --push

# Tutte le Fonti attive, come fa il cron
bash tool/ingest_all.sh

# Bandi di gov.sm: dry-run leggibile, poi la coda di revisione
dart run bin/bandi.dart --limit 5
dart run bin/bandi.dart --limit 30 --push

# Atti e comunicati per Omni-AI (crawl indice → pagine di dettaglio)
bash tool/ingest_istituzionale.sh

# Leggi e decreti dall'Archivio del Consiglio Grande e Generale (serve
# `pdftotext`, pacchetto poppler-utils): dry-run su pochi atti, poi sul serio
dart run bin/normativa.dart --dal 2025 --al 2025 --max-nuovi 5
dart run bin/normativa.dart --dal 1600 --coordinati --push
```

**La normativa** sono 11.165 atti dal 1600 a oggi, ognuno un PDF, più una
novantina di testi coordinati (le leggi con le modifiche già dentro). Il primo
giro è un lavoro di ore e si spezza su più notti (`--max-nuovi`); dopo, un atto
già in tabella non si riscarica e il giro dura pochi minuti. Ogni atto è
spezzato in **brani**, uno per articolo (`lib/normativa/brani.dart`): è
l'unità che Omni-AI cerca e cita. Il titolo di ogni atto dice anche quali atti
tocca («Modifica della Legge 25 luglio 2025 n.101»): `lib/normativa/riferimenti.dart`
ne ricava le chiavi, e l'app le usa per avvisare che un testo è stato
modificato dopo.

**Aggiungere una testata non si fa qui:** è una riga nella tabella `fonte`, con
il suo `config` (formato, tipo, url, selettori). Lo script chiede l'elenco al
ponte a ogni giro.

## Il numero da guardare

Ogni giro lascia una riga nel registro con `documenti` (quanti articoli espone
il feed), `righe` (quante ne abbiamo passate) e **`nuove`** (quante non erano
già nostre).

Se `nuove` è quasi sempre **0**, va tutto bene: il feed non ha novità. Se invece
`nuove` si avvicina a `documenti` a ogni giro, vuol dire che fra un giro e
l'altro il feed si è rinnovato per intero — e quello che è uscito nel mezzo
**l'abbiamo perso**. Quei feed espongono solo 20-25 articoli: una giornata
prolifica scorre via in poche ore.

## Una nota per chi tocca il codice

`lib/dedup_service.dart`, i parser del feed e quelli dei bandi sono **copie** di
file che vivono anche nel repo dell'app, dove i workflow gemelli restano
lanciabili a mano come rete di sicurezza. La `dedup_key` che si genera qui è un
contratto col vincolo unique sulla tabella: se cambia la normalizzazione del
titolo qui e non là, ricompaiono i doppioni. Chi modifica la normalizzazione deve
toccare tutt'e due.

Questo repo è la copia **operativa**: è quella che gira ogni giorno. Se le due
divergono, ha ragione questa.

## Licenza

Il codice è pubblico perché deve girare su Actions gratuite, non come invito a
riusarlo: nessuna licenza concessa.
