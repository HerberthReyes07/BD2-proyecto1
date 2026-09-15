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

## Paso 2 — Cuando el grupo esté listo en Tailscale

⚠️ **Orden importante:** a diferencia de la simulación local (donde el `docker-compose.local-sim.yml` ya fuerza automáticamente que Nodo 1 arranque primero y se confirme como líder antes de que Nodo 2/3 inicien), en modo distribuido **cada host es un `docker compose` independiente** — Compose no puede coordinar el orden entre máquinas distintas. Si los 3 arrancan a la vez, cualquiera de los 3 podría ganar la carrera por ser el primer líder, incluso Nodo 3, que se supone nunca debería serlo.

Por eso el orden debe coordinarse manualmente:

1. **Solo quien tenga Nodo 1** copia `.env.example` a `.env`, lo llena, y corre:
   ```bash
   docker compose --profile nodo-bd up -d --build
   ```
2. Espera y confirma que Nodo 1 ya es líder:
   ```bash
   curl http://localhost:8008/leader
   ```
   Debe responder `200 OK` (vacío está bien, solo importa el código de estado). Si tarda, revisa `docker compose logs patroni`.
3. **Recién entonces** avisa al grupo (canal de Discord/WhatsApp) que ya pueden levantar los suyos. Nodo 2 y Nodo 3 corren el mismo comando del paso 1.
4. Verificar desde cualquier nodo:
   ```bash
   docker compose exec patroni patronictl list
   ```
   Confirma que Nodo 1 aparece como `Leader`, Nodo 2 como `Sync Standby`, y Nodo 3 como `Replica` (no `Leader`).

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