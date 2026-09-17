#!/usr/bin/env bash
#
# Checkmarx One - Contribuyentes sobre varias organizaciones
# Falabella | Lugapel - Santiago Rullan
#
# Para el caso de miles de repositorios repartidos en organizaciones distintas,
# cuando NO se quiere medir todo: solo una lista acotada de repositorios.
#
# Lee repos.txt y acepta los dos formatos, mezclados si hace falta:
#
#   1. El CSV que exporta GitHub, con o sin la linea de cabecera:
#        repository_organization,repository_name
#        falabella-supply-chain,APP00388-oms-mass-processes
#
#   2. Una entrada por renglon, con barra:
#        falabella-supply-chain/APP00388-oms-mass-processes
#
# Agrupa solo por organizacion, parte cada grupo en lotes y ejecuta el CLI una
# vez por lote, guardando la salida cruda.
#
# Es REANUDABLE: si un lote ya tiene su archivo, lo saltea. Si la corrida se
# corta, se vuelve a ejecutar y sigue donde quedo.
#
# POR QUE NO SE SUMAN LOS TOTALES DE CADA LOTE:
#   El total que devuelve cada lote esta deduplicado SOLO dentro de ese lote.
#   Quien commitea en repos de lotes distintos, o en organizaciones distintas,
#   aparece en varios y sumar lo cuenta dos veces. Por eso se guarda el detalle
#   de usuarios (--debug) y el total real se calcula despues, deduplicando por
#   mail, con consolidar_a_excel.py
#
# POR QUE UNA CORRIDA POR ORGANIZACION:
#   El CLI acepta varias organizaciones en --orgs, pero cuando se pasa --repos
#   la organizacion tiene que ser una sola: los nombres de repo van pelados y
#   se buscan dentro de esa organizacion.
#
# Uso:
#   ./contributor-count-multiorg.sh [tamano_de_lote]
#   Ejemplo: ./contributor-count-multiorg.sh 25
#

set -uo pipefail

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTA="$WORKDIR/repos.txt"
CX_VERSION="2.3.65"
LOTE="${1:-50}"

echo
echo "==============================================================="
echo " Checkmarx One - Contribuyentes, varias organizaciones"
echo "==============================================================="
echo

if ! [[ "$LOTE" =~ ^[0-9]+$ ]] || [ "$LOTE" -lt 1 ]; then
  echo "ERROR: el tamano de lote debe ser un numero mayor a 0."
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Lista
# ---------------------------------------------------------------------------

[ -f "$LISTA" ] || { echo "ERROR: falta repos.txt en esta carpeta."; exit 1; }

# Normaliza a  organizacion/repositorio  y deduplica.
#
# Acepta el CSV de GitHub (organizacion,repositorio) y tambien la forma con
# barra. La cabecera repository_organization se descarta sola. Se limpian URLs
# completas, el sufijo .git, comillas y espacios sobrantes.
ENTRADAS=()
while IFS= read -r N; do [ -n "$N" ] && ENTRADAS+=("$N"); done < <(
  sed 's/#.*//' "$LISTA" \
    | tr -d '\r' \
    | sed 's/"//g' \
    | grep -v -i '^[[:space:]]*repository_organization' \
    | awk -F',' '
        {
          gsub(/^[ \t]+|[ \t]+$/, "", $0)
          if ($0 == "") next
          if (NF >= 2) {
            org = $1; repo = $2
            gsub(/^[ \t]+|[ \t]+$/, "", org)
            gsub(/^[ \t]+|[ \t]+$/, "", repo)
            if (org != "" && repo != "") print org "/" repo
          } else {
            print $0
          }
        }' \
    | sed 's#^https\?://[^/]*/##' \
    | sed 's/\.git$//' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' \
    | awk '!vistos[$0]++'
)

TOTAL=${#ENTRADAS[@]}
[ "$TOTAL" -eq 0 ] && { echo "ERROR: repos.txt no tiene repositorios."; exit 1; }

# Separa las que traen organizacion de las que no
SIN_ORG=()
ORGS=()
for E in "${ENTRADAS[@]}"; do
  case "$E" in
    */*) O="${E%%/*}"
         case " ${ORGS[*]-} " in *" $O "*) ;; *) ORGS+=("$O") ;; esac ;;
    *)   SIN_ORG+=("$E") ;;
  esac
done

echo "[1/4] Lista leida"
echo "      Entradas unicas:     $TOTAL"
echo "      Organizaciones:      ${#ORGS[@]}"
echo

if [ ${#SIN_ORG[@]} -gt 0 ]; then
  echo "      ATENCION: ${#SIN_ORG[@]} entradas NO dicen a que organizacion"
  echo "      pertenecen. El formato esperado es  organizacion/repositorio"
  echo
  echo "      Primeras que faltan:"
  for R in "${SIN_ORG[@]:0:5}"; do echo "        $R"; done
  echo
  echo "      Esas entradas se van a IGNORAR. El CLI no puede resolverlas:"
  echo "      los nombres de repo van pelados y necesita saber la organizacion."
  echo
fi

[ ${#ORGS[@]} -eq 0 ] && {
  echo "ERROR: ninguna entrada tiene el formato organizacion/repositorio."
  exit 1
}

echo "      Detalle por organizacion:"
CANT_LOTES_TOTAL=0
for O in "${ORGS[@]}"; do
  C=0
  for E in "${ENTRADAS[@]}"; do [ "${E%%/*}" = "$O" ] && [ "$E" != "$O" ] && C=$((C+1)); done
  L=$(( (C + LOTE - 1) / LOTE ))
  CANT_LOTES_TOTAL=$(( CANT_LOTES_TOTAL + L ))
  printf "        %-40s %5d repos  %3d lotes\n" "$O" "$C" "$L"
done
echo
echo "      Tamano de lote:      $LOTE"
echo "      Lotes en total:      $CANT_LOTES_TOTAL"
echo
echo "      No hay un maximo documentado por Checkmarx ni de repos por"
echo "      llamada ni de llamadas por hora. El limite real es el rate limit"
echo "      de la API de GitHub: 5000 requests por hora con un token clasico."
echo "      Si empiezan a fallar lotes, esperar y volver a correr este mismo"
echo "      script, o bajar el lote: ./contributor-count-multiorg.sh 20"
echo

read -r -p "      Continuar? [s/N]: " OK
case "$OK" in s|S|si|SI|Si) ;; *) echo "      Cancelado."; exit 0 ;; esac
echo

# ---------------------------------------------------------------------------
# 2. CLI
# ---------------------------------------------------------------------------

if command -v cx >/dev/null 2>&1; then
  CX_BIN="cx"; echo "[2/4] CLI ya instalado."
elif [ -x "$WORKDIR/cx" ]; then
  CX_BIN="$WORKDIR/cx"; echo "[2/4] CLI encontrado en esta carpeta."
else
  echo "[2/4] Descargando el CLI ($CX_VERSION)..."
  SO="$(uname -s)"; ARCH="$(uname -m)"
  case "$SO" in
    Darwin) A="ast-cli_${CX_VERSION}_darwin_universal.tar.gz" ;;
    Linux)
      if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        A="ast-cli_${CX_VERSION}_linux_arm64.tar.gz"
      else A="ast-cli_${CX_VERSION}_linux_x64.tar.gz"; fi ;;
    *) echo "ERROR: sistema no reconocido ($SO)."; exit 1 ;;
  esac
  if ! curl -sSL -o "$WORKDIR/ast-cli.tar.gz" \
      "https://github.com/Checkmarx/ast-cli/releases/download/${CX_VERSION}/${A}"; then
    echo "ERROR: no se pudo descargar. Bajelo a mano de"
    echo "       https://github.com/Checkmarx/ast-cli/releases"
    echo "       y deje el binario 'cx' en esta carpeta."
    exit 1
  fi
  tar -xzf "$WORKDIR/ast-cli.tar.gz" -C "$WORKDIR"
  chmod +x "$WORKDIR/cx"; rm -f "$WORKDIR/ast-cli.tar.gz"
  [ "$SO" = "Darwin" ] && xattr -d com.apple.quarantine "$WORKDIR/cx" 2>/dev/null
  CX_BIN="$WORKDIR/cx"; echo "      Listo."
fi
echo "      Version: $($CX_BIN version 2>&1 | head -1)"
echo

# ---------------------------------------------------------------------------
# 3. Datos
# ---------------------------------------------------------------------------

echo "[3/4] Token de GitHub"
echo
echo "  Un solo token para todas las organizaciones. Necesita scope 'repo' y,"
echo "  si alguna organizacion tiene SSO, debe estar autorizado PARA CADA UNA."
echo "  No se muestra al escribirlo."
read -r -s -p "  > Token: " TOKEN
echo; echo
[ -z "$TOKEN" ] && { echo "ERROR: obligatorio."; exit 1; }
read -r -p "  > URL de la API (vacio si es github.com): " GH_URL
echo

SALIDA="$WORKDIR/lotes-multiorg"
mkdir -p "$SALIDA"

printf '%s\n' "${ENTRADAS[@]}" > "$SALIDA/_entradas-consultadas.txt"
printf '%s\n' "${ORGS[@]}" > "$SALIDA/_organizaciones.txt"
if [ ${#SIN_ORG[@]} -gt 0 ]; then
  printf '%s\n' "${SIN_ORG[@]}" > "$SALIDA/_ignoradas-sin-organizacion.txt"
fi

# ---------------------------------------------------------------------------
# 4. Lotes
# ---------------------------------------------------------------------------

echo "[4/4] Ejecutando $CANT_LOTES_TOTAL lotes sobre ${#ORGS[@]} organizaciones"
echo "      Los resultados se guardan en: $SALIDA"
echo "      Se puede cortar y reanudar: los lotes ya hechos se saltean."
echo

FALLARON=()
HECHOS=0
SALTEADOS=0
NUM=0

for O in "${ORGS[@]}"; do
  # Repos de esta organizacion, ya pelados
  PROPIOS=()
  for E in "${ENTRADAS[@]}"; do
    if [ "${E%%/*}" = "$O" ] && [ "$E" != "$O" ]; then
      PROPIOS+=("${E#*/}")
    fi
  done
  CANT=${#PROPIOS[@]}
  [ "$CANT" -eq 0 ] && continue

  echo "  --- $O ($CANT repos)"

  for (( i=0; i<CANT; i+=LOTE )); do
    NUM=$(( NUM + 1 ))
    NUM_PAD=$(printf "%03d" "$NUM")
    PARTE=("${PROPIOS[@]:i:LOTE}")
    CSV="$(IFS=','; echo "${PARTE[*]}")"

    ARCHIVO_JSON="$SALIDA/lote-${NUM_PAD}.json"
    ARCHIVO_TXT="$SALIDA/lote-${NUM_PAD}.txt"
    ARCHIVO_REPOS="$SALIDA/lote-${NUM_PAD}.repos.txt"

    if [ -s "$ARCHIVO_JSON" ]; then
      echo "      [$NUM/$CANT_LOTES_TOTAL] ya estaba hecho, se saltea"
      SALTEADOS=$(( SALTEADOS + 1 ))
      continue
    fi

    # El .repos.txt guarda organizacion/repo, para saber de donde salio cada uno
    for R in "${PARTE[@]}"; do echo "$O/$R"; done > "$ARCHIVO_REPOS"

    echo -n "      [$NUM/$CANT_LOTES_TOTAL] ${#PARTE[@]} repos... "

    ARGS=(utils contributor-count github
          --orgs "$O" --repos "$CSV" --token "$TOKEN"
          --debug --timeout 3600)
    [ -n "$GH_URL" ] && ARGS+=(--url "$GH_URL")

    "$CX_BIN" "${ARGS[@]}" > "$ARCHIVO_TXT" 2>&1
    EST_TXT=$?

    "$CX_BIN" "${ARGS[@]}" --format json > "$ARCHIVO_JSON" 2>/dev/null
    EST_JSON=$?

    if [ "$EST_TXT" -ne 0 ] && [ "$EST_JSON" -ne 0 ]; then
      # El lote fallo. Basta que UN repo de la lista no exista (archivado,
      # renombrado, borrado, o sin permiso) para que el CLI aborte la corrida
      # entera y se pierdan los otros 49. Por eso, en vez de descartar el lote,
      # se reintenta repo por repo: los que andan se guardan igual y los que
      # fallan quedan aislados en _fallidos.txt con su motivo.
      echo "FALLO - reintentando de a uno"
      rm -f "$ARCHIVO_JSON"

      SUB=0
      RESCATADOS=0
      for R in "${PARTE[@]}"; do
        SUB=$(( SUB + 1 ))
        SUB_PAD=$(printf "%03d" "$SUB")
        S_JSON="$SALIDA/lote-${NUM_PAD}-r${SUB_PAD}.json"
        S_TXT="$SALIDA/lote-${NUM_PAD}-r${SUB_PAD}.txt"
        S_REPOS="$SALIDA/lote-${NUM_PAD}-r${SUB_PAD}.repos.txt"

        [ -s "$S_JSON" ] && { RESCATADOS=$(( RESCATADOS + 1 )); continue; }

        echo "$O/$R" > "$S_REPOS"

        UNO=(utils contributor-count github
             --orgs "$O" --repos "$R" --token "$TOKEN"
             --debug --timeout 3600)
        [ -n "$GH_URL" ] && UNO+=(--url "$GH_URL")

        "$CX_BIN" "${UNO[@]}" > "$S_TXT" 2>&1
        E_TXT=$?
        "$CX_BIN" "${UNO[@]}" --format json > "$S_JSON" 2>/dev/null
        E_JSON=$?

        if [ "$E_TXT" -ne 0 ] && [ "$E_JSON" -ne 0 ]; then
          # Motivo, sacado del propio log del CLI
          MOTIVO="error desconocido"
          if grep -q '"status":"404"' "$S_TXT" 2>/dev/null; then
            MOTIVO="404 - no existe, fue renombrado, o el token no lo ve"
          elif grep -qi 'saml\|single sign\|sso' "$S_TXT" 2>/dev/null; then
            MOTIVO="SSO - el token no esta autorizado para esta organizacion"
          elif grep -q '"status":"401"' "$S_TXT" 2>/dev/null; then
            MOTIVO="401 - token invalido o vencido"
          elif grep -qi 'rate limit\|"status":"403"' "$S_TXT" 2>/dev/null; then
            MOTIVO="403 - rate limit o sin permiso"
          fi
          printf '%s/%s\t%s\n' "$O" "$R" "$MOTIVO" >> "$SALIDA/_fallidos.txt"
          rm -f "$S_JSON" "$S_REPOS"
        else
          RESCATADOS=$(( RESCATADOS + 1 ))
        fi
      done

      PERDIDOS=$(( ${#PARTE[@]} - RESCATADOS ))
      echo "          rescatados $RESCATADOS de ${#PARTE[@]}, fallaron $PERDIDOS"
      if [ "$RESCATADOS" -gt 0 ]; then
        HECHOS=$(( HECHOS + 1 ))
      else
        FALLARON+=("$NUM ($O)")
      fi
    else
      echo "ok"
      HECHOS=$(( HECHOS + 1 ))
    fi
  done
  echo
done

echo "==============================================================="
echo " Corrida terminada"
echo "==============================================================="
echo
echo " Organizaciones:   ${#ORGS[@]}"
echo " Lotes ejecutados: $HECHOS"
echo " Lotes salteados:  $SALTEADOS (ya estaban)"
echo " Lotes perdidos:   ${#FALLARON[@]} (ni un repo se pudo medir)"

if [ -s "$SALIDA/_fallidos.txt" ]; then
  CANT_FALL=$(wc -l < "$SALIDA/_fallidos.txt" | tr -d ' ')
  echo
  echo " REPOSITORIOS QUE NO SE PUDIERON MEDIR: $CANT_FALL"
  echo " La lista completa, con el motivo de cada uno, esta en:"
  echo "   $SALIDA/_fallidos.txt"
  echo
  echo " Resumen por motivo:"
  cut -f2 "$SALIDA/_fallidos.txt" | sort | uniq -c | sort -rn \
    | while read -r C M; do printf "   %5d  %s\n" "$C" "$M"; done
  echo
  echo " El resto SI se midio. Estos repos quedan afuera del total, asi que"
  echo " el numero final es sobre los repositorios que si respondieron."
  echo " Conviene revisar la lista con el cliente antes de dar el numero:"
  echo " un 404 suele ser un repo archivado o renombrado."
fi

if [ ${#FALLARON[@]} -gt 0 ]; then
  echo
  echo " Fallaron: ${FALLARON[*]}"
  echo
  echo " Revise el .txt de alguno para ver el error, por ejemplo:"
  echo "   cat $SALIDA/lote-001.txt"
  echo
  echo " Si el error habla de SSO, el token no esta autorizado para esa"
  echo " organizacion en particular. Se autoriza desde la lista de tokens"
  echo " en GitHub, una por una."
  echo
  echo " Si es rate limit, esperar y volver a correr este mismo script:"
  echo " va a saltear los que ya estan y reintentar solo los que faltan."
  echo
  echo " NO consolidar a Excel hasta que no falle ningun lote: el total"
  echo " saldria incompleto."
fi

echo
echo " PASO SIGUIENTE - armar el Excel:"
echo
echo "   python3 consolidar_a_excel.py \"$SALIDA\""
echo
echo " El total real se calcula ahi, deduplicando por mail entre TODOS los"
echo " lotes y TODAS las organizaciones. No sumar los totales de cada lote:"
echo " contaria dos veces a quien commitea en varios repos u organizaciones."
echo
echo " El token NO quedo guardado en ningun archivo."
echo
