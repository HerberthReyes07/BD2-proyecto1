# `carga/` — Generación de Carga y Dataset de Prueba (Fase 6)

Contiene el dataset de prueba de la plataforma "Data Bug's" y los dos generadores de carga usados para validar el comportamiento del balanceo, el failover y la resiliencia de la arquitectura bajo tráfico controlado (Fase 6 del enunciado).

## Contenido

| Ruta | Rol |
|---|---|
| `dataset/01-esquema.sql` | Esquema (`databugs.*`) y datos semilla: clientes, productos, transacciones y bitácora de pruebas. |
| `k6/Dockerfile` | Construye un binario propio de k6 con la extensión `xk6-sql` (k6 no habla SQL de fábrica). |
| `k6/carga-mixta.js` | Escenarios de carga mixta lectura+escritura contra el proxy (Fase 6, escenarios 1 y 2). |
| `k6/carga-lectura.js` | Carga de solo lectura contra nodo3 en contingencia (Fase 6, escenario 3 / Fase 5). |
| `pgbench/escritura.sql`, `pgbench/lectura.sql` | Scripts SQL usados por `pgbench` como respaldo sin compilar nada. |
| `pgbench/run-carga.sh` | Orquesta los 3 escenarios (`escritura`, `lectura`, `mixta`) con `pgbench`. |
| `resultados/` | Salidas de las corridas, con marca de tiempo en el nombre de archivo. |

## Dataset de prueba

Modela la plataforma de "Data Bug's" del enunciado: clientes que generan transacciones sobre productos.

| Tabla | Registros | Propósito |
|---|---|---|
| `databugs.clientes` | 1.000 | Entidad base |
| `databugs.productos` | 200 | Entidad base |
| `databugs.transacciones` | 20.000 semilla + las que inserte la carga | Tabla caliente de la prueba |
| `databugs.bitacora_pruebas` | — | Cada `INSERT` registra `inet_server_addr()` y `clock_timestamp()`, para calcular el **RPO** comparando lo escrito antes de una caída contra lo que sobrevivió |

Se carga **una sola vez**, a través del puerto `5000` del proxy (escritura), por lo que aterriza en el líder y se replica a nodo2 (síncrono) y nodo3 (asíncrono):

```bash
set -a && source .env && set +a
PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5000 -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f carga/dataset/01-esquema.sql
```

## Generadores de carga

Ambos apuntan siempre al **proxy** (`5000` escritura, `5001` lectura), nunca directo a un nodo: apuntar directo a un nodo mediría la base de datos, no la arquitectura completa (balanceo + failover transparentes).

### k6 + xk6-sql (principal)

Compilado con `github.com/grafana/xk6-sql` y `xk6-sql-driver-postgres` (requiere Go 1.26 para el build). Exporta métricas (`escritura_duracion`, `lectura_duracion`, `operaciones_ok`, `operaciones_error`) a Prometheus vía remote-write, así la latencia aparece junto al estado del clúster en Grafana (ver [`monitoreo/README.md`](../monitoreo/README.md)). No define `thresholds` que aborten la corrida: durante un failover **deben** fallar operaciones — esa ventana de error es la evidencia que se quiere medir.

```bash
docker build -t bd2-k6-sql ./carga/k6

docker run --rm --network host -v "$PWD/carga/k6:/scripts:ro" \
  -e PROXY_HOST=localhost -e PGPASS=$SUPERUSER_PASSWORD -e DURACION=3m \
  -e K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write \
  -e K6_PROMETHEUS_RW_TREND_STATS='p(95),p(99),avg,max' \
  bd2-k6-sql run -o experimental-prometheus-rw /scripts/carga-mixta.js
```

Variables de entorno aceptadas: `PROXY_HOST`, `PUERTO_WRITE` (5000), `PUERTO_READ` (5001), `PGPASS`, `DURACION`, `VUS_ESCRITURA` (5), `VUS_LECTURA` (10).

### pgbench (respaldo)

Viene dentro de la imagen de Postgres que ya usa el proyecto: cero instalación. Da los números duros de TPS y latencia si el build de k6 falla en alguna máquina.

```bash
./carga/pgbench/run-carga.sh mixta 240 10   # modo | segundos | clientes
```

Variables de entorno opcionales: `PGHOST_PROXY`, `PUERTO_WRITE`, `PUERTO_READ`, `SUPERUSER_PASSWORD` (si no se pasan, se toman del `.env` de la raíz).

## Resultados

Cada corrida de `run-carga.sh` guarda un archivo de texto en `resultados/<timestamp>_<escenario>.txt` con inicio, fin, host/puerto destino y la salida cruda de `pgbench`. Las métricas de k6 (iteraciones, operaciones ok/fallidas, latencias p95/p99) se consultan en el resumen de consola y en el dashboard *BD2 — Carga y fallos* de Grafana.

## Notas de diseño

- La carga se genera siempre desde la máquina de nodo3 contra **su propio HAProxy local**: si se apuntara al HAProxy de nodo1 y luego se apagara nodo1, se perdería el generador de carga junto con el nodo, cortando la prueba en vez de demostrar el failover.
- `carga-mixta.js` y `carga-lectura.js` cuentan errores como métrica en vez de abortar, y loguean los primeros 5 para diagnosticar rápido (contraseña vacía, tabla inexistente) sin inundar la consola.
