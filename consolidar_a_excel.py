#!/usr/bin/env python3
"""Consolida las salidas por lote del CLI de Checkmarx One en un solo Excel.

Lee la carpeta que genera contributor-count-lotes.sh, junta el detalle de
usuarios de todos los lotes, deduplica por mail y arma el archivo final.

Por que se deduplica aca y no se suman los totales de cada lote
--------------------------------------------------------------
El CLI deduplica contribuyentes DENTRO de cada corrida. Si la lista se parte
en lotes, quien commitea en repos de lotes distintos aparece en los dos y
sumar los totales lo cuenta dos veces. El unico total correcto sale de juntar
los mails de todos los lotes y contar los unicos.

Sobre el formato de entrada
---------------------------
La documentacion de Checkmarx describe que --debug devuelve "el username de
cada contribuyente y los repos a los que contribuyo", pero NO publica el
esquema del JSON. Por eso este script no asume una estructura.

De donde se leen los mails, en este orden:
  1. Del JSON del lote, si el lote lo genero.
  2. Si no, de la tabla final del .txt, la que arranca con el encabezado
     UniqueContributorsEmail.

Lo que este script NO hace, a proposito: barrer el .txt entero buscando
mails. Antes de la tabla final, --debug vuelca unos 234 KB de logs HTTP en
crudo donde aparecen mails que no son contribuyentes contados. Leer todo ese
texto inflaba el total. Ver la nota de CABECERA_TABLA mas abajo.

La hoja Diagnostico deja constancia de por donde salio cada lote.

Uso
---
    python3 consolidar_a_excel.py <carpeta-de-lotes> [salida.xlsx]
"""

import json
import pathlib
import re
import sys
from collections import defaultdict

from openpyxl import Workbook
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter

RE_MAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")

AZUL = PatternFill("solid", fgColor="1F4E79")
GRIS = PatternFill("solid", fgColor="D9D9D9")
NARANJA = PatternFill("solid", fgColor="FCE4D6")
BLANCO_NEGRITA = Font(bold=True, color="FFFFFF")
NEGRITA = Font(bold=True)


def buscar_mails(nodo, encontrados):
    """Recorre cualquier JSON y junta (mail, nombre_probable) de donde aparezcan."""
    if isinstance(nodo, dict):
        mail = None
        nombre = None
        for clave, valor in nodo.items():
            cl = clave.lower()
            if isinstance(valor, str):
                if "mail" in cl and RE_MAIL.fullmatch(valor.strip()):
                    mail = valor.strip()
                elif cl in ("name", "username", "author", "user", "login", "displayname"):
                    nombre = valor.strip()
        if mail:
            encontrados.append((mail, nombre or ""))
        for valor in nodo.values():
            buscar_mails(valor, encontrados)
    elif isinstance(nodo, list):
        for item in nodo:
            buscar_mails(item, encontrados)
    elif isinstance(nodo, str):
        for m in RE_MAIL.findall(nodo):
            encontrados.append((m.strip(), ""))


# La tabla de detalle que imprime --debug arranca con este encabezado.
# TODO lo anterior son logs HTTP crudos: headers, JSON completo de cada commit,
# firmas PGP. Ahi aparecen mails que NO son contribuyentes contados (autores
# fuera de la ventana de 90 dias, co-authors, noreply@github.com...).
# Verificado el 16/09/2026 contra la organizacion Checkmarx: el output entero
# tenia 29 mails distintos y el conteo real del CLI era 18. Leer todo el texto
# inflaba el numero un 61%.
CABECERA_TABLA = "UniqueContributorsEmail"


def _tabla_de_detalle(texto):
    """Extrae (mail, nombre) SOLO de la tabla final que imprime --debug."""
    pos = texto.rfind(CABECERA_TABLA)
    if pos == -1:
        return None
    hallados = []
    for linea in texto[pos:].splitlines()[1:]:
        if not linea.strip() or linea.lstrip().startswith("----"):
            continue
        mails = RE_MAIL.findall(linea)
        if not mails:
            continue
        mail = mails[0]
        resto = linea.split(mail, 1)[1].strip()
        hallados.append((mail, resto))
    return hallados


def leer_lote(json_path, txt_path):
    """Devuelve (lista de (mail, nombre), origen)."""
    # 1. la tabla de detalle del .txt es la fuente mas confiable
    if txt_path.exists():
        texto = txt_path.read_text(encoding="utf-8", errors="replace")
        hallados = _tabla_de_detalle(texto)
        if hallados:
            return hallados, "tabla --debug"

    # 2. el json, recorrido buscando claves de mail
    if json_path.exists() and json_path.stat().st_size > 0:
        try:
            datos = json.loads(json_path.read_text(encoding="utf-8", errors="replace"))
            hallados = []
            buscar_mails(datos, hallados)
            if hallados:
                return hallados, "json"
        except json.JSONDecodeError:
            pass

    # 3. NO se cae a barrer el .txt entero a ciegas: inflaria el conteo.
    return [], "SIN DATOS"


def ancho(hoja):
    for col in hoja.columns:
        largo = max((len(str(c.value)) for c in col if c.value is not None), default=0)
        letra = get_column_letter(col[0].column)
        hoja.column_dimensions[letra].width = min(max(largo + 3, 12), 60)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    carpeta = pathlib.Path(sys.argv[1])
    if not carpeta.is_dir():
        print(f"ERROR: no existe la carpeta {carpeta}")
        sys.exit(1)

    salida = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 \
        else carpeta.parent / f"contribuyentes-{carpeta.name}.xlsx"

    lotes = sorted(carpeta.glob("lote-*.json"))
    if not lotes:
        print(f"ERROR: no hay archivos lote-*.json en {carpeta}")
        print("       Corra primero contributor-count-lotes.sh")
        sys.exit(1)

    por_mail = defaultdict(lambda: {"nombre": "", "lotes": set(), "repos": set()})
    diagnostico = []

    for json_path in lotes:
        numero = json_path.stem.replace("lote-", "")
        txt_path = json_path.with_suffix(".txt")
        repos_path = carpeta / f"lote-{numero}.repos.txt"

        repos = []
        if repos_path.exists():
            repos = [r.strip() for r in repos_path.read_text().splitlines() if r.strip()]

        hallados, origen = leer_lote(json_path, txt_path)

        unicos = set()
        for mail, nombre in hallados:
            mail_low = mail.lower()
            unicos.add(mail_low)
            reg = por_mail[mail_low]
            if nombre and not reg["nombre"]:
                reg["nombre"] = nombre
            reg["lotes"].add(numero)
            reg["repos"].update(repos)

        diagnostico.append({
            "lote": numero,
            "repos": len(repos),
            "mails": len(unicos),
            "origen": origen,
        })
        print(f"  lote {numero}: {len(repos):>4} repos, {len(unicos):>4} mails  [{origen}]")

    total = len(por_mail)
    sin_datos = [d for d in diagnostico if d["origen"] == "SIN DATOS"]

    wb = Workbook()

    # ---- Resumen ----
    hoja = wb.active
    hoja.title = "Resumen"
    hoja["A1"] = "CALCULO DE CONTRIBUYENTES - CHECKMARX ONE"
    hoja["A1"].font = Font(bold=True, size=14)
    hoja["A3"] = "Organizacion / carpeta"
    hoja["B3"] = carpeta.name
    hoja["A4"] = "Lotes procesados"
    hoja["B4"] = len(lotes)
    hoja["A5"] = "Repositorios consultados"
    hoja["B5"] = sum(d["repos"] for d in diagnostico)
    hoja["A7"] = "TOTAL DE CONTRIBUYENTES UNICOS"
    hoja["A7"].font = Font(bold=True, size=12)
    hoja["B7"] = total
    hoja["B7"].font = Font(bold=True, size=12)
    hoja["B7"].fill = NARANJA
    for fila in range(3, 6):
        hoja[f"A{fila}"].font = NEGRITA

    hoja["A9"] = "COMO SE CALCULO"
    hoja["A9"].font = NEGRITA
    notas = [
        "El total es la cantidad de mails unicos entre TODOS los lotes.",
        "No es la suma de los totales de cada lote: eso contaria dos veces a",
        "quien commitea en repositorios de lotes distintos.",
        "",
        "El identificador es el mail del commit. La misma persona con dos mails",
        "configurados cuenta como dos. Revisar la hoja Usuarios antes de dar el",
        "numero por bueno.",
        "",
        "Ventana: ultimos 90 dias. Fija, no configurable.",
        "Dependabot no se cuenta; otros bots pueden estar sumando.",
        "",
        "ALCANCE: cubre solo los repositorios de la lista consultada.",
    ]
    for i, texto in enumerate(notas, start=10):
        hoja[f"A{i}"] = texto

    if sin_datos:
        fila = 10 + len(notas) + 1
        hoja[f"A{fila}"] = f"ATENCION: {len(sin_datos)} lote(s) sin datos. El total esta INCOMPLETO."
        hoja[f"A{fila}"].font = Font(bold=True, color="C00000")
        hoja[f"A{fila+1}"] = "Lotes: " + ", ".join(d["lote"] for d in sin_datos)

    ancho(hoja)

    # ---- Usuarios ----
    hoja = wb.create_sheet("Usuarios")
    encabezados = ["#", "Mail del commit", "Nombre", "Lotes", "Repos del lote"]
    hoja.append(encabezados)
    for celda in hoja[1]:
        celda.fill = AZUL
        celda.font = BLANCO_NEGRITA
        celda.alignment = Alignment(horizontal="center")

    for i, (mail, reg) in enumerate(sorted(por_mail.items()), start=1):
        hoja.append([
            i,
            mail,
            reg["nombre"],
            ", ".join(sorted(reg["lotes"])),
            len(reg["repos"]),
        ])
    hoja.freeze_panes = "A2"
    ancho(hoja)

    # ---- Posibles duplicados ----
    hoja = wb.create_sheet("Posibles duplicados")
    hoja.append(["Criterio", "Valor", "Mails que coinciden"])
    for celda in hoja[1]:
        celda.fill = AZUL
        celda.font = BLANCO_NEGRITA

    por_usuario = defaultdict(list)
    por_nombre = defaultdict(list)
    for mail, reg in por_mail.items():
        por_usuario[mail.split("@")[0].lower()].append(mail)
        if reg["nombre"]:
            por_nombre[reg["nombre"].lower()].append(mail)

    hubo = False
    for usuario, mails in sorted(por_usuario.items()):
        if len(mails) > 1:
            hoja.append(["Mismo usuario, distinto dominio", usuario, ", ".join(sorted(mails))])
            hubo = True
    for nombre, mails in sorted(por_nombre.items()):
        if len(set(mails)) > 1:
            hoja.append(["Mismo nombre, distinto mail", nombre, ", ".join(sorted(set(mails)))])
            hubo = True

    if not hubo:
        hoja.append(["Sin coincidencias", "", "Ningun candidato automatico a duplicado"])

    hoja.append([])
    hoja.append(["Estos son CANDIDATOS, no duplicados confirmados."])
    hoja.append(["Cada uno resta 1 al total si se confirma que es la misma persona."])
    ancho(hoja)

    # ---- Diagnostico ----
    hoja = wb.create_sheet("Diagnostico")
    hoja.append(["Lote", "Repos", "Mails encontrados", "De donde se leyo"])
    for celda in hoja[1]:
        celda.fill = GRIS
        celda.font = NEGRITA
    for d in diagnostico:
        hoja.append([d["lote"], d["repos"], d["mails"], d["origen"]])
    ancho(hoja)

    wb.save(salida)

    print()
    print("=" * 63)
    print(f" TOTAL DE CONTRIBUYENTES UNICOS: {total}")
    print("=" * 63)
    print(f" Excel: {salida}")
    if sin_datos:
        print()
        print(f" ATENCION: {len(sin_datos)} lote(s) sin datos, el total esta INCOMPLETO.")
        print(" Lotes: " + ", ".join(d["lote"] for d in sin_datos))
    print()


if __name__ == "__main__":
    main()
