# `base/` — Capa de Datos (PostgreSQL + Patroni + etcd)

Contiene la imagen y configuración del nodo de base de datos: PostgreSQL 16 gestionado por Patroni, y el clúster de consenso etcd que decide automáticamente quién es el líder. Estos tres componentes corren en **los tres nodos** de la arquitectura (nodo1, nodo2, nodo3), de forma idéntica y parametrizada por variables de entorno.

Los `docker-compose*.yml` que realmente se ejecutan viven en la raíz del repositorio; esta carpeta solo contiene los `Dockerfile` y las plantillas de configuración que esos compose referencian.

## Contenido

| Archivo | Rol |
|---|---|
| `Dockerfile` | Imagen del nodo: `postgres:16` + Patroni instalado vía `pip install patroni[etcd3]` + `pg_rewind`. |
| `Dockerfile.etcd` | Imagen de etcd 3.5.17, compilada desde el binario oficial publicado en GitHub Releases (no depende de una imagen de terceros). |
| `bootstrap.yml.template` | Configuración compartida por los 3 nodos: parámetros del DCS (`ttl`, `loop_wait`, `synchronous_mode`), reglas de `initdb`/`pg_hba`, y los tags `nofailover`/`nosync` como placeholders. |
| `entrypoint.sh` | Sustituye esos placeholders (`${NOFAILOVER}`, `${NOSYNC}`) por los valores reales de ESE nodo vía `envsubst`, genera `/tmp/bootstrap.yml`, y arranca Patroni con ese archivo. |

## Cómo funciona

### etcd — consenso y elección de líder

Cada nodo corre su propio contenedor etcd, formando un clúster de 3 miembros que implementa el algoritmo **Raft**. etcd guarda el estado de la verdad del clúster (quién tiene el *leader lock* actualmente) y solo toma decisiones por mayoría:

```
Quorum = ⌊N/2⌋ + 1 = ⌊3/2⌋ + 1 = 2 votos
```

Si cae 1 nodo, quedan 2 vivos → hay quorum → el clúster sigue operando. Si caen 2, queda 1 vivo → se pierde quorum → no se pueden confirmar nuevas elecciones de líder (evita split-brain).

Puertos: `2379` (clientes — Patroni consulta y renueva aquí su liderazgo) y `2380` (comunicación entre pares de etcd, heartbeats Raft).

### Patroni — orquestación de PostgreSQL

PostgreSQL nativo no sabe auto-promoverse si el primario muere. Patroni (demonio en Python) resuelve eso: arranca PostgreSQL, revisa etcd cada `loop_wait: 10s`, renueva el candado de líder (`ttl: 30s`), y si el líder deja de renovarlo, negocia con los otros Patroni quién asume. Si un nodo caído vuelve, usa `pg_rewind` para resincronizarlo sin rehacer la base desde cero (requiere `data-checksums`, activado en el `initdb`).

Expone una API REST en el puerto `8008`:

- `GET /primary` → `200 OK` solo si el nodo es el líder actual (`503` si no).
- `GET /replica` → `200 OK` solo si el nodo es una réplica funcional (`503` si no).
- `GET /metrics` → métricas nativas en formato Prometheus (rol, timeline, posición de WAL).

Esta API es el puente que consume HAProxy (ver [`proxy/README.md`](../proxy/README.md)) y Prometheus (ver [`monitoreo/README.md`](../monitoreo/README.md)).

### Replicación y roles declarados vía tags

Resuelto de forma declarativa en `bootstrap.yml.template` + `entrypoint.sh`, sin necesidad de `patronictl edit-config` manual:

- `synchronous_mode: true` (global): activa replicación síncrona.
- El nodo con `NOSYNC=false` (nodo2) queda como candidato síncrono — el líder espera su confirmación en disco antes del commit (RPO = 0 frente a la caída del líder).
- El nodo con `NOFAILOVER=true` + `NOSYNC=true` (nodo3) queda excluido de ser candidato síncrono y de ser promovido en cualquier failover — solo lectura y contingencia.

⚠️ Esto solo aplica al **nacer** el clúster. Si se necesita cambiar con el clúster ya corriendo, hace falta `patronictl edit-config`. Verificar los tags de un nodo con `curl http://localhost:8008/patroni` (debe incluir la clave `"tags"`).

## Variables de entorno relevantes (`.env`)

| Variable | Uso |
|---|---|
| `NODE_NAME` | Nombre de este nodo en el clúster (`nodo1`/`nodo2`/`nodo3`). |
| `MY_TAILSCALE_IP` | IP de Tailscale de esta máquina; se usa como `advertise`/`connect_address`. |
| `IP_NODO1`, `IP_NODO2`, `IP_NODO3` | IPs de los 3 nodos, iguales en los 3 `.env`, arman `ETCD_INITIAL_CLUSTER` y `PATRONI_ETCD3_HOSTS`. |
| `NOFAILOVER`, `NOSYNC` | `true` solo en el `.env` de quien tenga nodo3. |
| `REPLICATION_PASSWORD`, `SUPERUSER_PASSWORD` | Credenciales compartidas, idénticas en los 3 `.env`; se siembran al nacer el clúster. |

## Operación

### Paso 1 — Validación local (un solo host)

```bash
docker compose -f docker-compose.local-sim.yml up -d --build
docker compose -f docker-compose.local-sim.yml exec patroni-nodo1 patronictl list
```

Debe verse un `Leader` y dos `Replica`, todos `running`. Prueba de failover local:

```bash
docker compose -f docker-compose.local-sim.yml stop patroni-nodo1
docker compose -f docker-compose.local-sim.yml exec patroni-nodo2 patronictl list
```

Limpieza: `docker compose -f docker-compose.local-sim.yml down -v`.

### Paso 2 — Bootstrap distribuido (Tailscale)

En modo distribuido cada host es un `docker compose` independiente — Compose no coordina el orden entre máquinas. Reglas:

1. **etcd primero, en los tres, a la vez:**
   ```bash
   docker compose --profile nodo-bd up -d etcd
   ```
2. **Checkpoint obligatorio antes de levantar Patroni** — en cada nodo:
   ```bash
   curl -s http://localhost:2379/version        # esperado: "etcdcluster":"3.5.x"
   docker compose exec etcd etcdctl member list # los 3 miembros con client URL poblada
   ```
   Si algún miembro nunca se unió, la versión se queda en `3.0.0` — no avanzar (ver Troubleshooting).
3. **Patroni, en orden coordinado:** nodo1 primero, confirmar que es líder, y solo entonces nodo2 y nodo3:
   ```bash
   docker compose --profile nodo-bd up -d patroni
   curl -s -o /dev/null -w '%{http_code}' http://localhost:8008/leader   # -> 200
   docker compose exec patroni patronictl list   # nodo1 Leader · nodo2 Sync Standby · nodo3 Replica
   ```

### Arranque rápido (clúster ya nacido)

Una vez que etcd ya tiene la `cluster version` en `3.5.x` (datos ya en los volúmenes), no hace falta la secuencia por fases:

```bash
docker compose --profile nodo-bd up -d     # etcd + patroni (+ proxy, ver proxy/README.md)
docker compose --profile nodo-bd ps
```

El orden local está garantizado por `depends_on: etcd: condition: service_healthy`.

### Prueba con 2 nodos (sin nodo3 físico)

```bash
docker compose --profile nodo-bd -f docker-compose.yml -f docker-compose.2nodes.yml up -d etcd
```

Arma un etcd de 2 miembros (quorum 2/2). Sirve para validar replicación/failover, **no** para demostrar alta disponibilidad real: si un nodo cae, se pierde el quorum.

### Pruebas de replicación y failover

```bash
export PGPASSWORD=$(grep SUPERUSER_PASSWORD .env | cut -d= -f2)
docker compose --profile nodo-bd exec patroni psql -U postgres -h localhost -c \
  "CREATE TABLE t1(id int); INSERT INTO t1 VALUES (1),(2);"
docker compose --profile nodo-bd exec patroni psql -U postgres -h localhost -c "SELECT * FROM t1;"

# Failover planificado
docker compose --profile nodo-bd exec patroni patronictl failover --candidate nodo2 --force

# Failover por caída
docker compose --profile nodo-bd stop patroni     # en el Leader
docker compose --profile nodo-bd exec patroni patronictl list   # desde cualquier otro nodo

# Reintegración
docker compose --profile nodo-bd up -d patroni    # en el nodo que se detuvo
```

## Troubleshooting

### `Detected Etcd version 3.0.0 is lower than 3.1.0` + `AttributeError: 'int' object has no attribute 'get'`

**Síntoma:** Patroni nunca sale de `waiting on etcd`, `/leader` no responde `200`.

**Causa raíz:** un clúster etcd nuevo arranca reportando `etcdcluster: 3.0.0` y solo sube de versión cuando **todos** los miembros del `ETCD_INITIAL_CLUSTER` se unen. Si uno nunca se une, la versión queda en `3.0.0` para siempre; Patroni lee esa versión y usa el prefijo `/v3alpha`, que etcd 3.5 ya no sirve (solo `/v3`), y la consulta revienta al parsear la respuesta.

**Detección:** `etcdctl member list` muestra al miembro ausente como `started` pero con su client URL **vacía** (4ta columna).

**Solución:** que ese miembro levante su etcd y se una, o usar `docker-compose.2nodes.yml` para pruebas de 2 nodos. En ambos casos, verificar el checkpoint de `/version` antes de levantar Patroni.

### Otros

- `network_mode: host` asume Linux nativo o WSL2. Con Docker Desktop en Mac/Windows, el engine corre en una VM y el nodo queda invisible para los demás — usar `docker context use default` o migrar a bridge con puertos publicados.
- Si `Dockerfile.etcd` falla al construir porque `ETCD_VERSION` ya no existe, revisar `github.com/etcd-io/etcd/releases` y reconstruir con `--build-arg ETCD_VERSION=vX.Y.Z`.
- Si el puerto `5432` ya está ocupado, suele ser el PostgreSQL nativo del sistema: `sudo systemctl disable --now postgresql@17-main` (ajustar versión).
