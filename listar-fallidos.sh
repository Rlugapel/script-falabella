#!/usr/bin/env bash
#
# Checkmarx One - Lista de repositorios que NO se pudieron medir
# Falabella | Lugapel - Santiago Rullan
#
# NO vuelve a correr nada contra GitHub. Lee lo que ya quedo en lotes-multiorg/
# y arma la lista de repos fallidos, con el motivo de cada uno, a partir de los
# archivos que dejo contributor-count-multiorg.sh.
#
# Sirve aunque _fallidos.txt no exista o haya quedado incompleto (por ejemplo,
# si la corrida se corto y se reanudo, o si se uso una version anterior del script).
#
# Uso:
#   ./listar-fallidos.sh            (busca lotes-multiorg/ en esta carpeta)
#   ./listar-fallidos.sh <carpeta>
#

set -uo pipefail

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SALIDA="${1:-$WORKDIR/lotes-multiorg}"
[ -d "$SALIDA" ] || { echo "ERROR: no existe la carpeta $SALIDA"; exit 1; }

REPORTE="$SALIDA/_fallidos-reconstruido.txt"
: > "$REPORTE"

motivo() {
  local T="$1"
  [ -f "$T" ] || { echo "sin log (el reintento no llego a correr)"; return; }
  if grep -q '"status":"404"' "$T" 2>/dev/null; then
    echo "404 - no existe, fue renombrado, o el token no lo ve"
  elif grep -qi 'saml\|single sign\|sso' "$T" 2>/dev/null; then
    echo "SSO - el token no esta autorizado para esta organizacion"
  elif grep -q '"status":"401"' "$T" 2>/dev/null; then
    echo "401 - token invalido o vencido"
  elif grep -qi 'rate limit\|"status":"403"' "$T" 2>/dev/null; then
    echo "403 - rate limit o sin permiso"
  else
    echo "error desconocido (ver $(basename "$T"))"
  fi
}

LOTES_FALLIDOS=0
for REPOS in "$SALIDA"/lote-[0-9][0-9][0-9].repos.txt; do
  [ -e "$REPOS" ] || continue
  BASE="${REPOS%.repos.txt}"
  # Si el lote tiene su .json, se midio entero: no hay fallidos ahi
  [ -s "$BASE.json" ] && continue

  LOTES_FALLIDOS=$(( LOTES_FALLIDOS + 1 ))
  LOTE_NUM="$(basename "$BASE")"
  SUB=0
  while IFS= read -r ORG_REPO; do
    [ -z "$ORG_REPO" ] && continue
    SUB=$(( SUB + 1 ))
    SUB_PAD=$(printf "%03d" "$SUB")
    R_JSON="$BASE-r${SUB_PAD}.json"
    R_TXT="$BASE-r${SUB_PAD}.txt"
    if [ ! -s "$R_JSON" ]; then
      printf '%s\t%s\t%s\n' "$ORG_REPO" "$(motivo "$R_TXT")" "$LOTE_NUM" >> "$REPORTE"
    fi
  done < "$REPOS"
done

echo
echo "==============================================================="
echo " Repositorios que NO se pudieron medir"
echo "==============================================================="
echo
echo " Lotes con errores: $LOTES_FALLIDOS"

if [ ! -s "$REPORTE" ]; then
  echo " Repos fallidos:    0"
  echo
  echo " Todos los repos de los lotes con error se rescataron en el reintento."
  exit 0
fi

CANT=$(wc -l < "$REPORTE" | tr -d ' ')
echo " Repos fallidos:    $CANT"
echo
printf " %-60s %s\n" "REPOSITORIO" "MOTIVO"
printf " %-60s %s\n" "-----------" "------"
sort "$REPORTE" | while IFS=$'\t' read -r R M L; do
  printf " %-60s %s\n" "$R" "$M"
done
echo
echo " Resumen por motivo:"
cut -f2 "$REPORTE" | sort | uniq -c | sort -rn \
  | while read -r C M; do printf "   %5d  %s\n" "$C" "$M"; done
echo
echo " Lista guardada en:"
echo "   $REPORTE"
echo "   (columnas: repositorio, motivo, lote)"
echo
echo " Como leerlo:"
echo "   404  -> repo archivado, renombrado o borrado. Si no tuvo commits en"
echo "           los ultimos 90 dias, no suma contribuyentes: se puede ignorar."
echo "   SSO  -> autorizar el token para esa organizacion en GitHub y volver"
echo "           a correr contributor-count-multiorg.sh (es reanudable)."
echo "   403  -> rate limit: esperar y volver a correr."
echo
