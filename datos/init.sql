-- =====================================================================
-- TAREA 7 · Programacion del lado del servidor: creacion de vistas
-- IoT Analytics Dashboard (NexoDev Solutions) · PostgreSQL 16
-- Las vistas simplifican las consultas de Grafana y limitan lo que cada
-- usuario puede ver o modificar. Nadie (salvo el administrador) toca las tablas.
-- =====================================================================

-- ------------------------------ TABLAS ------------------------------
CREATE TABLE dispositivos (
    id        SERIAL PRIMARY KEY,
    codigo    VARCHAR(20) NOT NULL UNIQUE,
    nombre    VARCHAR(60) NOT NULL,
    ubicacion VARCHAR(60) NOT NULL,
    estado    VARCHAR(15) NOT NULL DEFAULT 'activo'
              CHECK (estado IN ('activo', 'mantenimiento', 'inactivo'))
);

CREATE TABLE sensores (
    id             SERIAL PRIMARY KEY,
    dispositivo_id INT NOT NULL REFERENCES dispositivos(id),
    codigo         VARCHAR(20) NOT NULL UNIQUE,
    tipo           VARCHAR(20) NOT NULL CHECK (tipo IN ('temperatura', 'vibracion', 'energia')),
    unidad         VARCHAR(10) NOT NULL,
    umbral_max     NUMERIC(10,2) NOT NULL
);

CREATE TABLE lecturas (
    id        BIGSERIAL PRIMARY KEY,
    sensor_id INT NOT NULL REFERENCES sensores(id),
    valor     NUMERIC(10,2) NOT NULL,
    medido_en TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- Indices que aprovechan las vistas: ultima lectura por sensor y filtros por fecha
CREATE INDEX idx_lecturas_sensor_fecha ON lecturas (sensor_id, medido_en DESC);
CREATE INDEX idx_lecturas_fecha        ON lecturas (medido_en DESC);

CREATE TABLE alertas (
    id         SERIAL PRIMARY KEY,
    lectura_id BIGINT NOT NULL REFERENCES lecturas(id),
    sensor_id  INT NOT NULL REFERENCES sensores(id),
    severidad  VARCHAR(12) NOT NULL CHECK (severidad IN ('advertencia', 'critica')),
    valor      NUMERIC(10,2) NOT NULL,
    umbral     NUMERIC(10,2) NOT NULL,
    creada_en  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    atendida   BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE INDEX idx_alertas_pendientes ON alertas (creada_en DESC) WHERE NOT atendida;

-- Alerta automatica: advertencia si supera el umbral, critica si lo supera en mas de 20 %
CREATE FUNCTION generar_alerta() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_umbral NUMERIC;
BEGIN
    SELECT umbral_max INTO v_umbral FROM sensores WHERE id = NEW.sensor_id;
    IF NEW.valor > v_umbral THEN
        INSERT INTO alertas (lectura_id, sensor_id, severidad, valor, umbral, creada_en)
        VALUES (NEW.id, NEW.sensor_id,
                CASE WHEN NEW.valor > v_umbral * 1.2 THEN 'critica' ELSE 'advertencia' END,
                NEW.valor, v_umbral, NEW.medido_en);
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_generar_alerta AFTER INSERT ON lecturas
FOR EACH ROW EXECUTE FUNCTION generar_alerta();

-- ------------------------------ VISTAS ------------------------------

-- V1. Ultima lectura de cada sensor y su situacion.
-- LATERAL + LIMIT 1 usa el indice (sensor_id, medido_en DESC): lee 1 fila por sensor.
-- security_barrier: los filtros del usuario no se evaluan antes que los de la vista.
CREATE VIEW v_estado_sensores WITH (security_barrier) AS
SELECT s.codigo     AS sensor,
       s.tipo,
       s.unidad,
       d.codigo     AS dispositivo,
       d.ubicacion,
       d.estado     AS estado_dispositivo,
       s.umbral_max AS umbral,
       u.valor,
       u.medido_en,
       ROUND(100 * u.valor / s.umbral_max, 1) AS pct_umbral,
       CASE WHEN u.valor IS NULL                THEN 'sin datos'
            WHEN u.valor > s.umbral_max * 1.2  THEN 'critica'
            WHEN u.valor > s.umbral_max        THEN 'advertencia'
            ELSE 'normal' END                AS situacion
FROM sensores s
JOIN dispositivos d ON d.id = s.dispositivo_id
LEFT JOIN LATERAL (
    SELECT l.valor, l.medido_en
    FROM lecturas l
    WHERE l.sensor_id = s.id
    ORDER BY l.medido_en DESC
    LIMIT 1
) u ON TRUE;

-- V2. Tendencia por minuto de las ultimas 24 h (graficas de Grafana).
-- El filtro de 24 h va DENTRO de la vista para que use idx_lecturas_fecha.
CREATE VIEW v_tendencia_24h AS
SELECT date_trunc('minute', l.medido_en) AS minuto,
       s.codigo  AS sensor,
       s.tipo,
       d.codigo  AS dispositivo,
       COUNT(*)              AS lecturas,
       ROUND(AVG(l.valor), 2) AS promedio,
       MIN(l.valor)          AS minimo,
       MAX(l.valor)          AS maximo
FROM lecturas l
JOIN sensores s     ON s.id = l.sensor_id
JOIN dispositivos d ON d.id = s.dispositivo_id
WHERE l.medido_en > NOW() - INTERVAL '24 hours'
GROUP BY 1, 2, 3, 4;

-- V3. Alertas pendientes con contexto, ordenadas por prioridad.
CREATE VIEW v_alertas_pendientes AS
SELECT a.id,
       a.creada_en,
       s.codigo    AS sensor,
       s.tipo,
       d.codigo    AS dispositivo,
       d.ubicacion,
       a.severidad,
       a.valor,
       a.umbral,
       ROUND(100 * (a.valor - a.umbral) / a.umbral, 1)              AS pct_exceso,
       ROUND(EXTRACT(EPOCH FROM NOW() - a.creada_en) / 60, 1)       AS minutos_abierta
FROM alertas a
JOIN sensores s     ON s.id = a.sensor_id
JOIN dispositivos d ON d.id = s.dispositivo_id
WHERE NOT a.atendida
ORDER BY (a.severidad = 'critica') DESC, a.creada_en DESC;

-- V4. Salud de cada dispositivo (resumen para el tablero).
CREATE VIEW v_salud_dispositivos AS
SELECT d.codigo AS dispositivo,
       d.nombre,
       d.ubicacion,
       d.estado,
       COUNT(DISTINCT s.id)                                            AS sensores,
       (SELECT COUNT(*) FROM lecturas l JOIN sensores s2 ON s2.id = l.sensor_id
         WHERE s2.dispositivo_id = d.id
           AND l.medido_en > NOW() - INTERVAL '1 hour')               AS lecturas_ultima_hora,
       COUNT(a.id)                                                     AS alertas_pendientes,
       COUNT(a.id) FILTER (WHERE a.severidad = 'critica')              AS alertas_criticas,
       CASE WHEN d.estado <> 'activo'                                  THEN d.estado
            WHEN COUNT(a.id) FILTER (WHERE a.severidad = 'critica') > 0 THEN 'en riesgo'
            WHEN COUNT(a.id) > 0                                       THEN 'vigilar'
            ELSE 'ok' END                                              AS salud
FROM dispositivos d
JOIN sensores s     ON s.dispositivo_id = d.id
LEFT JOIN alertas a ON a.sensor_id = s.id AND NOT a.atendida
GROUP BY d.id, d.codigo, d.nombre, d.ubicacion, d.estado;

-- V5. Vista materializada: estadisticas por hora (historico).
-- Guarda el resultado; consultar 3 dias de historia no recorre toda la tabla de lecturas.
CREATE MATERIALIZED VIEW mv_resumen_hora AS
SELECT date_trunc('hour', l.medido_en) AS hora,
       s.codigo  AS sensor,
       s.tipo,
       COUNT(*)                AS lecturas,
       ROUND(AVG(l.valor), 2)   AS promedio,
       MIN(l.valor)             AS minimo,
       MAX(l.valor)             AS maximo,
       ROUND(percentile_cont(0.95) WITHIN GROUP (ORDER BY l.valor)::numeric, 2) AS p95,
       COUNT(*) FILTER (WHERE l.valor > s.umbral_max) AS lecturas_sobre_umbral
FROM lecturas l
JOIN sensores s ON s.id = l.sensor_id
GROUP BY 1, 2, 3
WITH NO DATA;
-- Indice unico: permite REFRESH ... CONCURRENTLY (Grafana puede leer mientras se actualiza)
CREATE UNIQUE INDEX ux_resumen_hora ON mv_resumen_hora (hora, sensor);

-- El consumidor refresca la vista sin ser su dueno: funcion SECURITY DEFINER
CREATE FUNCTION refrescar_resumen() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_resumen_hora;
END $$;

-- V6. Vista actualizable para operadores de planta.
-- Solo expone dispositivos en operacion y solo deja cambiar el estado;
-- WITH CHECK OPTION impide dar de baja (inactivo) desde la vista.
CREATE VIEW v_operacion_dispositivos AS
SELECT codigo, nombre, ubicacion, estado
FROM dispositivos
WHERE estado IN ('activo', 'mantenimiento')
WITH CASCADED CHECK OPTION;

-- ------------------------- USUARIOS Y PERMISOS -------------------------
-- Grafana: solo lectura y SOLO sobre las vistas (no ve las tablas)
CREATE ROLE grafana_lector LOGIN PASSWORD 'grafana123';
GRANT SELECT ON v_estado_sensores, v_tendencia_24h, v_alertas_pendientes,
                v_salud_dispositivos, mv_resumen_hora TO grafana_lector;

-- Consumidor de RabbitMQ: inserta lecturas y refresca el resumen
CREATE ROLE consumidor_iot LOGIN PASSWORD 'consumidor123';
GRANT SELECT (id, codigo) ON sensores TO consumidor_iot;
GRANT INSERT ON lecturas TO consumidor_iot;
GRANT USAGE ON SEQUENCE lecturas_id_seq TO consumidor_iot;
REVOKE EXECUTE ON FUNCTION refrescar_resumen() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION refrescar_resumen() TO consumidor_iot;

-- Operador de planta: consulta y cambia el estado solo a traves de V6
CREATE ROLE operador_planta LOGIN PASSWORD 'operador123';
GRANT SELECT, UPDATE (estado) ON v_operacion_dispositivos TO operador_planta;

-- --------------------------- DATOS INICIALES ---------------------------
INSERT INTO dispositivos (codigo, nombre, ubicacion) VALUES
('PRE-03', 'Prensa hidraulica 3', 'Linea 1'),
('TOR-01', 'Torno CNC 1',        'Linea 2'),
('EMB-02', 'Embotelladora 2',    'Linea 3');

INSERT INTO sensores (dispositivo_id, codigo, tipo, unidad, umbral_max) VALUES
(1, 'PRE03-TEMP', 'temperatura', '°C',   85.00),
(1, 'PRE03-VIB',  'vibracion',   'mm/s',  7.00),
(1, 'PRE03-ENE',  'energia',     'kWh',  30.00),
(2, 'TOR01-TEMP', 'temperatura', '°C',   80.00),
(2, 'TOR01-VIB',  'vibracion',   'mm/s',  6.00),
(2, 'TOR01-ENE',  'energia',     'kWh',  25.00),
(3, 'EMB02-TEMP', 'temperatura', '°C',   75.00),
(3, 'EMB02-VIB',  'vibracion',   'mm/s',  5.00),
(3, 'EMB02-ENE',  'energia',     'kWh',  20.00);

-- Historico de 3 dias (una lectura cada 30 s por sensor) para probar el rendimiento
SELECT setseed(0.7);
INSERT INTO lecturas (sensor_id, valor, medido_en)
SELECT s.id,
       ROUND((CASE WHEN random() < 0.003 THEN s.umbral_max * (1.05 + random() * 0.3)
                   ELSE s.umbral_max * (0.80 + (random() - 0.5) * 0.12) END)::numeric, 2),
       t
FROM sensores s
CROSS JOIN generate_series(NOW() - INTERVAL '3 days', NOW() - INTERVAL '1 minute',
                           INTERVAL '30 seconds') AS t;
UPDATE alertas SET atendida = TRUE;   -- las alertas historicas ya fueron atendidas

REFRESH MATERIALIZED VIEW mv_resumen_hora;
ANALYZE;
