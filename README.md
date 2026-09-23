# Mundial 2026: Impacto de las Pausas de Hidratación
### Dashboard de analítica deportiva — FIFA World Cup 2026

**Stack:** Python (ETL) → SQL Server (Data Warehouse, esquema estrella) → Power BI

Proyecto de portafolio que analiza si las pausas de hidratación obligatorias del reglamento del Mundial 2026 tienen un impacto medible en la dinámica de los partidos: intensidad de juego, generación de goles, y variación por fase/estadio/clima.

---

## El pipeline completo

```
SofaScore API  →  Python (extracción + parseo)  →  SQL Server (Data Warehouse)  →  Power BI
```

### 1. Extracción — `sofascore_loop.py`
Scraper en dos pasos con Playwright:
1. Recorre el calendario de la temporada del Mundial 2026 en SofaScore y obtiene el listado completo de los 104 partidos (`_partidos_lista.json`), incluyendo ronda, venue, marcador y equipos.
2. Para cada partido jugado, descarga y parsea 3 endpoints: `incidents` (goles, tarjetas, sustituciones), `comments` (eventos minuto a minuto, incluida la detección de pausas de hidratación por el patrón `startDelay`/`endDelay` con "drinks" en el texto) y `statistics` (posesión, tiros, etc.).

Es reanudable: si se interrumpe, retoma desde el último partido procesado usando un índice de checkpoint.

### 2. Data Warehouse — `00_REBUILD_SCHEMA.sql` + `01_REBUILD_ETL.py`
Modelo dimensional en estrella sobre SQL Server:

**Dimensiones:** `DimEquipo`, `DimEstadio`, `DimFase`, `DimTiempo`, `DimPartido`
**Hechos (nivel evento):** `FactIncidents`, `FactComments`, `FactPausasHidratacion`, `FactStatistics`
**Hechos derivados (calculados vía stored procedures):** `FactMomentum` (intensidad por bloques de 5 min), `FactPausaMetricas` (comparación pre/post pausa, ventana de 10 min), `FactGolPostPausa` (relación pausa→gol en ventanas de 5/10/15 min)
**Resumen para BI:** `ResumenPartido`, `ResumenTorneo`

El ETL es **idempotente**: cada corrida hace `DELETE` + reseed de identity + re-carga completa, nunca acumula datos duplicados en corridas repetidas. Incluye un procedimiento de validación (`sp_ValidarDW`) que revisa duplicados por clave natural, FKs huérfanas, y cruza el conteo de goles derivado de eventos contra el marcador oficial como control de calidad.

**Métrica central del proyecto** — índice de intensidad ponderado, usado tanto en `FactMomentum` como en `FactPausaMetricas`:
```
intensidad = (tiros × 2.0) + (corners × 1.0) + (faltas × 0.5)
```

### 3. Enriquecimiento — `actualizar_banderas_estadios_v2.py`
Poblado de banderas de los 48 equipos y fotos de los 16 estadios como URLs, para el storytelling visual del dashboard.

### 4. Presentación — Power BI
Dashboard de 6 páginas visibles: una landing con video introductorio e índice de navegación, y 5 páginas analíticas (Portada ejecutiva, Pausas de Hidratación, Momentum del Partido, Gol Post Pausa, Ficha de Partido).

Incluye además una **7ma página oculta de validación de datos** (Fase y Estadio), no expuesta en la navegación del usuario final: se usó para confirmar que la duración y frecuencia de la pausa de hidratación están estandarizadas por el reglamento (sin variación relevante por fase del torneo ni por clima del estadio), y se conservó como control de calidad interno en vez de como hallazgo de storytelling, ya que no aportaba una conclusión nueva para el usuario.

---

## Hallazgos principales

- **El efecto de la pausa no es uniforme**: a nivel agregado del torneo la intensidad de juego aumenta después de la pausa (+21% en faltas), pero en los dos partidos de mayor presión (la Final y el partido por el Tercer Puesto) el patrón se invierte — el equipo dominante pierde ritmo tras la pausa.
- **El exceso de probabilidad de gol atribuible a la pausa se concentra en los primeros 5 minutos** tras la reanudación (19.23% observado vs 15.41% esperado por azar); en ventanas de 10 y 15 minutos el efecto se diluye por debajo de la línea base.
- **La duración y frecuencia de la pausa están estandarizadas por el reglamento**, sin variación relevante por fase del torneo ni por clima del estadio (verificado en la página de validación interna) — confirma consistencia operativa del protocolo, no un factor de juego.

## Lecciones técnicas del proyecto

- Distinguir fuente de verdad: los metadatos de partido (ronda, venue, marcador) solo son confiables desde el índice maestro (`_partidos_lista.json`); los JSON individuales por partido son fiables únicamente para eventos/comentarios/estadísticas.
- Usar el campo `display` de SofaScore para el marcador (reglamentario + prórroga), nunca `current` (que mezcla penales).
- Los `UPDATE` sin condición de ventana temporal en el JOIN pueden contaminar columnas de "bandera" completas en vez de marcar solo las filas relevantes — un bug real encontrado y corregido durante el desarrollo.
- Preferencia de diseño: cuando aparece un bug en una columna del ETL, evaluar primero si se puede resolver con una medida DAX que recalcule la lógica correcta contra las tablas base, antes de re-ejecutar el pipeline completo.
- El bloque de limpieza inicial de un script de rebuild debe eliminar **todo** el schema anterior, no una parte: `00_REBUILD_SCHEMA.sql` solo dropeaba 2 de 5 vistas obsoletas, lo que no falla en una base nueva pero sí deja vistas colgadas (con columnas rotas de un schema anterior) si se corre sobre una base que ya las tenía — corregido incorporando el `DROP VIEW` completo directo en el schema, en vez de depender de recordar correr un script de limpieza aparte.

---

## Estructura del repositorio

```
├── extraction/
│   └── sofascore_loop.py
├── data_warehouse/
│   ├── 00_REBUILD_SCHEMA.sql
│   └── 01_REBUILD_ETL.py
├── enrichment/
│   └── actualizar_banderas_estadios_v2.py
├── docs/
│   └── LEEME_REBUILD.md
└── powerbi/
    └── (archivo .pbix del dashboard)
```

### Nota sobre el historial del proyecto

Este repositorio contiene únicamente la versión **vigente y consolidada** del pipeline. Durante el desarrollo hubo una primera versión del schema y del loader que se fue parchando incrementalmente (correcciones de ronda, fase, estadio, nombres de equipo en español, idempotencia del ETL) hasta que se decidió reconstruir el Data Warehouse desde cero (`00_REBUILD_SCHEMA.sql` + `01_REBUILD_ETL.py`), que absorbe y corrige todos esos hallazgos de una sola vez. Esa cadena de parches no se incluye en el repo — el resumen de qué se encontró y por qué se resolvió con un rebuild completo, en vez de seguir parchando, está en `docs/LEEME_REBUILD.md`.

Quedan fuera del repositorio, por no ser parte del pipeline activo: exploración con una fuente de datos alterna (FBref), y los archivos JSON crudos generados por el scraper (`_indice.json`, `partidos_wc2026/`), que se consideran datos, no código.

## Autor

Jose — Analista de datos independiente, Quito, Ecuador. Proyectos de Business Intelligence y Data Science: ingeniería de datos en Python, modelado dimensional en SQL Server, machine learning, y visualización en Power BI/React.
