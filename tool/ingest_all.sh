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

# Le Fonti che non hanno consegnato. Una Fonte che fallisce NON blocca le altre
# — il feed morto di una testata non deve fermare l'ingestione di tutte — ma non
# passa nemmeno inosservata: il giro chiude ROSSO.
#
# PERCHÉ. Fino al 5 agosto 2026 il `|| echo` bastava a sé stesso: il job usciva
# 0 comunque, e sul cruscotto delle Actions una fila di spunte verdi diceva che
# l'ingestione andava. Andava a metà — quattro Fonti su otto rispondevano 403
# da giorni (le testate hanno iniziato a bloccare gli IP dei runner) e una
# consegnava un feed vuoto. Nessuno se n'era accorto, perché non c'era niente
# da accorgersi: il verde era il colore di tutti i giri, riusciti o no.
#
# Nota sul `< <(...)`: la pipeline `| while` metterebbe il ciclo in una
# subshell, e l'array delle Fonti KO morirebbe lì dentro.
ko=()

# Notizie via RSS.
while read -r f; do
  fid="$(echo "$f" | jq -r '.id')"
  fnome="$(echo "$f" | jq -r '.nome')"
  furl="$(echo "$f" | jq -r '.config.url')"
  if [ -z "$furl" ] || [ "$furl" = "null" ]; then
    echo "  (salto $fnome: manca config.url)"; continue
  fi
  echo "→ $fnome (fonte $fid) — notizie RSS"
  if ! dart run bin/ingest.dart --formato rss --tipo notizia --fonte "$fid" \
    --url "$furl" --push; then
    echo "  ⚠ $fnome: ingestione fallita, continuo"
    ko+=("$fnome")
  fi
done < <(echo "$fonti" \
  | jq -c '.fonti[] | select(.config.tipo=="notizia" and .config.formato=="rss")')

# Eventi via scraping: url e selettori vengono dalla `config` della Fonte.
while read -r f; do
  fid="$(echo "$f" | jq -r '.id')"
  fnome="$(echo "$f" | jq -r '.nome')"
  furl="$(echo "$f" | jq -r '.config.url')"
  fsel="$(echo "$f" | jq -c '.config.selettori')"
  if [ -z "$furl" ] || [ "$furl" = "null" ]; then
    echo "  (salto $fnome: manca config.url)"; continue
  fi
  echo "→ $fnome (fonte $fid) — eventi scraping"
  if ! dart run bin/ingest.dart --formato html --tipo evento --fonte "$fid" \
    --url "$furl" --selettori "$fsel" --push; then
    echo "  ⚠ $fnome: ingestione fallita, continuo"
    ko+=("$fnome")
  fi
done < <(echo "$fonti" \
  | jq -c '.fonti[] | select(.config.tipo=="evento" and .config.formato=="html")')

if [ "${#ko[@]}" -eq 0 ]; then
  echo "✓ Ingestione completata: tutte le Fonti hanno consegnato."
  exit 0
fi

echo
if [ "${#ko[@]}" -eq 1 ]; then
  echo "✗ Ingestione completata, ma una Fonte non ha consegnato:"
else
  echo "✗ Ingestione completata, ma ${#ko[@]} Fonti non hanno consegnato:"
fi
for nome in "${ko[@]}"; do echo "   · $nome"; done
echo "  (il dettaglio per Fonte è nel registro \`ingestione_esito\`)"

# Su GitHub il riepilogo si legge dalla pagina del run, senza aprire i log: chi
# guarda un job rosso deve capire QUALE Fonte è caduta in due secondi.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Fonti che non hanno consegnato (${#ko[@]})"
    for nome in "${ko[@]}"; do echo "- $nome"; done
  } >> "$GITHUB_STEP_SUMMARY"
fi

exit 1
