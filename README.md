# IoT Analytics Dashboard · Vistas en PostgreSQL (Tarea 7)

NexoDev Solutions · Programación de Base de Datos (TESE) · Luis Gael Monterrubio López

## Documentación

📄 [Abrir la documentación de la Tarea 7 (PDF)](docs/Documentacion_Tarea7.pdf)

Vistas en PostgreSQL 16 que simplifican las consultas del tablero de Grafana y limitan lo que cada usuario puede ver o modificar. Las lecturas llegan en tiempo real por RabbitMQ.

```
Simulador ──► RabbitMQ ──► Consumidor ──► PostgreSQL (tablas + vistas) ◄── Grafana
            (red-mensajes)            (red-datos, SSL)        solo lee vistas
```

## Vistas

| Vista | Para qué |
|---|---|
| `v_estado_sensores` | Última lectura de cada sensor y su situación (LATERAL + índice, `security_barrier`) |
| `v_tendencia_24h` | Promedio, mínimo y máximo por minuto de las últimas 24 h (gráficas) |
| `v_alertas_pendientes` | Alertas sin atender con % de exceso y minutos abierta |
| `v_salud_dispositivos` | Resumen por dispositivo: lecturas, alertas y salud |
| `mv_resumen_hora` | Vista materializada: estadísticas por hora (promedio, p95) con `REFRESH CONCURRENTLY` |
| `v_operacion_dispositivos` | Vista actualizable con `WITH CHECK OPTION` para operadores |

## Usuarios

| Usuario | Permisos |
|---|---|
| `grafana_lector` | `SELECT` solo sobre las vistas (no puede leer tablas) |
| `consumidor_iot` | Insertar lecturas y ejecutar `refrescar_resumen()` |
| `operador_planta` | Cambiar el estado de un dispositivo solo por `v_operacion_dispositivos` |

## Levantar

```bash
docker compose up -d --build
```

- Grafana: http://localhost:3007 (admin / admin123)
- RabbitMQ: http://localhost:15677 (iot / iot123)

Pruebas de rendimiento:

```bash
docker exec -i vistas-datos psql -U postgres -d iotanalytics < datos/pruebas.sql
```
