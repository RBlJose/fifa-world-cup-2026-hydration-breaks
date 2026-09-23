"""
================================================================
MUNDIAL 2026 — ETL DE RECONSTRUCCIÓN DEFINITIVA
================================================================
Reemplaza cargar_json_sqlserver.py y todos los fixes sueltos
(fix_ronda.py, poblar_venue_y_estadio.py, agregar_equipos_es_en.py,
insertar_partido_parche.py, fix_rondas_desde_json.py).

QUÉ HACE, EN ORDEN:
  1. Corre 00_REBUILD_SCHEMA.sql si aún no lo corriste (o pídelo).
  2. TRUNCA todas las tablas (menos DimFase, que ya viene preseedeada
     en el schema) — esto es lo que garantiza IDEMPOTENCIA. No
     importa cuántas veces corras este script: nunca acumula.
  3. Carga DimEquipo y DimEstadio directamente desde _partidos_lista.json
     (id real de SofaScore como clave natural, no nombre a mano).
  4. Carga DimTiempo desde los start_timestamp reales.
  5. Carga DimPartido con el marcador correcto (goles vs penales
     separados, prórroga incluida en el marcador, penales NO).
  6. Carga FactIncidents / FactComments / FactPausasHidratacion /
     FactStatistics desde los JSON individuales por partido, con
     clave natural (event_id, orden) — sin duplicados posibles.
  7. Ejecuta EXEC sp_ActualizarTodo y EXEC sp_ValidarDW al final.

FUENTE DE VERDAD (no mezclar):
  - _partidos_lista.json  -> equipos, estadios, rondas/fase, marcador,
                              fecha. Es el único archivo con 104
                              registros verificados sin duplicados y
                              con event_raw completo.
  - carpeta de partidos individuales (un JSON por partido, generado
    por sofascore_loop.py) -> SOLO incidents / comments / pausas /
    statistics. Algunos de estos archivos vienen de una versión
    vieja del scraper y NO traen round/venue — por eso no se usan
    como fuente de esos campos.

pip install pyodbc
"""

import os
import re
import json
import glob
from datetime import datetime, timezone

import pyodbc

# ================================================================
# CONFIGURACIÓN
# ================================================================

SERVER   = "localhost"
DATABASE = "Mundial2026"
DRIVER   = "{ODBC Driver 17 for SQL Server}"

PARTIDOS_LISTA_PATH = r"C:\Users\josel\OneDrive\Escritorio\Proyectos\FIFA2026\partidos_wc2026\_partidos_lista.json"
JSON_DIR             = r"C:\Users\josel\OneDrive\Escritorio\Proyectos\FIFA2026\partidos_wc2026"

CONN_STRING = (
    f"DRIVER={DRIVER};SERVER={SERVER};DATABASE={DATABASE};Trusted_Connection=yes;"
)

# Diccionario ES manual — SofaScore solo trae traducción a ar/bn/hi/ru,
# no a español, así que esto es indispensable y se mantiene a mano
# (igual que en agregar_equipos_es_en.py, que este script reemplaza).
TRADUCCIONES_ES = {
    "Argentina": "Argentina", "Australia": "Australia", "Austria": "Austria",
    "Belgium": "Bélgica", "Bosnia & Herzegovina": "Bosnia y Herzegovina",
    "Brazil": "Brasil", "Cabo Verde": "Cabo Verde", "Canada": "Canadá",
    "Colombia": "Colombia", "Croatia": "Croacia", "Czechia": "Chequia",
    "Côte d'Ivoire": "Costa de Marfil", "DR Congo": "RD Congo",
    "Ecuador": "Ecuador", "Egypt": "Egipto", "England": "Inglaterra",
    "France": "Francia", "Germany": "Alemania", "Ghana": "Ghana",
    "Haiti": "Haití", "Iran": "Irán", "Iraq": "Irak", "Japan": "Japón",
    "Jordan": "Jordania", "Mexico": "México", "Morocco": "Marruecos",
    "Netherlands": "Países Bajos", "New Zealand": "Nueva Zelanda",
    "Norway": "Noruega", "Panama": "Panamá", "Paraguay": "Paraguay",
    "Portugal": "Portugal", "Qatar": "Catar", "Saudi Arabia": "Arabia Saudita",
    "Scotland": "Escocia", "Senegal": "Senegal", "South Africa": "Sudáfrica",
    "South Korea": "Corea del Sur", "Spain": "España", "Sweden": "Suecia",
    "Switzerland": "Suiza", "Tunisia": "Túnez", "Türkiye": "Turquía",
    "Uruguay": "Uruguay", "USA": "Estados Unidos", "Uzbekistan": "Uzbekistán",
    "Algeria": "Argelia", "Curaçao": "Curazao",
}


# ================================================================
# HELPERS DE LECTURA DE JSON
# ================================================================

def cargar_partidos_lista():
    with open(PARTIDOS_LISTA_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def indexar_jsons_individuales():
    """Mapea event_id -> ruta del JSON individual del partido.
    Usa el contenido (event_id) como fuente de verdad, no el nombre
    del archivo, por si el nombre tiene equipos con caracteres raros."""
    archivos = [
        f for f in glob.glob(os.path.join(JSON_DIR, "*.json"))
        if not os.path.basename(f).startswith("_")
    ]
    mapa = {}
    for path in archivos:
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
            eid = data.get("event_id")
            if eid:
                mapa[eid] = data
        except Exception as e:
            print(f"  AVISO: no se pudo leer {path}: {e}")
    return mapa


# ================================================================
# EXTRACCIÓN DE MARCADOR (regla definitiva goles vs penales)
# ================================================================

def extraer_marcador(event_raw):
    hs = event_raw.get("homeScore", {}) or {}
    aws = event_raw.get("awayScore", {}) or {}

    hubo_prorroga = ("extra1" in hs) or ("extra1" in aws)
    fue_a_penales = ("penalties" in hs) or ("penalties" in aws)

    return {
        # goles_home/away = "display": reglamentario + prórroga, SIN penales.
        # Es el campo que SofaScore ya calcula bien; "current" es el que
        # se contamina sumando penales (current = display + penalties).
        "goles_home": hs.get("display", hs.get("normaltime", 0)),
        "goles_away": aws.get("display", aws.get("normaltime", 0)),
        "goles_home_reglamentario": hs.get("normaltime", hs.get("period1", 0) + hs.get("period2", 0)),
        "goles_away_reglamentario": aws.get("normaltime", aws.get("period1", 0) + aws.get("period2", 0)),
        "goles_home_prorroga": hs.get("overtime", 0) or 0,
        "goles_away_prorroga": aws.get("overtime", 0) or 0,
        "hubo_prorroga": hubo_prorroga,
        "fue_a_penales": fue_a_penales,
        "penales_home": hs.get("penalties") if fue_a_penales else None,
        "penales_away": aws.get("penalties") if fue_a_penales else None,
    }


def extraer_resultado(event_raw, home_equipo_id, away_equipo_id):
    winner_code = event_raw.get("winnerCode")
    if winner_code == 1:
        return home_equipo_id, "local"
    if winner_code == 2:
        return away_equipo_id, "visitante"
    return None, "empate"


# ================================================================
# CARGA DE DIMENSIONES (directo desde _partidos_lista.json)
# ================================================================

def poblar_equipos(cursor, partidos):
    equipos = {}   # sofascore_id -> {nombre_en, pais_alpha3, ranking}
    for m in partidos:
        for lado in ("homeTeam", "awayTeam"):
            t = m["event_raw"].get(lado)
            if not t:
                continue
            equipos[t["id"]] = {
                "nombre_en": t.get("name"),
                "pais_alpha3": (t.get("country") or {}).get("alpha3"),
                "ranking": t.get("ranking"),
            }

    sin_traduccion = []
    for sofascore_id, info in equipos.items():
        nombre_es = TRADUCCIONES_ES.get(info["nombre_en"])
        if nombre_es is None:
            sin_traduccion.append(info["nombre_en"])
        cursor.execute(
            """
            INSERT INTO DimEquipo (sofascore_id, nombre_en, nombre_es, pais_alpha3, ranking_fifa)
            VALUES (?, ?, ?, ?, ?)
            """,
            sofascore_id, info["nombre_en"], nombre_es, info["pais_alpha3"], info["ranking"],
        )

    if sin_traduccion:
        print(f"  AVISO: equipos sin traducción ES (agrégalos a TRADUCCIONES_ES): {sorted(set(sin_traduccion))}")

    cursor.execute("SELECT sofascore_id, equipo_id, nombre_en FROM DimEquipo")
    return {row.sofascore_id: row.equipo_id for row in cursor.fetchall()}


def poblar_estadios(cursor, partidos):
    venues = {}   # sofascore_id -> datos
    for m in partidos:
        v = m["event_raw"].get("venue")
        if not v:
            continue
        coords = v.get("venueCoordinates", {}) or {}
        venues[v["id"]] = {
            "nombre": v.get("name"),
            "ciudad": (v.get("city") or {}).get("name"),
            "pais": (v.get("country") or {}).get("name"),
            "capacidad": v.get("capacity"),
            "latitud": coords.get("latitude"),
            "longitud": coords.get("longitude"),
        }

    for sofascore_id, info in venues.items():
        cursor.execute(
            """
            INSERT INTO DimEstadio (sofascore_id, nombre, ciudad, pais, capacidad, latitud, longitud)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            sofascore_id, info["nombre"], info["ciudad"], info["pais"],
            info["capacidad"], info["latitud"], info["longitud"],
        )

    cursor.execute("SELECT sofascore_id, estadio_id FROM DimEstadio")
    return {row.sofascore_id: row.estadio_id for row in cursor.fetchall()}


def poblar_tiempo(cursor, partidos):
    timestamps = sorted({m["event_raw"]["startTimestamp"] for m in partidos if m["event_raw"].get("startTimestamp")})
    for ts in timestamps:
        dt = datetime.fromtimestamp(ts, tz=timezone.utc)
        hora = dt.hour
        franja = "Mañana" if hora < 12 else "Tarde" if hora < 19 else "Noche"
        cursor.execute(
            """
            INSERT INTO DimTiempo (unix_timestamp, fecha, hora_utc, anio, mes, dia,
                dia_semana, hora_utc_num, es_nocturno_utc, franja_utc)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            ts, dt.date(), dt.time(), dt.year, dt.month, dt.day,
            dt.strftime("%A"), hora, 1 if hora >= 19 else 0, franja,
        )
    cursor.execute("SELECT unix_timestamp, tiempo_id FROM DimTiempo")
    return {row.unix_timestamp: row.tiempo_id for row in cursor.fetchall()}


def poblar_fase_map(cursor):
    cursor.execute("SELECT ronda, fase_id FROM DimFase")
    return {row.ronda: row.fase_id for row in cursor.fetchall()}


def poblar_partidos(cursor, partidos, equipo_map, estadio_map, tiempo_map, fase_map):
    for m in partidos:
        er = m["event_raw"]
        event_id = m["event_id"]

        home_sf_id = er["homeTeam"]["id"]
        away_sf_id = er["awayTeam"]["id"]
        home_equipo_id = equipo_map[home_sf_id]
        away_equipo_id = equipo_map[away_sf_id]

        venue_sf_id = er.get("venue", {}).get("id")
        estadio_id = estadio_map.get(venue_sf_id)

        ts = er.get("startTimestamp")
        tiempo_id = tiempo_map.get(ts)

        ronda = (er.get("roundInfo") or {}).get("round")
        fase_id = fase_map.get(ronda)
        jornada = ronda if ronda in (1, 2, 3) else None

        marcador = extraer_marcador(er)
        ganador_equipo_id, resultado = extraer_resultado(er, home_equipo_id, away_equipo_id)

        cursor.execute(
            """
            INSERT INTO DimPartido (
                event_id, slug, home_equipo_id, away_equipo_id, home_team, away_team,
                estadio_id, fase_id, tiempo_id, ronda, jornada, status, start_timestamp,
                goles_home, goles_away, goles_home_reglamentario, goles_away_reglamentario,
                goles_home_prorroga, goles_away_prorroga, hubo_prorroga, fue_a_penales,
                penales_home, penales_away, ganador_equipo_id, resultado, venue_nombre_raw
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            event_id, m.get("slug"), home_equipo_id, away_equipo_id,
            er["homeTeam"]["name"], er["awayTeam"]["name"],
            estadio_id, fase_id, tiempo_id, ronda, jornada,
            (er.get("status") or {}).get("description"), ts,
            marcador["goles_home"], marcador["goles_away"],
            marcador["goles_home_reglamentario"], marcador["goles_away_reglamentario"],
            marcador["goles_home_prorroga"], marcador["goles_away_prorroga"],
            1 if marcador["hubo_prorroga"] else 0, 1 if marcador["fue_a_penales"] else 0,
            marcador["penales_home"], marcador["penales_away"],
            ganador_equipo_id, resultado, er.get("venue", {}).get("name"),
        )


# ================================================================
# CARGA DE HECHOS (desde los JSON individuales por partido)
# ================================================================

def cargar_incidents(cursor, event_id, incidents):
    sql = """
    INSERT INTO FactIncidents (
        event_id, orden, minute, added, period, is_home, type, class,
        player, assist, goal_type, player_in, player_out,
        shot_x, shot_y, reason, var_class, home_score, away_score, length, text
    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    """
    for orden, inc in enumerate(incidents):
        cursor.execute(
            sql, event_id, orden,
            inc.get("minute"), inc.get("added", 0), inc.get("period"), inc.get("is_home"),
            inc.get("type"), inc.get("class"), inc.get("player"), inc.get("assist"),
            inc.get("goal_type"), inc.get("player_in"), inc.get("player_out"),
            inc.get("shot_x"), inc.get("shot_y"), inc.get("reason"), inc.get("var_class"),
            inc.get("home_score"), inc.get("away_score"), inc.get("length"), inc.get("text"),
        )


def cargar_comments(cursor, event_id, comments_data):
    sql = "INSERT INTO FactComments (event_id, orden, minute, period, type, text) VALUES (?,?,?,?,?,?)"
    for orden, c in enumerate(comments_data.get("todos_eventos", [])):
        cursor.execute(sql, event_id, orden, c.get("minute"), c.get("period"), c.get("type"), c.get("text"))


def cargar_pausas(cursor, event_id, comments_data):
    sql = """
    INSERT INTO FactPausasHidratacion (event_id, orden, period, start_minute, end_minute, duration)
    VALUES (?,?,?,?,?,?)
    """
    for orden, pausa in enumerate(comments_data.get("pausas_hidratacion", []), start=1):
        cursor.execute(
            sql, event_id, orden, pausa.get("period"),
            pausa.get("start_minute"), pausa.get("end_minute"), pausa.get("duration"),
        )


def cargar_statistics(cursor, event_id, statistics):
    sql = "INSERT INTO FactStatistics (event_id, period, stat_name, home_value, away_value) VALUES (?,?,?,?,?)"
    for period, stats in (statistics or {}).items():
        for stat_name, valores in stats.items():
            cursor.execute(sql, event_id, period, stat_name, str(valores.get("home", "")), str(valores.get("away", "")))


# ================================================================
# TRUNCADO IDEMPOTENTE (orden hijo -> padre, respeta FKs)
# ================================================================

TABLAS_A_TRUNCAR_EN_ORDEN = [
    "ResumenTorneo", "ResumenPartido", "FactGolPostPausa", "FactPausaMetricas",
    "FactMomentum", "FactStatistics", "FactPausasHidratacion", "FactComments",
    "FactIncidents", "DimPartido", "DimTiempo", "DimEstadio", "DimEquipo",
    # DimFase NO se trunca: viene preseedeada desde 00_REBUILD_SCHEMA.sql
]


# Tablas con columna IDENTITY (necesitan reseed manual tras el DELETE,
# ya que a diferencia de TRUNCATE, DELETE no reinicia el contador).
TABLAS_CON_IDENTITY = {
    "ResumenTorneo", "FactGolPostPausa", "FactPausaMetricas", "FactMomentum",
    "FactStatistics", "FactPausasHidratacion", "FactComments", "FactIncidents",
    "DimTiempo", "DimEstadio", "DimEquipo",
    # ResumenPartido y DimPartido NO llevan IDENTITY (su PK es event_id real)
}


def truncar_todo(cursor):
    # DELETE en vez de TRUNCATE: SQL Server no permite TRUNCATE sobre una
    # tabla referenciada por una FOREIGN KEY de OTRA tabla, aunque esa
    # tabla hija ya esté vacía y el orden sea el correcto (p. ej.
    # FactMomentum/FactPausaMetricas/FactGolPostPausa referencian
    # FactPausasHidratacion.id). DELETE respetando el mismo orden
    # hijo->padre no tiene esa restricción.
    for tabla in TABLAS_A_TRUNCAR_EN_ORDEN:
        cursor.execute(f"DELETE FROM {tabla}")
        if tabla in TABLAS_CON_IDENTITY:
            cursor.execute(f"DBCC CHECKIDENT ('{tabla}', RESEED, 0)")
    print(f"  {len(TABLAS_A_TRUNCAR_EN_ORDEN)} tablas vaciadas y contadores reseteados (rebuild limpio garantizado).")


# ================================================================
# MAIN
# ================================================================

def main():
    print("=== REBUILD MUNDIAL 2026 — inicio ===\n")

    partidos = cargar_partidos_lista()
    print(f"Partidos en {PARTIDOS_LISTA_PATH}: {len(partidos)}")

    jsons_individuales = indexar_jsons_individuales()
    print(f"JSON individuales encontrados en {JSON_DIR}/: {len(jsons_individuales)}")

    faltantes = [m["event_id"] for m in partidos if m["event_id"] not in jsons_individuales]
    if faltantes:
        print(f"  AVISO: {len(faltantes)} partidos sin JSON individual (sin incidents/comments/pausas): {faltantes}")

    conn = pyodbc.connect(CONN_STRING, autocommit=False)
    cursor = conn.cursor()
    cursor.fast_executemany = False  # los INSERT llevan tipos mixtos (NULL, texto largo)

    try:
        print("\n--- Truncando tablas (rebuild limpio) ---")
        truncar_todo(cursor)

        print("\n--- Cargando dimensiones desde _partidos_lista.json ---")
        equipo_map = poblar_equipos(cursor, partidos)
        print(f"  DimEquipo: {len(equipo_map)} equipos")
        estadio_map = poblar_estadios(cursor, partidos)
        print(f"  DimEstadio: {len(estadio_map)} estadios")
        tiempo_map = poblar_tiempo(cursor, partidos)
        print(f"  DimTiempo: {len(tiempo_map)} timestamps únicos")
        fase_map = poblar_fase_map(cursor)

        print("\n--- Cargando DimPartido (marcador correcto: goles != penales) ---")
        poblar_partidos(cursor, partidos, equipo_map, estadio_map, tiempo_map, fase_map)
        print(f"  DimPartido: {len(partidos)} partidos")

        print("\n--- Cargando hechos por partido (incidents/comments/pausas/statistics) ---")
        ok, sin_json = 0, 0
        for m in partidos:
            event_id = m["event_id"]
            data = jsons_individuales.get(event_id)
            if not data:
                sin_json += 1
                continue
            cargar_incidents(cursor, event_id, data.get("incidents", []))
            comments_data = data.get("comments", {})
            cargar_comments(cursor, event_id, comments_data)
            cargar_pausas(cursor, event_id, comments_data)
            cargar_statistics(cursor, event_id, data.get("statistics", {}))
            ok += 1

        print(f"  Partidos con hechos cargados: {ok}")
        if sin_json:
            print(f"  Partidos sin JSON individual (solo metadata, sin eventos): {sin_json}")

        conn.commit()
        print("\n--- COMMIT realizado ---")

        print("\n--- Ejecutando sp_ActualizarTodo ---")
        cursor.execute("EXEC sp_ActualizarTodo")
        conn.commit()

        print("\n--- Ejecutando sp_ValidarDW ---")
        cursor.execute("EXEC sp_ValidarDW")

        etiquetas_resultsets = ["RESUMEN", "PARTIDOS CON PENALES", "EQUIPOS SIN TRADUCCIÓN ES"]
        i = 0
        while True:
            titulo = etiquetas_resultsets[i] if i < len(etiquetas_resultsets) else f"RESULTSET {i+1}"
            try:
                columnas = [c[0] for c in cursor.description] if cursor.description else None
                filas = cursor.fetchall()
                print(f"\n[{titulo}]")
                if not filas:
                    print("  (sin filas)")
                elif columnas:
                    for fila in filas:
                        for col, val in zip(columnas, fila):
                            print(f"  {col}: {val}")
                        print("  ---")
            except pyodbc.ProgrammingError:
                pass
            i += 1
            if not cursor.nextset():
                break

    except Exception as e:
        conn.rollback()
        print(f"\nERROR — se hizo ROLLBACK completo, la base quedó como estaba antes de correr esto: {e}")
        raise
    finally:
        cursor.close()
        conn.close()

    print("\n=== REBUILD MUNDIAL 2026 — completado ===")


if __name__ == "__main__":
    main()