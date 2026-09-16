# base/ — Nodo de datos (Postgres + Patroni + etcd)

Contiene la imagen y configuración compartida del clúster de datos. Los `docker-compose.yml` que realmente se ejecutan viven en la **raíz del repo**, no aquí — esta carpeta solo tiene los `Dockerfile` y el `bootstrap.yml` que esos compose referencian.

## Archivos

- `Dockerfile` — imagen del nodo (Postgres 16 + Patroni instalado vía pip).
- `Dockerfile.etcd` — imagen de etcd, construida desde el binario oficial de GitHub Releases.
- `bootstrap.yml.template` — configuración compartida (igual para los 3 nodos): reglas de `initdb`, `pg_hba`, config dinámica inicial (`synchronous_mode: true`), y los tags `nofailover`/`nosync` como placeholders (`${NOFAILOVER}`, `${NOSYNC}`).
- `entrypoint.sh` — al arrancar el contenedor, sustituye esos placeholders por los valores reales de ESE nodo (variables `NOFAILOVER`/`NOSYNC`, sin prefijo `PATRONI_`) y genera `/tmp/bootstrap.yml`, que es el que Patroni realmente usa. Esto es necesario porque Patroni **no** soporta configurar `tags` vía variables `PATRONI_TAGS_*` sueltas (confirmado revisando su código fuente) — solo funciona si está directo en el archivo YAML.

## Paso 1 — Validar localmente (en tu propia laptop)

Desde la **raíz** del repo:

```bash
docker compose -f docker-compose.local-sim.yml up -d --build
```

Espera ~40-60 segundos y revisa el estado:

```bash
docker compose -f docker-compose.local-sim.yml exec patroni-nodo1 patronictl list
```

Deberías ver un `Leader` y dos `Replica`, todos en `running`.

**Prueba de failover local:**

```bash
docker compose -f docker-compose.local-sim.yml stop patroni-nodo1
docker compose -f docker-compose.local-sim.yml exec patroni-nodo2 patronictl list
```

Cuando termines:

```bash
docker compose -f docker-compose.local-sim.yml down -v
```

## Paso 2 — Bootstrap distribuido (cuando el grupo esté listo en Tailscale)

⚠️ **Orden importante:** en modo distribuido **cada host es un `docker compose` independiente** — Compose no puede coordinar el orden entre máquinas distintas. El orden correcto tiene **dos reglas de oro**:

1. **etcd se levanta PRIMERO en TODOS los nodos**, y recién cuando el clúster etcd esté sano se levanta Patroni. Patroni *depende* de etcd, no al revés.
2. **Antes de levantar Patroni, se VERIFICA que etcd subió su `cluster version`**. Si no, Patroni usa el prefijo de API equivocado y queda para siempre en "waiting on etcd" (ver [Troubleshooting](#troubleshooting)).

### Fase 0 — Pre-flight en cada nodo (todos a la vez)

1. `git pull` y copiar `.env.example` a `.env` con tus valores (IPs exactas de `tailscale ip -4`).
2. Verificar que nada ocupe los puertos del clúster:
   ```bash
   ss -lntp | grep -E '5432|2379|2380|8008'
   ```
   Si **algo escucha en 5432** suele ser el Postgres nativo del sistema (PostgreSQL 17 en Debian/Ubuntu):
   ```bash
   systemctl stop postgresql@17-main && systemctl disable postgresql@17-main
   ```
   ⚠️ Sin esto, Patroni no puede arrancar su postgres y todo queda en `stopped`.

### Fase 1 — Levantar etcd (en TODOS los nodos, a la vez)

Cada quien, con su `.env`:
```bash
docker compose --profile nodo-bd up -d etcd
```

### Fase 2 — Checkpoint obligatorio: etcd debe estar sano ANTES de Patroni

**No se avanza a Patroni si esto no pasa.** En CADA nodo:

1. La versión del clúster debe ser 3.3+ (idealmente 3.5.x):
   ```bash
   curl -s http://localhost:2379/version
   # esperado: {"etcdserver":"3.5.17","etcdcluster":"3.5.x"}
   # si dice "etcdcluster":"3.0.0", un miembro no se unió todavía -> NO avanzar.
   ```
2. Los 3 miembros deben tener sus client URLs **pobladas** (la 4ta columna no puede estar vacía):
   ```bash
   docker compose exec etcd etcdctl member list
   ```
3. Confirmar la subida de versión en los logs:
   ```bash
   docker compose logs etcd | grep "cluster version"
   # esperado: "updated cluster version from 3.0 to 3.5"
   ```

### Fase 3 — Levantar Patroni (orden coordinado por el grupo)

La carrera por el primer líder existe: en modo distribuido, si los 3 levantan Patroni a la vez, cualquiera podría ganar (incluso Nodo 3). Coordinarse:

1. **Nodo 1** levanta Patroni y se confirma líder:
   ```bash
   docker compose --profile nodo-bd up -d patroni
   curl -s -o /dev/null -w '%{http_code}' http://localhost:8008/leader   # -> 200
   ```
2. **Recién entonces** el grupo avisa en Discord/WhatsApp que Nodo 2 y Nodo 3 pueden levantar los suyos (mismo comando).
3. Verificación final desde cualquier nodo:
   ```bash
   docker compose exec patroni patronictl list
   ```
   Confirma: Nodo 1 `Leader`, Nodo 2 `Sync Standby`, Nodo 3 `Replica` (nunca `Leader`).

## Probar solo con 2 nodos (sin nodo3)

Si nodo3 físico no está disponible, usa el override `docker-compose.2nodes.yml` (en la **raíz** del repo). Arma el etcd como clúster de **2 miembros** (quorum 2/2 completo) para que la versión suba y Patroni funcione con el prefijo `/v3`:

```bash
docker compose --profile nodo-bd \
  -f docker-compose.yml -f docker-compose.2nodes.yml up -d etcd
```

⚠️ Los 2 nodos deben usar el **mismo** override (mismos valores en su `.env`). Y ojo: con 2 miembros el quorum es 2/2 — si uno cae, etcd pierde quorum. Es para validar replicación/failover, no para demostrar alta disponibilidad real.

## Troubleshooting

### `Detected Etcd version 3.0.0 is lower than 3.1.0` + `AttributeError: 'int' object has no attribute 'get'`

**Síntoma:** Patroni nunca sale de "waiting on etcd", `/leader` no responde 200 y en los logs de `patroni` aparece ese error con `...:2379/v3alpha: ...`.

**Causa raíz (por diseño, no es error de configuración):** un clúster etcd nuevo arranca reportando `etcdcluster: 3.0.0` y solo sube su versión cuando **todos** los miembros del `ETCD_INITIAL_CLUSTER` se unen y negocian. Si un miembro está registrado en el roster pero **nunca se unió** (por ejemplo nodo3 apagado), la versión se queda en `3.0.0` para siempre. Patroni lee esa versión y decide usar el prefijo de API **`/v3alpha`** — pero etcd 3.5 **ya no sirve** `/v3alpha` (solo `/v3/...`), así que la consulta del member list devuelve algo inesperado y revienta al parsearlo.

**Cómo detectarlo:** `etcdctl member list` muestra al miembro ausente como `started` pero con su **client URL vacía** (4ta columna):

```
5357ad57d3ee0876, started, nodo3, http://100.126.127.120:2380, , false
```

**Solución:** que ese miembro levante su etcd y se una (reunión general), o quitar el miembro ausente del `ETCD_INITIAL_CLUSTER` con el override `docker-compose.2nodes.yml` para las pruebas de 2 nodos. En ambos casos, verificar el checkpoint de la Fase 2 antes de levantar Patroni.

## Replicación síncrona/asíncrona y exclusión de failover

Resuelto de forma declarativa vía `bootstrap.yml.template` + `entrypoint.sh`, **no** requiere `patronictl edit-config` manual:

- La plantilla activa `synchronous_mode: true` globalmente (se siembra en etcd la primera vez que el clúster nace).
- El `.env` de Nodo 3 tiene `NOSYNC=true` y `NOFAILOVER=true` — el `entrypoint.sh` los escribe como tags reales en el archivo de config al arrancar, excluyendo a Nodo 3 de ser candidato síncrono y de ser promovido en un failover.
- Verifica que un nodo registró bien sus tags con: `curl http://localhost:8008/patroni` (debe incluir una clave `"tags"` con `nofailover`/`nosync`).

⚠️ Esto solo aplica al nacer el clúster por primera vez. Si alguna vez necesitan cambiarlo con el clúster ya corriendo, ahí sí hace falta `patronictl edit-config`.

## Notas

- Verifica los nombres exactos de las variables `PATRONI_*` contra la documentación oficial (ENVIRONMENT.rst del repo de Patroni) antes de la sesión de integración.
- `network_mode: host` en `docker-compose.yml` asume Linux nativo o WSL2. Si alguien usa Docker Desktop en Mac, avisar para ajustar a bridge + puertos publicados atados a la IP de Tailscale.
- Si `Dockerfile.etcd` falla al construir porque `ETCD_VERSION` ya no existe, revisa versiones en `github.com/etcd-io/etcd/releases` y reconstruye con `--build-arg ETCD_VERSION=vX.Y.Z`.