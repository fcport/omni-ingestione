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
#
# Fallire una Fonte non ferma le altre, ma il giro chiude ROSSO: un job verde
# con dentro un 404 è esattamente il modo in cui le tre settimane qui sopra sono
# passate inosservate. (Il `< <(...)` invece della pipeline serve a non perdere
# l'array in una subshell.)
ko=()

while read -r f; do
  fid="$(echo "$f" | jq -r '.id')"
  fnome="$(echo "$f" | jq -r '.nome')"
  furl="$(echo "$f" | jq -r '.config.url')"
  fsel="$(echo "$f" | jq -c '.config.selettori')"
  fbase="$(echo "$f" | jq -r '.config.base // empty')"
  if [ -z "$furl" ] || [ "$furl" = "null" ]; then
    echo "  (salto $fnome: manca config.url)"; continue
  fi
  echo "→ $fnome (fonte $fid) — istituzionale"
  # `config.base` è opzionale e serve quando i link di dettaglio sono relativi a
  # una cartella diversa da quella dell'indice. Sul Consiglio Grande e Generale
  # l'indice è `/on-line/home.html` e i link sono `articoloNNNN.html`: risolti
  # contro l'indice diventano `/on-line/articoloNNNN.html`, che il CMS serve con
  # **200 e il contenuto della home** invece di un 404. Il crawl "riesce" e
  # ingerisce la pagina sbagliata — il tipo di guasto che non si vede.
  if ! dart run bin/ingest.dart --formato html --tipo istituzionale --fonte "$fid" \
    --url "$furl" ${fbase:+--base "$fbase"} --selettori "$fsel" --push; then
    echo "  ⚠ $fnome: ingestione fallita, continuo"
    ko+=("$fnome")
  fi
done < <(echo "$fonti" \
  | jq -c '.fonti[] | select(.config.tipo=="istituzionale" and .config.formato=="html")')

if [ "${#ko[@]}" -eq 0 ]; then
  echo "✓ Ingestione istituzionale completata: tutte le Fonti hanno consegnato."
  exit 0
fi

echo
if [ "${#ko[@]}" -eq 1 ]; then
  echo "✗ Ingestione istituzionale completata, ma una Fonte non ha consegnato:"
else
  echo "✗ Ingestione istituzionale completata, ma ${#ko[@]} Fonti non hanno consegnato:"
fi
for nome in "${ko[@]}"; do echo "   · $nome"; done
echo "  (il dettaglio è nel registro \`ingestione_esito\`, tipo='istituzionale')"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Fonti istituzionali che non hanno consegnato (${#ko[@]})"
    for nome in "${ko[@]}"; do echo "- $nome"; done
  } >> "$GITHUB_STEP_SUMMARY"
fi

exit 1
