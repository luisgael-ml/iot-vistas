-- Pruebas de rendimiento: misma informacion con y sin vista materializada
\timing on
\echo '--- Consulta directa sobre lecturas (3 dias, agrupado por hora) ---'
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT date_trunc('hour', l.medido_en) AS hora, s.tipo, ROUND(AVG(l.valor), 2)
FROM lecturas l JOIN sensores s ON s.id = l.sensor_id
GROUP BY 1, 2;

\echo '--- Misma informacion desde mv_resumen_hora ---'
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT hora, tipo, ROUND(AVG(promedio), 2)
FROM mv_resumen_hora
GROUP BY 1, 2;

\echo '--- v_estado_sensores: el LATERAL usa el indice (1 fila por sensor) ---'
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT * FROM v_estado_sensores;
