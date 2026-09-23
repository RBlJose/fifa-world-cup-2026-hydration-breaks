"""
Agrega bandera_url a DimEquipo e imagen_url a DimEstadio.
Versión corregida para el schema definitivo (00_REBUILD_SCHEMA.sql):
  - DimEquipo ya no tiene columna "nombre": ahora es "nombre_en".
  - No hace falta el INSERT de sincronización de equipos: DimEquipo
    ya se puebla completo desde 01_REBUILD_ETL.py, con sofascore_id
    real como clave. Este script solo AGREGA las columnas de URL,
    nunca inserta filas nuevas.
  - Se corrigió el estadio faltante: Mercedes-Benz Stadium (Atlanta)
    sí se usa en el torneo y no estaba en el diccionario viejo;
    "Stade Olympique" (Montreal) se quitó porque nunca se usa.

pip install pyodbc
"""

import pyodbc

SERVER   = "localhost"
DATABASE = "Mundial2026"
CONN_STR = (
    f"DRIVER={{ODBC Driver 17 for SQL Server}};"
    f"SERVER={SERVER};DATABASE={DATABASE};Trusted_Connection=yes;"
)

BANDERAS = {
    "Argentina": "ar", "Australia": "au", "Austria": "at", "Belgium": "be",
    "Bosnia & Herzegovina": "ba", "Brazil": "br", "Cabo Verde": "cv", "Canada": "ca",
    "Colombia": "co", "Croatia": "hr", "Czechia": "cz", "Côte d'Ivoire": "ci",
    "DR Congo": "cd", "Ecuador": "ec", "Egypt": "eg", "England": "gb-eng",
    "France": "fr", "Germany": "de", "Ghana": "gh", "Haiti": "ht", "Iran": "ir",
    "Iraq": "iq", "Japan": "jp", "Jordan": "jo", "Mexico": "mx", "Morocco": "ma",
    "Netherlands": "nl", "New Zealand": "nz", "Norway": "no", "Panama": "pa",
    "Paraguay": "py", "Portugal": "pt", "Qatar": "qa", "Saudi Arabia": "sa",
    "Scotland": "gb-sct", "Senegal": "sn", "South Africa": "za", "South Korea": "kr",
    "Spain": "es", "Sweden": "se", "Switzerland": "ch", "Tunisia": "tn",
    "Türkiye": "tr", "Uruguay": "uy", "USA": "us", "Uzbekistan": "uz",
    "Algeria": "dz", "Curaçao": "cw",
}
FLAG_BASE = "https://flagcdn.com/w320/{codigo}.png"

ESTADIOS_IMG = {
    "SoFi Stadium": "https://upload.wikimedia.org/wikipedia/commons/b/bd/SoFi_Stadium_%2851126606022%29.jpg",
    "MetLife Stadium": "https://upload.wikimedia.org/wikipedia/commons/4/46/New_Meadowlands_Stadium_Mezz_Corner.jpg",
    "AT&T Stadium": "https://upload.wikimedia.org/wikipedia/commons/5/52/Cowboys_Stadium_full_view.jpg",
    "NRG Stadium": "https://upload.wikimedia.org/wikipedia/commons/6/6a/Reliantstadium.jpg",
    "Levi's Stadium": "https://upload.wikimedia.org/wikipedia/commons/3/39/Panoramic_view_of_Levi%27s_Stadium.jpg",
    "Arrowhead Stadium": "https://upload.wikimedia.org/wikipedia/commons/8/8e/Arrowhead_Stadium_%28October_27%2C_2019_-_2%29.jpg",
    "Hard Rock Stadium": "https://upload.wikimedia.org/wikipedia/commons/8/8b/Dolphin_Stadium_baseball_diamond.jpg",
    "Lincoln Financial Field": "https://upload.wikimedia.org/wikipedia/commons/0/03/Lincoln_Financial_Field%2C_Philadelphia%2C_2024.jpg",
    "Gillette Stadium": "https://upload.wikimedia.org/wikipedia/commons/c/ce/Gillette_Stadium%2C_Chicago_Fire_vs._New_England_Revolution_2003.jpg",
    "Lumen Field": "https://upload.wikimedia.org/wikipedia/commons/f/f9/Quest_Field_July_2005.jpg",
    "Estadio Azteca": "https://upload.wikimedia.org/wikipedia/commons/6/6f/Estadio_Azteca_desde_el_aire_1.jpg",
    "Estadio BBVA": "https://upload.wikimedia.org/wikipedia/commons/0/0e/Mexico_Guadalupe_Monterrey_Estadio_BBVA_Bancomer_fifa_world_cup_2026_1.JPG",
    "Estadio Akron": "https://upload.wikimedia.org/wikipedia/commons/1/1e/Volcano_stadium.png",
    "BC Place": "https://upload.wikimedia.org/wikipedia/commons/a/a7/BC_Place_%28Vancouver%29.jpg",
    "BMO Field": "https://upload.wikimedia.org/wikipedia/commons/2/29/BMO_Field_Closeups_04.jpg",
    # NUEVO: faltaba en el diccionario original, sí se usa en el torneo real.
    "Mercedes-Benz Stadium": "https://upload.wikimedia.org/wikipedia/commons/b/b3/Peach_Bowl_Pre-game_%2838723784494%29_%28cropped%29.jpg",
    # QUITADO: "Stade Olympique" (Montreal) — nunca se usa en ningún partido real,
    # no existe en DimEstadio del schema nuevo (que se carga solo con venues reales).
}


def main():
    conn = pyodbc.connect(CONN_STR)
    cursor = conn.cursor()
    print(f"Conectado a {SERVER}/{DATABASE}\n")

    # --- DimEquipo: agregar columna bandera_url si no existe ---
    cursor.execute("""
        IF NOT EXISTS (
            SELECT * FROM sys.columns
            WHERE object_id = OBJECT_ID('DimEquipo') AND name = 'bandera_url'
        )
        ALTER TABLE DimEquipo ADD bandera_url NVARCHAR(300);
    """)
    conn.commit()

    sin_mapeo_equipo = []
    cursor.execute("SELECT equipo_id, nombre_en FROM DimEquipo")
    for equipo_id, nombre_en in cursor.fetchall():
        codigo = BANDERAS.get(nombre_en)
        if codigo:
            cursor.execute(
                "UPDATE DimEquipo SET bandera_url = ? WHERE equipo_id = ?",
                FLAG_BASE.format(codigo=codigo), equipo_id,
            )
        else:
            sin_mapeo_equipo.append(nombre_en)
    conn.commit()
    print("Banderas actualizadas en DimEquipo")
    if sin_mapeo_equipo:
        print(f"  AVISO: equipos sin código de bandera (agrégalos a BANDERAS): {sin_mapeo_equipo}")

    # --- DimEstadio: agregar columna imagen_url si no existe ---
    cursor.execute("""
        IF NOT EXISTS (
            SELECT * FROM sys.columns
            WHERE object_id = OBJECT_ID('DimEstadio') AND name = 'imagen_url'
        )
        ALTER TABLE DimEstadio ADD imagen_url NVARCHAR(500);
    """)
    conn.commit()

    sin_mapeo_estadio = []
    cursor.execute("SELECT estadio_id, nombre FROM DimEstadio")
    ok = 0
    for estadio_id, nombre in cursor.fetchall():
        url = ESTADIOS_IMG.get(nombre)
        if url:
            cursor.execute(
                "UPDATE DimEstadio SET imagen_url = ? WHERE estadio_id = ?",
                url, estadio_id,
            )
            ok += 1
        else:
            sin_mapeo_estadio.append(nombre)
    conn.commit()
    print(f"Imágenes actualizadas en DimEstadio: {ok}/16")
    if sin_mapeo_estadio:
        print(f"  AVISO: estadios sin imagen (agrégalos a ESTADIOS_IMG): {sin_mapeo_estadio}")

    cursor.close()
    conn.close()
    print("\nListo.")


if __name__ == "__main__":
    main()