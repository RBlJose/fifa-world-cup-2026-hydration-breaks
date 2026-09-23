-- ================================================================
-- MUNDIAL 2026 — RECONSTRUCCIÓN DEFINITIVA DEL DATA WAREHOUSE
-- ================================================================
-- Reemplaza TODO lo anterior (crear_tablas_wc2026.sql,
-- mejoras_dw_mundial2026.sql y los fixes 01-06). No es un parche
-- más: es la versión definitiva. Corre este script sobre una base
-- vacía o sobre Mundial2026 (dropea y recrea todo).
--
-- ORDEN DE EJECUCIÓN DEL PROYECTO:
--   1. 00_REBUILD_SCHEMA.sql   (este archivo) — DDL + procedimientos
--   2. 01_REBUILD_ETL.py       — carga TODO desde cero (Python)
--   3. EXEC sp_ActualizarTodo  — lo dispara automáticamente el ETL,
--                                 pero puedes re-ejecutarlo manualmente
--   4. EXEC sp_ValidarDW       — validación de integridad y plausibilidad
--
-- Si necesitas recargar datos después (nuevos partidos, corrección
-- de un JSON), NO corras fixes sueltos: vuelve a correr
-- 01_REBUILD_ETL.py completo. Es idempotente por diseño: cada
-- corrida hace TRUNCATE + INSERT de todo, nunca acumula.
-- ================================================================

IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'Mundial2026')
BEGIN
    CREATE DATABASE Mundial2026;
END
GO

USE Mundial2026;
GO

-- ================================================================
-- BLOQUE 0: LIMPIEZA — dropear todo lo anterior en orden seguro
-- (vistas y SPs primero, luego tablas hijas, luego tablas padre)
-- ================================================================

DROP VIEW IF EXISTS vw_ComparacionPausa;
DROP VIEW IF EXISTS vw_EventosPorVentanaPausa;
DROP VIEW IF EXISTS vw_KPIsTorneo;
DROP VIEW IF EXISTS vw_MomentumPartido;
DROP VIEW IF EXISTS vw_PartidoConBanderas;
GO

DROP PROCEDURE IF EXISTS sp_ActualizarTodo;
DROP PROCEDURE IF EXISTS sp_PoblarMomentum;
DROP PROCEDURE IF EXISTS sp_PoblarPausaMetricas;
DROP PROCEDURE IF EXISTS sp_PoblarResumenPartido;
DROP PROCEDURE IF EXISTS sp_PoblarResumenTorneo;
DROP PROCEDURE IF EXISTS sp_ValidarDW;
GO

DROP TABLE IF EXISTS ResumenTorneo;
DROP TABLE IF EXISTS ResumenPartido;
DROP TABLE IF EXISTS FactGolPostPausa;
DROP TABLE IF EXISTS FactPausaMetricas;
DROP TABLE IF EXISTS FactMomentum;
DROP TABLE IF EXISTS FactStatistics;
DROP TABLE IF EXISTS FactPausasHidratacion;
DROP TABLE IF EXISTS FactComments;
DROP TABLE IF EXISTS FactIncidents;
DROP TABLE IF EXISTS DimPartido;
DROP TABLE IF EXISTS DimTiempo;
DROP TABLE IF EXISTS DimEstadio;
DROP TABLE IF EXISTS DimFase;
DROP TABLE IF EXISTS DimEquipo;
GO

PRINT 'Esquema anterior eliminado. Reconstruyendo desde cero...';
GO

-- ================================================================
-- BLOQUE 1: DIMENSIONES
-- ================================================================

-- DimEquipo: clave natural = sofascore_id (el id real que manda la
-- API), no el nombre. Antes se usaba el nombre como clave implícita,
-- lo que es frágil ante cualquier variación de texto.
CREATE TABLE DimEquipo (
    equipo_id     INT IDENTITY(1,1) PRIMARY KEY,
    sofascore_id  INT NOT NULL UNIQUE,
    nombre_en     NVARCHAR(100) NOT NULL,   -- tal cual lo manda SofaScore
    nombre_es     NVARCHAR(100) NULL,       -- diccionario manual (API no trae ES)
    pais_alpha3   CHAR(3) NULL,
    ranking_fifa  INT NULL,
    created_at    DATETIME DEFAULT GETDATE()
);
GO

-- DimEstadio: clave natural = sofascore_id (venue.id). Esto elimina
-- de raíz la clase de bug que tuvimos con "Levi's Stadium" /
-- "Lumen Field" mal escritos a mano: los datos vienen del venue
-- real de cada partido, no de una lista tipeada aparte.
CREATE TABLE DimEstadio (
    estadio_id       INT IDENTITY(1,1) PRIMARY KEY,
    sofascore_id     INT NOT NULL UNIQUE,
    nombre           NVARCHAR(150) NOT NULL,
    ciudad           NVARCHAR(100),
    pais             NVARCHAR(50),
    capacidad        INT,
    latitud          FLOAT,
    longitud         FLOAT,
    es_ciudad_calida BIT DEFAULT 0,   -- editable a mano post-carga si se quiere
    created_at       DATETIME DEFAULT GETDATE()
);
GO

-- DimFase: estructura REAL del torneo según SofaScore. Los IDs de
-- ronda de knockout NO son secuenciales (4,5,6,7,8) como se asumió
-- originalmente: son 5, 6, 27, 28, 29, 50. Se preseedea aquí mismo,
-- en el DDL, para que nunca vuelva a quedar vacía ni mal poblada
-- por un script aparte.
CREATE TABLE DimFase (
    fase_id          INT IDENTITY(1,1) PRIMARY KEY,
    ronda            INT NOT NULL UNIQUE,   -- roundInfo.round crudo de SofaScore
    nombre_fase      NVARCHAR(50) NOT NULL,
    es_eliminatoria  BIT NOT NULL,
    importancia      INT NOT NULL           -- orden lógico para reportes/ejes
);
GO

INSERT INTO DimFase (ronda, nombre_fase, es_eliminatoria, importancia) VALUES
    (1,  N'Fase de Grupos',      0, 1),
    (2,  N'Fase de Grupos',      0, 1),
    (3,  N'Fase de Grupos',      0, 1),
    (6,  N'Round of 32',         1, 2),
    (5,  N'Round of 16',         1, 3),
    (27, N'Quarterfinals',       1, 4),
    (28, N'Semifinals',          1, 5),
    (50, N'Match for 3rd place', 1, 6),
    (29, N'Final',               1, 7);
GO

-- DimTiempo: la puebla el ETL de Python a partir de los
-- start_timestamp reales (evita duplicar lógica de fechas en SQL
-- y en Python). hora_utc/franja_utc en vez de "local" porque
-- SofaScore no da timezone de estadio — nombrar el campo "local"
-- cuando en realidad es UTC fue una de las asunciones no validadas
-- que causaron confusión antes.
CREATE TABLE DimTiempo (
    tiempo_id        INT IDENTITY(1,1) PRIMARY KEY,
    unix_timestamp   BIGINT NOT NULL UNIQUE,
    fecha            DATE,
    hora_utc         TIME,
    anio             INT,
    mes              INT,
    dia              INT,
    dia_semana       NVARCHAR(20),
    hora_utc_num     INT,             -- 0-23
    es_nocturno_utc  BIT,
    franja_utc       NVARCHAR(20)     -- Mañana / Tarde / Noche (en UTC)
);
GO

-- DimPartido: 1 fila = 1 partido. Clave natural = event_id real de
-- SofaScore (ya lo era). Incluye el marcador correcto separando
-- reglamentario, prórroga y penales — regla definitiva del prompt
-- maestro (secciones 12-17): el resultado del partido NUNCA incluye
-- la tanda de penales.
CREATE TABLE DimPartido (
    event_id                   BIGINT PRIMARY KEY,   -- SofaScore event id
    slug                       NVARCHAR(200),
    home_equipo_id             INT NOT NULL REFERENCES DimEquipo(equipo_id),
    away_equipo_id             INT NOT NULL REFERENCES DimEquipo(equipo_id),
    home_team                  NVARCHAR(100) NOT NULL,  -- denormalizado (EN, igual a nombre_en)
    away_team                  NVARCHAR(100) NOT NULL,  -- usado por los SPs de matching texto->equipo
    estadio_id                 INT NULL REFERENCES DimEstadio(estadio_id),
    fase_id                    INT NULL REFERENCES DimFase(fase_id),
    tiempo_id                  INT NULL REFERENCES DimTiempo(tiempo_id),
    ronda                      INT,           -- roundInfo.round crudo (1,2,3,5,6,27,28,29,50)
    jornada                    INT NULL,      -- solo tiene sentido en fase de grupos (1,2,3)
    status                     NVARCHAR(50),
    start_timestamp            BIGINT,

    -- ---- MARCADOR (fuente de verdad = event_raw.homeScore/awayScore) ----
    goles_home                 INT NOT NULL,  -- = "display": reglamentario + prórroga, SIN penales
    goles_away                 INT NOT NULL,
    goles_home_reglamentario   INT,           -- = "normaltime" (90 min)
    goles_away_reglamentario   INT,
    goles_home_prorroga        INT DEFAULT 0, -- = "overtime" (0 si no hubo)
    goles_away_prorroga        INT DEFAULT 0,
    hubo_prorroga               BIT NOT NULL DEFAULT 0,
    fue_a_penales                BIT NOT NULL DEFAULT 0,
    penales_home                  INT NULL,   -- NULL si no hubo tanda (nunca 0 falso)
    penales_away                  INT NULL,
    ganador_equipo_id              INT NULL REFERENCES DimEquipo(equipo_id),  -- NULL = empate (solo grupos)
    resultado                      NVARCHAR(20),  -- 'local' / 'visitante' / 'empate'

    venue_nombre_raw            NVARCHAR(150),   -- venue.name crudo, solo para trazabilidad/debug

    created_at DATETIME DEFAULT GETDATE()
);
GO

-- ================================================================
-- BLOQUE 2: TABLAS DE HECHOS (granularidad = 1 evento real)
-- Todas llevan una columna "orden" = posición del evento dentro
-- de la lista original del JSON de ese partido, con UNIQUE
-- (event_id, orden). Esto es la clave natural: SofaScore no manda
-- un id estable para cada incidente/comentario/pausa en el formato
-- que usa este proyecto, así que el ETL genera uno determinístico.
-- La UNIQUE constraint es la barrera física anti-duplicación: si el
-- ETL se corre dos veces sin TRUNCATE, revienta el INSERT en vez de
-- duplicar silenciosamente (a diferencia del loader anterior, que
-- no tenía ninguna guarda para estas 4 tablas).
-- ================================================================

-- 1 fila = 1 incidente real (gol, tarjeta, sustitución, periodo...)
CREATE TABLE FactIncidents (
    id           BIGINT IDENTITY(1,1) PRIMARY KEY,
    event_id     BIGINT NOT NULL REFERENCES DimPartido(event_id),
    orden        INT NOT NULL,
    minute       INT,
    added        INT DEFAULT 0,
    period       NVARCHAR(10),
    is_home      BIT,
    type         NVARCHAR(50),
    class        NVARCHAR(50),
    player       NVARCHAR(100),
    assist       NVARCHAR(100),
    goal_type    NVARCHAR(50),
    player_in    NVARCHAR(100),
    player_out   NVARCHAR(100),
    shot_x       FLOAT,
    shot_y       FLOAT,
    reason       NVARCHAR(100),
    var_class    NVARCHAR(50),
    home_score   INT,
    away_score   INT,
    length       INT,
    text         NVARCHAR(200),
    created_at   DATETIME DEFAULT GETDATE(),
    CONSTRAINT UQ_Incidents_EventOrden UNIQUE (event_id, orden)
);
GO

-- 1 fila = 1 comentario/evento minuto a minuto real
CREATE TABLE FactComments (
    id         BIGINT IDENTITY(1,1) PRIMARY KEY,
    event_id   BIGINT NOT NULL REFERENCES DimPartido(event_id),
    orden      INT NOT NULL,
    minute     INT,
    period     NVARCHAR(10),
    type       NVARCHAR(50),
    text       NVARCHAR(MAX),
    created_at DATETIME DEFAULT GETDATE(),
    CONSTRAINT UQ_Comments_EventOrden UNIQUE (event_id, orden)
);
GO

-- 1 fila = 1 pausa de hidratación real detectada (startDelay/endDelay
-- con "drinks" en el texto). Con 104 partidos se esperan ~208 filas
-- (2 por partido); si vuelve a aparecer un número muy distinto,
-- es señal de que el ETL se corrió sin TRUNCATE antes.
CREATE TABLE FactPausasHidratacion (
    id            BIGINT IDENTITY(1,1) PRIMARY KEY,
    event_id      BIGINT NOT NULL REFERENCES DimPartido(event_id),
    orden         INT NOT NULL,     -- 1 = primera pausa del partido, 2 = segunda...
    period        NVARCHAR(10),
    start_minute  INT,
    end_minute    INT,
    duration      INT,
    pre_shots     INT, pre_corners     INT, pre_fouls     INT, pre_goals     INT,
    post_shots    INT, post_corners    INT, post_fouls    INT, post_goals    INT,
    created_at    DATETIME DEFAULT GETDATE(),
    CONSTRAINT UQ_PausasHidrat_EventOrden UNIQUE (event_id, orden)
);
GO

-- 1 fila = 1 estadística de un periodo de un partido
CREATE TABLE FactStatistics (
    id          BIGINT IDENTITY(1,1) PRIMARY KEY,
    event_id    BIGINT NOT NULL REFERENCES DimPartido(event_id),
    period      NVARCHAR(10),
    stat_name   NVARCHAR(100),
    home_value  NVARCHAR(50),
    away_value  NVARCHAR(50),
    created_at  DATETIME DEFAULT GETDATE(),
    CONSTRAINT UQ_Statistics_EventPeriodStat UNIQUE (event_id, period, stat_name)
);
GO

-- ================================================================
-- BLOQUE 3: TABLAS DE HECHOS ANALÍTICAS DERIVADAS
-- (calculadas por los SP de abajo, no cargadas directamente)
-- ================================================================

-- 1 fila = 1 ventana de 5 minutos de un partido
CREATE TABLE FactMomentum (
    id                          BIGINT IDENTITY(1,1) PRIMARY KEY,
    event_id                    BIGINT NOT NULL REFERENCES DimPartido(event_id),
    ventana_inicio               INT,
    ventana_fin                  INT,
    period                       NVARCHAR(10),
    tiros_local                   INT DEFAULT 0,
    tiros_visitante               INT DEFAULT 0,
    corners_local                 INT DEFAULT 0,
    corners_visitante             INT DEFAULT 0,
    faltas_local                  INT DEFAULT 0,
    faltas_visitante              INT DEFAULT 0,
    goles_local                   INT DEFAULT 0,
    goles_visitante               INT DEFAULT 0,
    intensidad_local              FLOAT DEFAULT 0,
    intensidad_visitante          FLOAT DEFAULT 0,
    dominancia                    FLOAT DEFAULT 0,
    ritmo_juego                   FLOAT DEFAULT 0,
    delta_intensidad_local        FLOAT NULL,
    delta_intensidad_visitante    FLOAT NULL,
    delta_dominancia              FLOAT NULL,
    es_pre_pausa                  BIT DEFAULT 0,
    es_post_pausa                 BIT DEFAULT 0,
    pausa_id                      BIGINT NULL REFERENCES FactPausasHidratacion(id),
    created_at DATETIME DEFAULT GETDATE(),
    CONSTRAINT UQ_Momentum_EventVentanaPeriod UNIQUE (event_id, period, ventana_inicio)
);
GO

-- 1 fila = 1 pausa, con todas sus métricas pre/post consolidadas
CREATE TABLE FactPausaMetricas (
    id                    BIGINT IDENTITY(1,1) PRIMARY KEY,
    pausa_id              BIGINT NOT NULL UNIQUE REFERENCES FactPausasHidratacion(id),
    event_id              BIGINT NOT NULL REFERENCES DimPartido(event_id),
    period                NVARCHAR(10),
    start_minute          INT,
    end_minute            INT,
    duration_min          INT,
    ventana_minutos       INT DEFAULT 10,
    pre_tiros_total INT DEFAULT 0, pre_tiros_local INT DEFAULT 0, pre_tiros_visitante INT DEFAULT 0,
    pre_corners_total INT DEFAULT 0, pre_faltas_total INT DEFAULT 0, pre_goles_total INT DEFAULT 0,
    pre_intensidad_local FLOAT DEFAULT 0, pre_intensidad_visit FLOAT DEFAULT 0, pre_dominancia FLOAT DEFAULT 0,
    post_tiros_total INT DEFAULT 0, post_tiros_local INT DEFAULT 0, post_tiros_visitante INT DEFAULT 0,
    post_corners_total INT DEFAULT 0, post_faltas_total INT DEFAULT 0, post_goles_total INT DEFAULT 0,
    post_intensidad_local FLOAT DEFAULT 0, post_intensidad_visit FLOAT DEFAULT 0, post_dominancia FLOAT DEFAULT 0,
    delta_tiros INT, delta_corners INT, delta_faltas INT, delta_goles INT,
    delta_intensidad_local FLOAT, delta_intensidad_visit FLOAT, delta_dominancia FLOAT,
    marcador_local_al_inicio INT, marcador_visit_al_inicio INT, diferencia_goles INT,
    equipo_ganando NVARCHAR(10), es_eliminatoria BIT, pausa_numero INT,
    created_at DATETIME DEFAULT GETDATE()
);
GO

-- 1 fila = 1 pausa, con la pregunta "¿hubo gol después?"
CREATE TABLE FactGolPostPausa (
    id                BIGINT IDENTITY(1,1) PRIMARY KEY,
    pausa_id          BIGINT NOT NULL UNIQUE REFERENCES FactPausasHidratacion(id),
    event_id          BIGINT NOT NULL REFERENCES DimPartido(event_id),
    period            NVARCHAR(10),
    end_minute        INT,
    gol_en_5min       BIT DEFAULT 0,
    gol_en_10min      BIT DEFAULT 0,
    gol_en_15min      BIT DEFAULT 0,
    minuto_primer_gol INT NULL,
    equipo_gol        NVARCHAR(10),
    tipo_gol          NVARCHAR(50),
    created_at DATETIME DEFAULT GETDATE()
);
GO

-- ================================================================
-- BLOQUE 4: TABLAS RESUMEN PARA POWER BI (1 fila = 1 partido / 1 fila = todo el torneo)
-- ================================================================

CREATE TABLE ResumenPartido (
    event_id              BIGINT PRIMARY KEY REFERENCES DimPartido(event_id),
    home_team             NVARCHAR(100),
    away_team             NVARCHAR(100),
    home_score            INT,           -- = DimPartido.goles_home (fuente de verdad)
    away_score            INT,
    ronda                 INT,
    nombre_fase           NVARCHAR(50),
    es_eliminatoria       BIT,
    total_goles           INT,           -- = home_score + away_score, NUNCA de un JOIN a FactIncidents
    total_goles_incidents INT,           -- conteo derivado de FactIncidents type='goal' (cruce de control)
    total_tiros           INT,
    total_corners         INT,
    total_faltas          INT,
    total_tarjetas_am     INT,
    total_tarjetas_ro     INT,
    total_sustituciones   INT,
    total_pausas_hidrat   INT,
    hubo_pausa_1st        BIT,
    hubo_pausa_2nd        BIT,
    minuto_pausa_1st      INT,
    minuto_pausa_2nd      INT,
    gol_post_pausa_1st    BIT,
    gol_post_pausa_2nd    BIT,
    hubo_prorroga         BIT,
    fue_a_penales         BIT,
    created_at DATETIME DEFAULT GETDATE()
);
GO

CREATE TABLE ResumenTorneo (
    id                          INT IDENTITY(1,1) PRIMARY KEY,
    total_partidos              INT,
    total_goles                 INT,
    promedio_goles_partido      FLOAT,
    total_pausas_hidratacion    INT,
    promedio_pausas_partido     FLOAT,
    partidos_con_gol_post_pausa INT,
    pct_gol_post_pausa_10min    FLOAT,
    total_tarjetas_amarillas    INT,
    total_tarjetas_rojas        INT,
    promedio_tiros_partido      FLOAT,
    partidos_con_penales        INT,
    calculado_en DATETIME DEFAULT GETDATE()
);
GO

-- ================================================================
-- BLOQUE 5: ÍNDICES
-- ================================================================

CREATE INDEX IX_FactComments_EventTypeMinute ON FactComments(event_id, type, minute) INCLUDE (period, text);
CREATE INDEX IX_FactIncidents_TypePeriod ON FactIncidents(event_id, type, period) INCLUDE (minute, player, is_home, shot_x, shot_y);
CREATE INDEX IX_PausasHidrat_EventPeriod ON FactPausasHidratacion(event_id, period) INCLUDE (start_minute, end_minute, duration);
CREATE INDEX IX_Momentum_EventVentana ON FactMomentum(event_id, ventana_inicio, ventana_fin) INCLUDE (intensidad_local, intensidad_visitante, dominancia);
CREATE INDEX IX_DimPartido_Equipos ON DimPartido(home_equipo_id, away_equipo_id) INCLUDE (event_id, ronda, goles_home, goles_away);
GO

PRINT 'Esquema recreado. Ahora corre 01_REBUILD_ETL.py para cargar los datos.';
GO

-- ================================================================
-- BLOQUE 6: PROCEDIMIENTOS ALMACENADOS
--
-- REGLA DE ORO aplicada en TODOS los SP de este bloque (era la
-- causa raíz de los ~1.8M goles / 17.000 promedio):
--   Cada tabla de hechos se agrega a UNA fila por partido (o por
--   pausa) en su propio CTE ANTES de unirla con cualquier otra
--   tabla de hechos. Nunca se hace JOIN de dos tablas de hechos
--   "crudas" (sin agregar) en el mismo FROM solo por event_id.
-- ================================================================

-- ----------------------------------------------------------------
-- sp_PoblarMomentum: ventanas de 5 minutos, local/visitante
-- determinado por el nombre real del equipo (no por texto
-- inventado tipo "%home%" ni hardcodeado tipo "%Mexico%").
-- Grano de agregación: FactComments -> GROUP BY event_id, ventana,
-- period. Una sola tabla de hechos por consulta: sin fan-out.
-- ----------------------------------------------------------------
CREATE OR ALTER PROCEDURE sp_PoblarMomentum
    @ventana_minutos INT = 5
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM FactMomentum;

    WITH Ventanas AS (
        SELECT 0 AS inicio, 5 AS fin
        UNION ALL
        SELECT inicio + 5, fin + 5 FROM Ventanas WHERE fin < 120
    ),
    EventosPorVentana AS (
        SELECT
            c.event_id, v.inicio, v.fin, c.period,
            SUM(CASE WHEN c.type IN ('shotOnTarget','shotOffTarget','shotBlocked','post')
                     AND c.text LIKE '%' + dp.home_team + '%' THEN 1 ELSE 0 END) AS tiros_local,
            SUM(CASE WHEN c.type IN ('shotOnTarget','shotOffTarget','shotBlocked','post')
                     AND c.text LIKE '%' + dp.away_team + '%'
                     AND c.text NOT LIKE '%' + dp.home_team + '%' THEN 1 ELSE 0 END) AS tiros_visit,
            SUM(CASE WHEN c.type = 'cornerKick' AND c.text LIKE '%' + dp.home_team + '%' THEN 1 ELSE 0 END) AS corners_local,
            SUM(CASE WHEN c.type = 'cornerKick' AND c.text LIKE '%' + dp.away_team + '%'
                     AND c.text NOT LIKE '%' + dp.home_team + '%' THEN 1 ELSE 0 END) AS corners_visit,
            SUM(CASE WHEN c.type IN ('freeKickWon','freeKickLost') AND c.text LIKE '%' + dp.home_team + '%' THEN 1 ELSE 0 END) AS faltas_local,
            SUM(CASE WHEN c.type IN ('freeKickWon','freeKickLost') AND c.text LIKE '%' + dp.away_team + '%'
                     AND c.text NOT LIKE '%' + dp.home_team + '%' THEN 1 ELSE 0 END) AS faltas_visit,
            SUM(CASE WHEN c.type = 'scoreChange' AND c.text LIKE '%' + dp.home_team + '%' THEN 1 ELSE 0 END) AS goles_local,
            SUM(CASE WHEN c.type = 'scoreChange' AND c.text LIKE '%' + dp.away_team + '%'
                     AND c.text NOT LIKE '%' + dp.home_team + '%' THEN 1 ELSE 0 END) AS goles_visit
        FROM FactComments c
        JOIN DimPartido dp ON dp.event_id = c.event_id
        JOIN Ventanas v ON c.minute >= v.inicio AND c.minute < v.fin
        GROUP BY c.event_id, v.inicio, v.fin, c.period
    )
    INSERT INTO FactMomentum (
        event_id, ventana_inicio, ventana_fin, period,
        tiros_local, tiros_visitante, corners_local, corners_visitante,
        faltas_local, faltas_visitante, goles_local, goles_visitante,
        intensidad_local, intensidad_visitante, dominancia, ritmo_juego
    )
    SELECT
        event_id, inicio, fin, period,
        tiros_local, tiros_visit, corners_local, corners_visit,
        faltas_local, faltas_visit, goles_local, goles_visit,
        (tiros_local * 2.0 + corners_local * 1.0 + faltas_local * 0.5 + goles_local * 5.0),
        (tiros_visit  * 2.0 + corners_visit  * 1.0 + faltas_visit  * 0.5 + goles_visit  * 5.0),
        (tiros_local * 2.0 + corners_local * 1.0 + goles_local * 5.0) -
        (tiros_visit  * 2.0 + corners_visit  * 1.0 + goles_visit  * 5.0),
        (tiros_local + tiros_visit) * 2.0 + (corners_local + corners_visit) * 1.0
            + (faltas_local + faltas_visit) * 0.5 + (goles_local + goles_visit) * 5.0
    FROM EventosPorVentana
    OPTION (MAXRECURSION 200);

    UPDATE m
    SET es_pre_pausa  = CASE WHEN m.ventana_fin <= ph.start_minute AND m.ventana_inicio >= ph.start_minute - 10 THEN 1 ELSE 0 END,
        es_post_pausa = CASE WHEN m.ventana_inicio >= ph.end_minute AND m.ventana_fin <= ph.end_minute + 10 THEN 1 ELSE 0 END,
        pausa_id      = ph.id
    FROM FactMomentum m
    JOIN FactPausasHidratacion ph ON ph.event_id = m.event_id AND ph.period = m.period;

    UPDATE m
    SET delta_intensidad_local     = m.intensidad_local     - prev.intensidad_local,
        delta_intensidad_visitante = m.intensidad_visitante - prev.intensidad_visitante,
        delta_dominancia           = m.dominancia            - prev.dominancia
    FROM FactMomentum m
    JOIN FactMomentum prev ON prev.event_id = m.event_id AND prev.period = m.period AND prev.ventana_fin = m.ventana_inicio;

    PRINT 'FactMomentum poblado.';
END;
GO

-- ----------------------------------------------------------------
-- sp_PoblarPausaMetricas: 1 fila resultante por pausa. Cada
-- subconsulta agrega hasta el grano de "pausa" antes del JOIN
-- final, así que no hay multiplicación cruzada.
-- ----------------------------------------------------------------
CREATE OR ALTER PROCEDURE sp_PoblarPausaMetricas
    @ventana INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM FactGolPostPausa;
    DELETE FROM FactPausaMetricas;

    WITH PausasNumeradas AS (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY start_minute) AS pausa_numero
        FROM FactPausasHidratacion
    ),
    MarcadorEnPausa AS (
        SELECT ph.id AS pausa_id, ph.event_id,
            SUM(CASE WHEN i.type = 'goal' AND i.is_home = 1 AND i.minute < ph.start_minute THEN 1 ELSE 0 END) AS goles_local,
            SUM(CASE WHEN i.type = 'goal' AND i.is_home = 0 AND i.minute < ph.start_minute THEN 1 ELSE 0 END) AS goles_visit
        FROM PausasNumeradas ph
        LEFT JOIN FactIncidents i ON i.event_id = ph.event_id AND i.minute < ph.start_minute
        GROUP BY ph.id, ph.event_id
    ),
    Splits AS (
        SELECT
            ph.id AS pausa_id,
            SUM(CASE WHEN c.minute >= ph.start_minute - @ventana AND c.minute < ph.start_minute
                     AND c.type IN ('shotOnTarget','shotOffTarget','shotBlocked','post')
                     AND c.text LIKE '%' + dp.home_team + '%' THEN 1 ELSE 0 END) AS pre_tiros_local,
            SUM(CASE WHEN c.minute >= ph.start_minute - @ventana AND c.minute < ph.start_minute
                     AND c.type IN ('shotOnTarget','shotOffTarget','shotBlocked','post')
                     AND c.text LIKE '%' + dp.away_team + '%' AND c.text NOT LIKE '%' + dp.home_team + '%' THEN 1 ELSE 0 END) AS pre_tiros_visit,
            SUM(CASE WHEN c.minute >= ph.start_minute - @ventana AND c.minute < ph.start_minute
                     AND c.type = 'cornerKick' AND c.text LIKE '%' + dp.home_team + '%' THEN 1 ELSE 0 END) AS pre_corners_local,
            SUM(CASE WHEN c.minute >= ph.start_minute - @ventana AND c.minute < ph.start_minute
                     AND c.type = 'cornerKick' AND c.text LIKE '%' + dp.away_team + '%' AND c.text NOT LIKE '%' + dp.home_team + '%' THEN 1 ELSE 0 END) AS pre_corners_visit,
            SUM(CASE WHEN c.minute >= ph.start_minute - @ventana AND c.minute < ph.start_minute
                     AND c.type IN ('freeKickWon','freeKickLost') AND c.text LIKE '%' + dp.home_team + '%' THEN 1 ELSE 0 END) AS pre_faltas_local,
            SUM(CASE WHEN c.minute >= ph.start_minute - @ventana AND c.minute < ph.start_minute
                     AND c.type IN ('freeKickWon','freeKickLost') AND c.text LIKE '%' + dp.away_team + '%' AND c.text NOT LIKE '%' + dp.home_team + '%' THEN 1 ELSE 0 END) AS pre_faltas_visit,
            SUM(CASE WHEN c.minute > ph.end_minute AND c.minute <= ph.end_minute + @ventana
                     AND c.type IN ('shotOnTarget','shotOffTarget','shotBlocked','post')
                     AND c.text LIKE '%' + dp.home_team + '%' THEN 1 ELSE 0 END) AS post_tiros_local,
            SUM(CASE WHEN c.minute > ph.end_minute AND c.minute <= ph.end_minute + @ventana
                     AND c.type IN ('shotOnTarget','shotOffTarget','shotBlocked','post')
                     AND c.text LIKE '%' + dp.away_team + '%' AND c.text NOT LIKE '%' + dp.home_team + '%' THEN 1 ELSE 0 END) AS post_tiros_visit,
            SUM(CASE WHEN c.minute > ph.end_minute AND c.minute <= ph.end_minute + @ventana
                     AND c.type = 'cornerKick' AND c.text LIKE '%' + dp.home_team + '%' THEN 1 ELSE 0 END) AS post_corners_local,
            SUM(CASE WHEN c.minute > ph.end_minute AND c.minute <= ph.end_minute + @ventana
                     AND c.type = 'cornerKick' AND c.text LIKE '%' + dp.away_team + '%' AND c.text NOT LIKE '%' + dp.home_team + '%' THEN 1 ELSE 0 END) AS post_corners_visit,
            SUM(CASE WHEN c.minute > ph.end_minute AND c.minute <= ph.end_minute + @ventana
                     AND c.type IN ('freeKickWon','freeKickLost') AND c.text LIKE '%' + dp.home_team + '%' THEN 1 ELSE 0 END) AS post_faltas_local,
            SUM(CASE WHEN c.minute > ph.end_minute AND c.minute <= ph.end_minute + @ventana
                     AND c.type IN ('freeKickWon','freeKickLost') AND c.text LIKE '%' + dp.away_team + '%' AND c.text NOT LIKE '%' + dp.home_team + '%' THEN 1 ELSE 0 END) AS post_faltas_visit,
            SUM(CASE WHEN c.minute >= ph.start_minute - @ventana AND c.minute < ph.start_minute AND c.type = 'scoreChange' THEN 1 ELSE 0 END) AS pre_goles_total,
            SUM(CASE WHEN c.minute > ph.end_minute AND c.minute <= ph.end_minute + @ventana AND c.type = 'scoreChange' THEN 1 ELSE 0 END) AS post_goles_total
        FROM PausasNumeradas ph
        JOIN FactComments c ON c.event_id = ph.event_id AND c.period = ph.period
        JOIN DimPartido dp  ON dp.event_id = ph.event_id
        GROUP BY ph.id
    )
    INSERT INTO FactPausaMetricas (
        pausa_id, event_id, period, start_minute, end_minute, duration_min, ventana_minutos,
        pre_tiros_total, pre_tiros_local, pre_tiros_visitante, pre_corners_total, pre_faltas_total, pre_goles_total,
        pre_intensidad_local, pre_intensidad_visit, pre_dominancia,
        post_tiros_total, post_tiros_local, post_tiros_visitante, post_corners_total, post_faltas_total, post_goles_total,
        post_intensidad_local, post_intensidad_visit, post_dominancia,
        delta_tiros, delta_corners, delta_faltas, delta_goles,
        delta_intensidad_local, delta_intensidad_visit, delta_dominancia,
        marcador_local_al_inicio, marcador_visit_al_inicio, diferencia_goles, equipo_ganando, es_eliminatoria, pausa_numero
    )
    SELECT
        ph.id, ph.event_id, ph.period, ph.start_minute, ph.end_minute, ph.duration, @ventana,
        s.pre_tiros_local + s.pre_tiros_visit, s.pre_tiros_local, s.pre_tiros_visit,
        s.pre_corners_local + s.pre_corners_visit, s.pre_faltas_local + s.pre_faltas_visit, s.pre_goles_total,
        (s.pre_tiros_local * 2.0 + s.pre_corners_local * 1.0 + s.pre_faltas_local * 0.5),
        (s.pre_tiros_visit * 2.0 + s.pre_corners_visit * 1.0 + s.pre_faltas_visit * 0.5),
        (s.pre_tiros_local * 2.0 + s.pre_corners_local * 1.0) - (s.pre_tiros_visit * 2.0 + s.pre_corners_visit * 1.0),
        s.post_tiros_local + s.post_tiros_visit, s.post_tiros_local, s.post_tiros_visit,
        s.post_corners_local + s.post_corners_visit, s.post_faltas_local + s.post_faltas_visit, s.post_goles_total,
        (s.post_tiros_local * 2.0 + s.post_corners_local * 1.0 + s.post_faltas_local * 0.5),
        (s.post_tiros_visit * 2.0 + s.post_corners_visit * 1.0 + s.post_faltas_visit * 0.5),
        (s.post_tiros_local * 2.0 + s.post_corners_local * 1.0) - (s.post_tiros_visit * 2.0 + s.post_corners_visit * 1.0),
        (s.post_tiros_local + s.post_tiros_visit) - (s.pre_tiros_local + s.pre_tiros_visit),
        (s.post_corners_local + s.post_corners_visit) - (s.pre_corners_local + s.pre_corners_visit),
        (s.post_faltas_local + s.post_faltas_visit) - (s.pre_faltas_local + s.pre_faltas_visit),
        s.post_goles_total - s.pre_goles_total,
        (s.post_tiros_local * 2.0 + s.post_corners_local * 1.0 + s.post_faltas_local * 0.5) - (s.pre_tiros_local * 2.0 + s.pre_corners_local * 1.0 + s.pre_faltas_local * 0.5),
        (s.post_tiros_visit * 2.0 + s.post_corners_visit * 1.0 + s.post_faltas_visit * 0.5) - (s.pre_tiros_visit * 2.0 + s.pre_corners_visit * 1.0 + s.pre_faltas_visit * 0.5),
        ((s.post_tiros_local * 2.0 + s.post_corners_local * 1.0) - (s.post_tiros_visit * 2.0 + s.post_corners_visit * 1.0))
            - ((s.pre_tiros_local * 2.0 + s.pre_corners_local * 1.0) - (s.pre_tiros_visit * 2.0 + s.pre_corners_visit * 1.0)),
        mep.goles_local, mep.goles_visit, mep.goles_local - mep.goles_visit,
        CASE WHEN mep.goles_local > mep.goles_visit THEN 'local' WHEN mep.goles_local < mep.goles_visit THEN 'visitante' ELSE 'empate' END,
        ISNULL(f.es_eliminatoria, 0), pn.pausa_numero
    FROM PausasNumeradas ph
    JOIN Splits s ON s.pausa_id = ph.id
    JOIN DimPartido dp ON dp.event_id = ph.event_id
    LEFT JOIN DimFase f ON dp.fase_id = f.fase_id
    JOIN MarcadorEnPausa mep ON mep.pausa_id = ph.id
    JOIN PausasNumeradas pn ON pn.id = ph.id;

    INSERT INTO FactGolPostPausa (pausa_id, event_id, period, end_minute, gol_en_5min, gol_en_10min, gol_en_15min, minuto_primer_gol, equipo_gol, tipo_gol)
    SELECT
        ph.id, ph.event_id, ph.period, ph.end_minute,
        MAX(CASE WHEN i.minute > ph.end_minute AND i.minute <= ph.end_minute + 5  AND i.type = 'goal' THEN 1 ELSE 0 END),
        MAX(CASE WHEN i.minute > ph.end_minute AND i.minute <= ph.end_minute + 10 AND i.type = 'goal' THEN 1 ELSE 0 END),
        MAX(CASE WHEN i.minute > ph.end_minute AND i.minute <= ph.end_minute + 15 AND i.type = 'goal' THEN 1 ELSE 0 END),
        MIN(CASE WHEN i.minute > ph.end_minute AND i.minute <= ph.end_minute + 15 AND i.type = 'goal' THEN i.minute ELSE NULL END),
        MIN(CASE WHEN i.minute > ph.end_minute AND i.minute <= ph.end_minute + 15 AND i.type = 'goal' THEN CASE WHEN i.is_home = 1 THEN 'local' ELSE 'visitante' END END),
        MIN(CASE WHEN i.minute > ph.end_minute AND i.minute <= ph.end_minute + 15 AND i.type = 'goal' THEN i.class END)
    FROM FactPausasHidratacion ph
    LEFT JOIN FactIncidents i ON i.event_id = ph.event_id
    GROUP BY ph.id, ph.event_id, ph.period, ph.end_minute;

    -- Sync FactPausasHidratacion.pre_*/post_* (evita duplicar la lógica de nuevo)
    UPDATE ph
    SET pre_shots = pm.pre_tiros_total, pre_corners = pm.pre_corners_total, pre_fouls = pm.pre_faltas_total, pre_goals = pm.pre_goles_total,
        post_shots = pm.post_tiros_total, post_corners = pm.post_corners_total, post_fouls = pm.post_faltas_total, post_goals = pm.post_goles_total
    FROM FactPausasHidratacion ph
    JOIN FactPausaMetricas pm ON pm.pausa_id = ph.id;

    PRINT 'FactPausaMetricas, FactGolPostPausa y sync de FactPausasHidratacion completados.';
END;
GO

-- ----------------------------------------------------------------
-- sp_PoblarResumenPartido: EL FIX CENTRAL. Cada tabla de hechos se
-- agrega en su propio CTE (grano = 1 fila por event_id) ANTES de
-- unirlas. Así es imposible que un JOIN cruzado multiplique goles
-- por comentarios por pausas, que era exactamente la causa de los
-- ~1.8M goles / ~17.000 promedio.
--
-- total_goles usa DimPartido.goles_home/away (fuente de verdad,
-- viene directo del marcador oficial de SofaScore) — NO cuenta
-- filas de FactIncidents. total_goles_incidents sí cuenta
-- FactIncidents type='goal' como métrica de cruce/control: si
-- alguna vez difieren, sp_ValidarDW lo marca como alerta de calidad.
-- ----------------------------------------------------------------
CREATE OR ALTER PROCEDURE sp_PoblarResumenPartido
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM ResumenPartido;

    WITH AgIncidents AS (
        SELECT event_id,
            SUM(CASE WHEN type = 'goal' THEN 1 ELSE 0 END) AS total_goles_incidents,
            SUM(CASE WHEN type = 'card' AND class = 'yellow' THEN 1 ELSE 0 END) AS total_tarjetas_am,
            SUM(CASE WHEN type = 'card' AND class = 'red' THEN 1 ELSE 0 END) AS total_tarjetas_ro,
            SUM(CASE WHEN type = 'substitution' THEN 1 ELSE 0 END) AS total_sustituciones
        FROM FactIncidents
        GROUP BY event_id
    ),
    AgComments AS (
        SELECT event_id,
            SUM(CASE WHEN type IN ('shotOnTarget','shotOffTarget','shotBlocked','post') THEN 1 ELSE 0 END) AS total_tiros,
            SUM(CASE WHEN type = 'cornerKick' THEN 1 ELSE 0 END) AS total_corners,
            SUM(CASE WHEN type IN ('freeKickWon','freeKickLost') THEN 1 ELSE 0 END) AS total_faltas
        FROM FactComments
        GROUP BY event_id
    ),
    AgPausas AS (
        SELECT event_id,
            COUNT(*) AS total_pausas_hidrat,
            MAX(CASE WHEN period = '1ST' THEN 1 ELSE 0 END) AS hubo_pausa_1st,
            MAX(CASE WHEN period = '2ND' THEN 1 ELSE 0 END) AS hubo_pausa_2nd,
            MIN(CASE WHEN period = '1ST' THEN start_minute END) AS minuto_pausa_1st,
            MIN(CASE WHEN period = '2ND' THEN start_minute END) AS minuto_pausa_2nd
        FROM FactPausasHidratacion
        GROUP BY event_id
    ),
    AgGolPost AS (
        SELECT ph.event_id,
            MAX(CASE WHEN ph.period = '1ST' AND gp.gol_en_10min = 1 THEN 1 ELSE 0 END) AS gol_post_pausa_1st,
            MAX(CASE WHEN ph.period = '2ND' AND gp.gol_en_10min = 1 THEN 1 ELSE 0 END) AS gol_post_pausa_2nd
        FROM FactPausasHidratacion ph
        LEFT JOIN FactGolPostPausa gp ON gp.pausa_id = ph.id
        GROUP BY ph.event_id
    )
    INSERT INTO ResumenPartido (
        event_id, home_team, away_team, home_score, away_score, ronda, nombre_fase, es_eliminatoria,
        total_goles, total_goles_incidents, total_tiros, total_corners, total_faltas,
        total_tarjetas_am, total_tarjetas_ro, total_sustituciones, total_pausas_hidrat,
        hubo_pausa_1st, hubo_pausa_2nd, minuto_pausa_1st, minuto_pausa_2nd,
        gol_post_pausa_1st, gol_post_pausa_2nd, hubo_prorroga, fue_a_penales
    )
    SELECT
        d.event_id, d.home_team, d.away_team, d.goles_home, d.goles_away, d.ronda, f.nombre_fase, ISNULL(f.es_eliminatoria, 0),
        d.goles_home + d.goles_away,                     -- total_goles: FUENTE DE VERDAD
        ISNULL(ai.total_goles_incidents, 0),              -- cruce de control
        ISNULL(ac.total_tiros, 0), ISNULL(ac.total_corners, 0), ISNULL(ac.total_faltas, 0),
        ISNULL(ai.total_tarjetas_am, 0), ISNULL(ai.total_tarjetas_ro, 0), ISNULL(ai.total_sustituciones, 0),
        ISNULL(ap.total_pausas_hidrat, 0), ISNULL(ap.hubo_pausa_1st, 0), ISNULL(ap.hubo_pausa_2nd, 0),
        ap.minuto_pausa_1st, ap.minuto_pausa_2nd,
        ISNULL(agp.gol_post_pausa_1st, 0), ISNULL(agp.gol_post_pausa_2nd, 0),
        d.hubo_prorroga, d.fue_a_penales
    FROM DimPartido d
    LEFT JOIN DimFase     f   ON f.fase_id = d.fase_id
    LEFT JOIN AgIncidents ai  ON ai.event_id = d.event_id
    LEFT JOIN AgComments  ac  ON ac.event_id = d.event_id
    LEFT JOIN AgPausas    ap  ON ap.event_id = d.event_id
    LEFT JOIN AgGolPost   agp ON agp.event_id = d.event_id;

    PRINT 'ResumenPartido poblado (sin fan-out entre tablas de hechos).';
END;
GO

-- ----------------------------------------------------------------
-- sp_PoblarResumenTorneo
-- ----------------------------------------------------------------
CREATE OR ALTER PROCEDURE sp_PoblarResumenTorneo
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM ResumenTorneo;

    INSERT INTO ResumenTorneo (
        total_partidos, total_goles, promedio_goles_partido,
        total_pausas_hidratacion, promedio_pausas_partido,
        partidos_con_gol_post_pausa, pct_gol_post_pausa_10min,
        total_tarjetas_amarillas, total_tarjetas_rojas,
        promedio_tiros_partido, partidos_con_penales
    )
    SELECT
        COUNT(*),
        SUM(rp.total_goles),
        AVG(CAST(rp.total_goles AS FLOAT)),
        SUM(rp.total_pausas_hidrat),
        AVG(CAST(rp.total_pausas_hidrat AS FLOAT)),
        SUM(CASE WHEN rp.gol_post_pausa_1st = 1 OR rp.gol_post_pausa_2nd = 1 THEN 1 ELSE 0 END),
        (SELECT CAST(SUM(CAST(gol_en_10min AS INT)) AS FLOAT) / NULLIF(COUNT(*), 0) * 100 FROM FactGolPostPausa),
        SUM(rp.total_tarjetas_am),
        SUM(rp.total_tarjetas_ro),
        AVG(CAST(rp.total_tiros AS FLOAT)),
        SUM(CASE WHEN rp.fue_a_penales = 1 THEN 1 ELSE 0 END)
    FROM ResumenPartido rp;

    PRINT 'ResumenTorneo poblado.';
END;
GO

-- ----------------------------------------------------------------
-- sp_ActualizarTodo: único punto de entrada para repoblar TODO lo
-- derivado, en el orden correcto de dependencias.
-- ----------------------------------------------------------------
CREATE OR ALTER PROCEDURE sp_ActualizarTodo
AS
BEGIN
    PRINT 'Iniciando actualización completa del DW...';
    EXEC sp_PoblarMomentum      @ventana_minutos = 5;
    EXEC sp_PoblarPausaMetricas @ventana = 10;
    EXEC sp_PoblarResumenPartido;
    EXEC sp_PoblarResumenTorneo;
    PRINT 'Actualización completa finalizada.';
END;
GO

-- ----------------------------------------------------------------
-- sp_ValidarDW: validaciones de integridad + controles de
-- plausibilidad futbolística (secciones 18-20 del prompt maestro).
-- No basta con que SQL Server acepte los datos: se valida que
-- tengan sentido.
-- ----------------------------------------------------------------
CREATE OR ALTER PROCEDURE sp_ValidarDW
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @partidos INT, @goles INT, @pausas INT, @dupIncidents INT, @dupComments INT,
            @dupPausas INT, @fkHuerfanas INT, @idsNull INT, @promGoles FLOAT, @promPausas FLOAT,
            @equipos INT, @estadios INT, @comentarios INT, @tarjetas INT, @sustituciones INT,
            @conPenales INT, @mismatchGoles INT;

    SELECT @partidos = COUNT(*) FROM DimPartido;
    SELECT @equipos = COUNT(*) FROM DimEquipo;
    SELECT @estadios = COUNT(*) FROM DimEstadio;
    SELECT @goles = SUM(goles_home + goles_away) FROM DimPartido;
    SELECT @pausas = COUNT(*) FROM FactPausasHidratacion;
    SELECT @comentarios = COUNT(*) FROM FactComments;
    SELECT @tarjetas = SUM(CASE WHEN type = 'card' THEN 1 ELSE 0 END) FROM FactIncidents;
    SELECT @sustituciones = SUM(CASE WHEN type = 'substitution' THEN 1 ELSE 0 END) FROM FactIncidents;
    SELECT @conPenales = COUNT(*) FROM DimPartido WHERE fue_a_penales = 1;

    -- Duplicados por clave natural (event_id, orden) — no deberían existir nunca
    -- por la UNIQUE constraint, pero se valida igual como cinturón y tirantes.
    SELECT @dupIncidents = ISNULL(SUM(c - 1), 0) FROM (SELECT COUNT(*) c FROM FactIncidents GROUP BY event_id, orden HAVING COUNT(*) > 1) x;
    SELECT @dupComments  = ISNULL(SUM(c - 1), 0) FROM (SELECT COUNT(*) c FROM FactComments GROUP BY event_id, orden HAVING COUNT(*) > 1) x;
    SELECT @dupPausas    = ISNULL(SUM(c - 1), 0) FROM (SELECT COUNT(*) c FROM FactPausasHidratacion GROUP BY event_id, orden HAVING COUNT(*) > 1) x;

    -- FK huérfanas (no debería pasar por las FK reales, pero se documenta)
    SELECT @fkHuerfanas =
        (SELECT COUNT(*) FROM FactIncidents i WHERE NOT EXISTS (SELECT 1 FROM DimPartido d WHERE d.event_id = i.event_id)) +
        (SELECT COUNT(*) FROM FactPausasHidratacion p WHERE NOT EXISTS (SELECT 1 FROM DimPartido d WHERE d.event_id = p.event_id));

    -- IDs críticos NULL
    SELECT @idsNull =
        (SELECT COUNT(*) FROM DimPartido WHERE home_equipo_id IS NULL OR away_equipo_id IS NULL) +
        (SELECT COUNT(*) FROM DimPartido WHERE fase_id IS NULL) +
        (SELECT COUNT(*) FROM DimPartido WHERE estadio_id IS NULL);

    -- Cruce de control: total_goles (fuente de verdad) vs conteo de FactIncidents type='goal'
    SELECT @mismatchGoles = COUNT(*) FROM ResumenPartido WHERE total_goles <> total_goles_incidents;

    SET @promGoles  = CAST(@goles AS FLOAT) / NULLIF(@partidos, 0);
    SET @promPausas = CAST(@pausas AS FLOAT) / NULLIF(@partidos, 0);

    PRINT '================================================';
    PRINT 'REBUILD MUNDIAL 2026';
    PRINT '================================================';
    PRINT '';
    PRINT 'Partidos:                  ' + CAST(@partidos AS VARCHAR);
    PRINT 'Equipos:                   ' + CAST(@equipos AS VARCHAR);
    PRINT 'Estadios:                  ' + CAST(@estadios AS VARCHAR);
    PRINT 'Goles (fuente de verdad):  ' + CAST(@goles AS VARCHAR);
    PRINT 'Pausas hidratacion:        ' + CAST(@pausas AS VARCHAR);
    PRINT 'Comentarios:                ' + CAST(@comentarios AS VARCHAR);
    PRINT 'Tarjetas:                  ' + CAST(@tarjetas AS VARCHAR);
    PRINT 'Sustituciones:             ' + CAST(@sustituciones AS VARCHAR);
    PRINT 'Partidos con penales:      ' + CAST(@conPenales AS VARCHAR);
    PRINT '';
    PRINT 'Duplicados criticos:       ' + CAST(@dupIncidents + @dupComments + @dupPausas AS VARCHAR);
    PRINT 'FK huerfanas:              ' + CAST(@fkHuerfanas AS VARCHAR);
    PRINT 'IDs criticos NULL:         ' + CAST(@idsNull AS VARCHAR);
    PRINT 'Partidos con mismatch de goles (ResumenPartido vs FactIncidents): ' + CAST(@mismatchGoles AS VARCHAR);
    PRINT '';
    PRINT 'Promedio goles/partido:    ' + CAST(ROUND(@promGoles, 2) AS VARCHAR);
    PRINT 'Promedio pausas/partido:   ' + CAST(ROUND(@promPausas, 2) AS VARCHAR);
    PRINT '';

    IF @promGoles > 10 OR @promPausas > 6 OR @dupIncidents > 0 OR @dupComments > 0 OR @dupPausas > 0 OR @fkHuerfanas > 0
    BEGIN
        PRINT '================================================';
        PRINT 'ERROR DE CALIDAD — revisar antes de usar en Power BI';
        PRINT '================================================';
    END
    ELSE
    BEGIN
        PRINT '================================================';
        PRINT 'DATA WAREHOUSE VALIDADO';
        PRINT '================================================';
    END

    -- ---- RESUMEN COMO RESULTSET (los PRINT de arriba no llegan a pyodbc,
    -- Python solo captura SELECTs — este es el que hay que leer desde el ETL) ----
    SELECT
        @partidos            AS partidos,
        @equipos              AS equipos,
        @estadios             AS estadios,
        @goles                AS goles_total,
        ROUND(@promGoles, 2)  AS promedio_goles_partido,
        @pausas               AS pausas_hidratacion,
        ROUND(@promPausas, 2) AS promedio_pausas_partido,
        @comentarios          AS comentarios,
        @tarjetas             AS tarjetas,
        @sustituciones        AS sustituciones,
        @conPenales           AS partidos_con_penales,
        @dupIncidents + @dupComments + @dupPausas AS duplicados_criticos,
        @fkHuerfanas          AS fk_huerfanas,
        @idsNull              AS ids_criticos_null,
        @mismatchGoles        AS partidos_con_mismatch_goles,
        CASE WHEN @promGoles > 10 OR @promPausas > 6 OR @dupIncidents > 0 OR @dupComments > 0
                  OR @dupPausas > 0 OR @fkHuerfanas > 0
             THEN 'ERROR DE CALIDAD — revisar antes de usar en Power BI'
             ELSE 'DATA WAREHOUSE VALIDADO' END AS veredicto;

    -- Detalle: partidos con tanda de penales (sección 16 del prompt maestro)
    SELECT
        d.event_id, d.home_team, d.away_team,
        d.goles_home, d.goles_away,
        d.penales_home, d.penales_away,
        d.fue_a_penales,
        CASE WHEN d.ganador_equipo_id = d.home_equipo_id THEN d.home_team
             WHEN d.ganador_equipo_id = d.away_equipo_id THEN d.away_team
             ELSE 'Empate' END AS ganador
    FROM DimPartido d
    WHERE d.fue_a_penales = 1
    ORDER BY d.start_timestamp;

    -- Equipos sin traducción ES (para completar el diccionario si aparece un equipo nuevo)
    SELECT nombre_en FROM DimEquipo WHERE nombre_es IS NULL;
END;
GO

PRINT 'Procedimientos creados: sp_PoblarMomentum, sp_PoblarPausaMetricas,';
PRINT 'sp_PoblarResumenPartido, sp_PoblarResumenTorneo, sp_ActualizarTodo, sp_ValidarDW.';
GO

