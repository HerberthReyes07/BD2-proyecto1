# `monitoreo/` — Observabilidad (Prometheus + Grafana) — Fase 7

Aporta la visibilidad en tiempo real que la arquitectura necesita para las Fases 6, 7 y 8 del enunciado: sin esto, la única forma de saber qué está pasando era entrar a cada máquina a correr `patronictl list`. Se centraliza en un único punto de recolección — la máquina de **nodo3** — porque es el único nodo que sobrevive a todos los escenarios de falla contemplados (Fases 3-5 tumban nodo1 y/o nodo2); si viviera en nodo1, se apagaría justo cuando hay que observar.

## Contenido

| Ruta | Rol |
|---|---|
| `prometheus/entrypoint.sh` | Genera `prometheus.yml` en cada arranque a partir de variables de entorno — el mismo stack sirve para la simulación local (nombres de contenedor) y el despliegue distribuido (IPs de Tailscale). |
| `grafana/provisioning/datasources/prometheus.yml` | Datasource de Prometheus aprovisionado (URL por variable de entorno). |
| `grafana/provisioning/dashboards/dashboards.yml` | Proveedor que carga los dashboards desde archivos JSON versionados en git. |
| `grafana/dashboards/01-cluster-estado.json` | Dashboard *BD2 — Estado del clúster*. |
| `grafana/dashboards/02-carga-fallos.json` | Dashboard *BD2 — Carga y fallos*. |

## Arquitectura de la capa

Prometheus scrapea cada 5s tres tipos de fuente, presentes en **cada uno de los 3 nodos**:

| Fuente | Puerto | Qué aporta |
|---|---|---|
| Patroni (nativo, sin exporter) | `8008/metrics` | Rol, estado de Postgres, timeline, posición de WAL (lag de replicación) |
| `node_exporter` | `9100` | CPU, memoria, disco del host |
| `postgres_exporter` | `9187` | Conexiones, transacciones, `pg_up` |

Cada serie se etiqueta con `nodo="nodo1|nodo2|nodo3"`, la etiqueta sobre la que se construyen **todos** los paneles de Grafana, permitiendo comparar los tres nodos lado a lado en una sola gráfica.

`node_exporter` y `postgres_exporter` corren en los tres nodos bajo el perfil `nodo-bd` (suben junto con el clúster) y también bajo `monitoreo-agente` (para reiniciarlos solos). El stack de recolección/visualización (Prometheus + Grafana) corre solo en nodo3, bajo el perfil `monitoreo`, exclusivo de esa máquina.

`postgres_exporter` apunta siempre al Postgres **local** de su nodo (`127.0.0.1:5432`), nunca al proxy: cada nodo debe reportar su propio estado. Si Patroni tiene su Postgres abajo, el exporter publica `pg_up=0`.

### Por qué no hace falta un exporter para el estado del clúster

Patroni 4.1.5 publica su propio endpoint `/metrics` sobre el mismo puerto REST `8008` que ya usa HAProxy para sus health checks. De ahí salen las métricas más relevantes:

| Métrica | Qué mide |
|---|---|
| `patroni_postgres_running` | Estado del servicio de base de datos |
| `patroni_primary`, `patroni_replica`, `patroni_sync_standby` | Rol y disponibilidad de cada nodo |
| `patroni_xlog_location`, `patroni_xlog_replayed_location` | Latencia de replicación |
| `patroni_postgres_timeline` | Evidencia histórica de failovers |
| `patroni_cluster_unlocked` | Clúster sin líder (contingencia de Fase 5) |
| `patroni_dcs_last_seen` | Salud del consenso (etcd) |

> El líder se excluye de los paneles de lag: no replaya WAL, así que su `patroni_xlog_replayed_location` es 0 y mostraría un lag falso enorme. Los paneles filtran con `and (patroni_primary == 0)`.

## Dashboards

**`01-cluster-estado.json` — BD2 — Estado del clúster:** líder actual, nodos Patroni alcanzables, PostgreSQL corriendo, clúster sin líder, lag de replicación por nodo, rol de cada nodo, timeline de PostgreSQL, disponibilidad de targets, CPU, memoria, conexiones activas.

**`02-carga-fallos.json` — BD2 — Carga y fallos:** operaciones completadas/fallidas, throughput actual, VUs activos, líder actual, latencia de escritura/lectura, throughput y errores durante la falla, rol de cada nodo bajo carga, CPU bajo carga, lag de replicación bajo carga.

## Variables de entorno relevantes (`.env`)

| Variable | Uso |
|---|---|
| `IP_NODO1..3` | Usadas para construir los targets de Prometheus (`:8008`, `:9100`, `:9187`) hacia los 3 nodos. |
| `GRAFANA_USER`, `GRAFANA_PASSWORD` | Opcionales; por defecto `admin`/`admin`. |
| `SUPERUSER_PASSWORD` | Usada por `postgres_exporter` para conectarse al Postgres local. |

## Operación

### Simulación local (una sola máquina)

```bash
docker compose -f docker-compose.local-sim.yml \
               -f docker-compose.local-sim.proxy.yml \
               -f docker-compose.local-sim.monitoreo.yml up -d --build
```

Grafana: `http://localhost:3000` (admin/admin) · Prometheus: `http://localhost:9090`.

### Despliegue distribuido (solo nodo3)

Los agentes (`node-exporter`, `postgres-exporter`) ya suben en los tres nodos junto con `--profile nodo-bd`. Solo nodo3 levanta además el stack de observabilidad:

```bash
docker compose --profile monitoreo up -d
```

Verificación (los 9 targets deben estar `up`):

```bash
curl -s 'http://localhost:9090/api/v1/targets?state=any' | python3 -c \
  "import sys,json;[print(f\"{t['labels']['job']:<10} {t['labels'].get('nodo','-'):<7} {t['health']}\") for t in json.load(sys.stdin)['data']['activeTargets']]"
```

Grafana queda accesible desde cualquier máquina del equipo en `http://<IP_TAILSCALE_NODO3>:3000`.

Levantar todo de una sola vez en nodo3 (base de datos + observabilidad):

```bash
docker compose --profile nodo-bd --profile monitoreo up -d --build
```

## Limitación conocida

Al no existir una cuarta máquina física, el monitoreo vive en el mismo host que nodo3. Si esa máquina se apaga, se pierden simultáneamente el nodo de contingencia **y** toda la observabilidad — un punto único de fallo residual que se documenta explícitamente en el [README.md](../README.md) principal. Además, Prometheus, Grafana y los generadores de carga (ver [`carga/README.md`](../carga/README.md)) consumen CPU en esa misma máquina, introduciendo algo de ruido en las métricas de nodo3 durante las pruebas de carga.
