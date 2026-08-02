# Omni — ingestione delle Notizie e degli Eventi

Legge i feed delle testate sammarinesi, normalizza gli articoli, toglie i
doppioni e li consegna all'app [Omni](https://omnism.it).

Gira da solo ogni ora, dalle 7 alle 23 (ora di San Marino), su GitHub Actions.

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
che sa fare tre cose e nient'altro:

| Azione | Cosa fa |
|---|---|
| `fonti` | restituisce le Fonti attive da leggere |
| `righe` | upsert su `notizia` e `evento` — solo quelle due tabelle |
| `esito` | scrive una riga di diagnostica nel registro |

Se il token trapela, il danno è «ci inseriscono notizie finte»: brutto,
riparabile, circoscritto. Non è «il database è di chiunque».

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
```

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

`lib/dedup_service.dart` e i parser sono **copie** di file che vivono anche nel
repo dell'app. La `dedup_key` che si genera qui è un contratto col vincolo unique
sulla tabella: se cambia la normalizzazione del titolo qui e non là, ricompaiono
i doppioni. Chi modifica la normalizzazione deve toccare tutt'e due.

## Licenza

Il codice è pubblico perché deve girare su Actions gratuite, non come invito a
riusarlo: nessuna licenza concessa.
