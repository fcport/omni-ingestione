#!/usr/bin/env bash
# Ingestione delle Fonti ISTITUZIONALI: popola `documento_istituzionale`
# crawlando le pagine-indice configurate in `fonte` (config.tipo='istituzionale').
# È la base di conoscenza che Omni-AI cita al cittadino.
#
# Separata dal feed Notizie/Eventi: gira SETTIMANALMENTE, non ogni ora — gli atti
# cambiano lentamente e le pagine di dettaglio si crawlano una per una.
#
# Come `ingest_all.sh`, l'elenco delle Fonti NON è cablato qui: lo chiede al
# ponte. Aggiungerne una resta una riga nella tabella `fonte`.
#
# Variabili d'ambiente:
#   SUPABASE_URL   host del progetto (non è un segreto)
#   INGEST_TOKEN   il segreto: autorizza il ponte, e solo quello
#
# In locale: `set -a; . ./.env.ingest; set +a; bash tool/ingest_istituzionale.sh`
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

# Una Fonte che fallisce NON blocca le altre. Nella versione che stava nel repo
# privato mancava il `|| echo` e lo script girava sotto `set -e`: dal 13 luglio
# 2026 l'indice del Congresso di Stato rispondeva 404, il job moriva sulla prima
# Fonte e il Consiglio Grande e Generale non veniva nemmeno provato. Tre
# settimane di ingestione istituzionale a zero per una sola pagina spostata.
echo "$fonti" \
| jq -c '.fonti[] | select(.config.tipo=="istituzionale" and .config.formato=="html")' \
| while read -r f; do
  fid="$(echo "$f" | jq -r '.id')"
  fnome="$(echo "$f" | jq -r '.nome')"
  furl="$(echo "$f" | jq -r '.config.url')"
  fsel="$(echo "$f" | jq -c '.config.selettori')"
  if [ -z "$furl" ] || [ "$furl" = "null" ]; then
    echo "  (salto $fnome: manca config.url)"; continue
  fi
  echo "→ $fnome (fonte $fid) — istituzionale"
  dart run bin/ingest.dart --formato html --tipo istituzionale --fonte "$fid" \
    --url "$furl" --selettori "$fsel" --push \
    || echo "  ⚠ $fnome: ingestione fallita, continuo"
done

echo "✓ Ingestione istituzionale completata."
echo "  (gli errori per Fonte sono nel registro \`ingestione_esito\`, tipo='istituzionale')"
