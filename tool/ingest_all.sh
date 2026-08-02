#!/usr/bin/env bash
# Ingerisce tutte le Fonti attive di Notizie ed Eventi.
#
# L'elenco delle Fonti NON è cablato qui: lo chiede al ponte, che lo legge dal
# database. Aggiungere una testata resta una riga nella tabella `fonte` — questo
# script non si tocca.
#
# Variabili d'ambiente:
#   SUPABASE_URL   host del progetto (non è un segreto)
#   INGEST_TOKEN   il segreto: autorizza il ponte, e solo quello
#
# In locale: `set -a; . ./.env.ingest; set +a; bash tool/ingest_all.sh`
set -euo pipefail

: "${SUPABASE_URL:?Imposta SUPABASE_URL}"
: "${INGEST_TOKEN:?Imposta INGEST_TOKEN}"

ponte="$SUPABASE_URL/functions/v1/ingestione-ponte"

fonti="$(curl -sS -X POST "$ponte" \
  -H "Authorization: Bearer $INGEST_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"azione":"fonti"}')"

if ! echo "$fonti" | jq -e '.fonti' >/dev/null 2>&1; then
  echo "Il ponte non ha restituito le Fonti: $fonti" >&2
  exit 1
fi

# Notizie via RSS. Una Fonte che fallisce NON blocca le altre: il feed morto di
# una testata non deve fermare l'ingestione di tutte le altre.
echo "$fonti" \
| jq -c '.fonti[] | select(.config.tipo=="notizia" and .config.formato=="rss")' \
| while read -r f; do
  fid="$(echo "$f" | jq -r '.id')"
  fnome="$(echo "$f" | jq -r '.nome')"
  furl="$(echo "$f" | jq -r '.config.url')"
  if [ -z "$furl" ] || [ "$furl" = "null" ]; then
    echo "  (salto $fnome: manca config.url)"; continue
  fi
  echo "→ $fnome (fonte $fid) — notizie RSS"
  dart run bin/ingest.dart --formato rss --tipo notizia --fonte "$fid" \
    --url "$furl" --push || echo "  ⚠ $fnome: ingestione fallita, continuo"
done

# Eventi via scraping: url e selettori vengono dalla `config` della Fonte.
echo "$fonti" \
| jq -c '.fonti[] | select(.config.tipo=="evento" and .config.formato=="html")' \
| while read -r f; do
  fid="$(echo "$f" | jq -r '.id')"
  fnome="$(echo "$f" | jq -r '.nome')"
  furl="$(echo "$f" | jq -r '.config.url')"
  fsel="$(echo "$f" | jq -c '.config.selettori')"
  if [ -z "$furl" ] || [ "$furl" = "null" ]; then
    echo "  (salto $fnome: manca config.url)"; continue
  fi
  echo "→ $fnome (fonte $fid) — eventi scraping"
  dart run bin/ingest.dart --formato html --tipo evento --fonte "$fid" \
    --url "$furl" --selettori "$fsel" --push || echo "  ⚠ $fnome: ingestione fallita, continuo"
done

echo "✓ Ingestione completata."
