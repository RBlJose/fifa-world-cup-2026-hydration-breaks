# Mundial 2026 — Data Warehouse

---

## Cómo correrlo

1. `sqlcmd -S localhost -i 00_REBUILD_SCHEMA.sql` (o ejecútalo en SSMS — dropea y recrea **todo** el esquema desde cero).
2. Coloca `01_REBUILD_ETL.py` en la carpeta donde tengas `_partidos_lista.json` y la carpeta `partidos_wc2026/` con los JSON individuales (o edita `PARTIDOS_LISTA_PATH` / `JSON_DIR` al inicio del script).
3. `pip install pyodbc` → `python 01_REBUILD_ETL.py`

Eso es todo. El script ya ejecuta `sp_ActualizarTodo` y `sp_ValidarDW` al final e imprime el resumen de validación. No hace falta correr nada más a mano.

Si necesitas recargar datos después (partidos nuevos, corregiste un JSON): vuelve a correr `01_REBUILD_ETL.py` completo. Trunca todo y recarga desde cero — nunca acumula, nunca duplica. No hay "fix03.sql" que corra después de esto.

---

## Causas raíz reales encontradas (verificadas contra los datos, no supuestas)

| Síntoma | Causa raíz real |
|---|---|
| Goles ≈ 1.8M / promedio ≈ 17.000 | `sp_PoblarResumenPartido` hacía `LEFT JOIN` de `FactIncidents` × `FactComments` × `FactPausasHidratacion` × `FactGolPostPausa`, las 4 unidas solo por `event_id` en la misma consulta sin agregar antes. Fan-out cartesiano clásico: 1 partido × 16 incidentes × 90 comentarios × 2 pausas se contaba como miles de filas antes del `SUM`. |
| Pausas = 621 (esperado ~208) | `cargar_json_sqlserver.py` solo tenía guardia `IF NOT EXISTS` para `DimPartido`. `FactIncidents`, `FactComments`, `FactPausasHidratacion` y `FactStatistics` se insertaban sin ningún chequeo de duplicado — cada re-corrida del loader (por versiones viejas/nuevas del scraper) volvía a insertar todo. 208 × 3 ≈ 624, calza con los 621 que se tenían. |
| Marcadores tipo "3-4" en partidos de penales | El pipeline usaba (o hubiera usado) el campo `current` de SofaScore, que es `display + penalties`. El campo correcto ya existe en la fuente: `display` = reglamentario + prórroga, sin penales. Verificado con Netherlands vs Morocco: `display=1`, `penalties=3`, `current=4` — el bug exacto que se sospechaba. |
| `DimEstadio` con nombres mal escritos ("Levi's Stadium") | Nombres tipeados a mano en vez de tomados del `venue` real de cada partido. |
| Nuevo hallazgo, nadie lo había visto: un estadio de más y uno de menos | `DimEstadio` tenía "Stade Olympique" (Montreal) — nunca se usa en ningún partido real — y le faltaba "Mercedes-Benz Stadium" (Atlanta), que sí se usa. Un partido que nunca iba a poder resolver `estadio_id`. |
| `DimFase` con rondas inventadas (4,5,6,7,8) | Las rondas reales de knockout que manda `roundInfo.round` son 5, 6, 27, 28, 29, 50 (no secuenciales). Verificado contra los 104 partidos reales. |
| home/away de comentarios siempre en 0 | `LIKE '%home%'` / `LIKE '%Mexico%'` hardcodeado. Se corrigió comparando contra el nombre real del equipo del partido — se mantiene esa lógica (ya estaba bien resuelta) pero ahora vive en el schema definitivo, no en un fix aparte. |
| `00_REBUILD_SCHEMA.sql` solo dropeaba 2 de 5 vistas obsoletas | El bloque de limpieza inicial no listaba `vw_KPIsTorneo`, `vw_MomentumPartido` ni `vw_PartidoConBanderas`. No falla al correr sobre una base nueva, pero sí deja vistas colgadas (apuntando a columnas de un schema anterior) al correr sobre una base que ya las tenía — corregido incluyendo el `DROP VIEW IF EXISTS` completo de las 5 vistas directo en el schema. |

---

## Fuente de verdad

| Métrica | Fuente | Granularidad |
|---|---|---|
| Partidos | `_partidos_lista.json` | 1 fila = 1 partido |
| Goles del partido | `DimPartido.goles_home/away` (= `event_raw.homeScore.display`) | 1 partido = suma oficial |
| Goles por evento (quién, minuto, asistencia) | `FactIncidents WHERE type='goal'` | 1 gol (métrica de cruce/control contra la oficial, no la fuente de verdad) |
| Penales de tanda | `DimPartido.penales_home/away` (= `event_raw.homeScore.penalties`) | 1 tanda |
| Pausas de hidratación | `FactPausasHidratacion` | 1 pausa |
| Tarjetas / sustituciones | `FactIncidents` | 1 evento |
| Comentarios | `FactComments` | 1 comentario |

## Granularidad de cada tabla

| Tabla | 1 fila = | Clave natural |
|---|---|---|
| `DimEquipo` | 1 selección nacional | `sofascore_id` |
| `DimEstadio` | 1 estadio | `sofascore_id` (`venue.id`) |
| `DimFase` | 1 fase del torneo | `ronda` |
| `DimPartido` | 1 partido | `event_id` |
| `FactIncidents` | 1 incidente real (gol/tarjeta/sustitución/periodo) | (`event_id`, `orden`) |
| `FactComments` | 1 comentario real minuto a minuto | (`event_id`, `orden`) |
| `FactPausasHidratacion` | 1 pausa de hidratación real | (`event_id`, `orden`) |
| `FactPausaMetricas` / `FactGolPostPausa` | 1 pausa (con sus métricas) | `pausa_id` |
| `FactMomentum` | 1 ventana de 5 min de 1 partido | (`event_id`, `period`, `ventana_inicio`) |
| `ResumenPartido` | 1 partido | `event_id` |
| `ResumenTorneo` | 1 fila (todo el torneo) | — |

### Por qué no se crearon tablas separadas (`HechoGol` / `HechoTarjeta` / `HechoSustitucion`)

`FactIncidents` ya tiene granularidad correcta (1 fila = 1 evento real) y una columna discriminadora `type`. Partirla no arregla nada — el problema nunca fue la tabla, era que los stored procedures la unían mal con otras tablas de hechos. Ese es el fix real y ya está aplicado en los procedimientos de `00_REBUILD_SCHEMA.sql`.

---

## Regla del marcador

- `goles_home` / `goles_away` = tiempo reglamentario + prórroga (`display`)
- `penales_home` / `penales_away` = solo la tanda (`NULL` si no hubo, nunca `0` falso)
- `ganador_equipo_id` = `event_raw.winnerCode` (1=local, 2=visitante, 3=empate; ya viene calculado correctamente por SofaScore incluso cuando el ganador se define por penales)

Verificado contra los 4 partidos de penales del torneo (Germany-Paraguay, Netherlands-Morocco, Australia-Egypt, Switzerland-Colombia) y los 9 partidos con prórroga: 0 errores.

---

## Qué NO se tocó a propósito

- La heurística de `LIKE '%' + home_team + '%'` para separar local/visitante en `FactComments` (SofaScore no da `is_home` estructurado ahí). Ya estaba bien resuelta en los fixes anteriores; se mantiene tal cual dentro del schema definitivo.
- `FactStatistics` — funciona bien, no había bug ahí.

## Limitación conocida

`hora_utc` / `franja_utc` en `DimTiempo` están en UTC, no en hora local del estadio (SofaScore no manda timezone del venue). El nombre se corrigió de "hora_local" a "hora_utc" para no dar una falsa sensación de precisión — antes decía "local" y en realidad era UTC. Si la hipótesis de investigación sobre calor/hidratación necesita hora local real, hace falta un mapeo estadio → timezone que no existe todavía en ningún archivo del proyecto.
