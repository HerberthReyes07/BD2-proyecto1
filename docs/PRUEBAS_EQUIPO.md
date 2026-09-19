# Guía de pruebas con el equipo — Proyecto 1 BD2, Grupo 5

> **Cómo usar este documento.** Es el libreto de la sesión de integración. Cada
> fase indica **quién ejecuta qué** y qué evidencia hay que capturar. Las fases
> siguen la numeración del enunciado.
>
> Reparto: **nodo1** = Capa A (datos) · **nodo2** = Capa B (proxy) ·
> **nodo3 + nodo4** = Capa C (monitoreo y carga).

---

## Fase 0 — Pre-vuelo (los tres, antes de arrancar nada)

### 0.1 Acordar las credenciales

`REPLICATION_PASSWORD` y `SUPERUSER_PASSWORD` deben ser **idénticas en los tres
`.env`**. Se siembran al nacer el clúster: cambiarlas después obliga a rehacerlo
con `down -v` en los tres. Definirlas **antes** de levantar.

### 0.2 Cada quien verifica su máquina

```bash
docker info --format '{{.OperatingSystem}}'
```

Debe decir la distro, **nunca** `Docker Desktop`. Con Docker Desktop,
`network_mode: host` es la red de una VM y el nodo queda invisible para los
demás. Si aparece, corregir con `docker context use default`.

```bash
ss -lntp | grep -E ':5432|:2379|:2380|:8008|:5000|:5001|:7000'
```

Debe estar todo libre. Si el 5432 está ocupado suele ser el PostgreSQL del
sistema: `sudo systemctl disable --now postgresql@17-main` (ajustar la versión).

### 0.3 Limpieza coordinada

**Los tres, en la misma ventana de tiempo:**

```bash
docker compose --profile nodo-bd down -v
```

Confirmar que no quedó nada:

```bash
docker ps -a | grep proyecto1; docker volume ls | grep proyecto1
```

> ⚠️ El `-v` es obligatorio. etcd guarda la membresía del clúster **dentro de su
> data dir**, no en las variables de entorno: un miembro inicializado creyendo
> que el clúster es de 2 nodos rechazará al tercero para siempre. Y si uno
> arranca con el volumen vacío mientras los otros ya formaron clúster, se
> re-bootstrapea y arrastra el estado de todos.

---

## Fase 1 — Levantar la arquitectura

### 1.1 Levantar todo, en los tres lo más simultáneo posible

```bash
docker compose --profile nodo-bd up -d --build
```

Ese único comando levanta los **4 contenedores** del nodo: `etcd`, `patroni`,
`haproxy` y `keepalived` (los dos últimos comparten el perfil `nodo-bd`).

**Ya no hace falta arrancar etcd por separado.** El healthcheck de etcd que tiene
el compose, combinado con `depends_on: service_healthy`, hace el escalonamiento
automáticamente: Patroni no arranca hasta que su etcd local responde sano, lo que
solo ocurre cuando el clúster alcanzó quórum. Eso evita que Patroni se conecte a
un DCS a medio formar.

> ⚠️ **La ventana es de ~60 segundos.** El healthcheck da `start_period: 10s` más
> 5 reintentos cada 10 s. Si uno de los tres tarda más que eso en levantar, los
> que ya arrancaron marcan su etcd como `unhealthy` y Compose aborta con
> `dependency failed to start: container etcd-1 is unhealthy`. No es un fallo de
> configuración: es que alguien llegó tarde. Se resuelve repitiendo el comando
> cuando los tres estén listos, o subiendo `retries` si se vuelve recurrente.

### 1.2 Verificar el clúster de etcd

Sigue valiendo la pena comprobarlo, ya no como puerta de paso sino como
**evidencia de la Fase 1** (el enunciado pide verificar la conectividad entre
componentes):

```bash
curl -s localhost:2379/version
```

Debe decir `"etcdcluster":"3.5.0"` en los tres. Un `3.0.0` persistente significa
que un miembro no se unió: la cluster version no sube hasta que etcd conoce la
versión de los tres.

```bash
docker compose exec etcd etcdctl member list -w table
```

Deben aparecer los 3 miembros con su client URL.

### 1.3 Verificar Patroni

```bash
docker compose exec patroni patronictl list
```

**Resultado esperado:** `nodo1` Leader · `nodo2` Sync Standby · `nodo3` Replica
con tags `nofailover` y `nosync`.

> El standby síncrono tarda un ciclo de `loop_wait` (~10-30 s) en aparecer. Si al
> inicio los dos salen como `Replica`, esperar antes de diagnosticar.

### 1.4 Verificar el proxy

Abrir `http://localhost:7000/` en cada máquina: `postgres_write_back` debe tener
solo al líder en verde, y `postgres_read_back` a las dos réplicas.

Si hiciera falta reiniciar solo la capa de proxy sin tocar la base de datos:

```bash
docker compose --profile proxy up -d
```

### 1.5 Monitoreo

**Los agentes de métricas ya vienen dentro del perfil `nodo-bd`**, así que el
comando del paso 1.1 los levanta solos en los tres nodos: `node-exporter`
(CPU/memoria/disco) y `postgres-exporter` (conexiones y estado de Postgres). No
hay un segundo compose que correr.

Cada quien puede confirmar que los suyos responden:

```bash
curl -s localhost:9100/metrics | head -3 && curl -s localhost:9187/metrics | grep '^pg_up'
```

**Solo nodo3** levanta además el stack de observabilidad, con su propio perfil:

```bash
docker compose --profile monitoreo up -d
```

Verificación desde nodo3 — los 9 targets deben estar `up`:

```bash
curl -s 'http://localhost:9090/api/v1/targets?state=any' | python3 -c "import sys,json;[print(f\"{t['labels']['job']:<10} {t['labels'].get('nodo','-'):<7} {t['health']}\") for t in json.load(sys.stdin)['data']['activeTargets']]"
```

Grafana queda en `http://<IP_TAILSCALE_NODO3>:3000` (admin/admin). Los demás lo
abren desde sus máquinas por Tailscale.

> Si nodo3 quiere levantar todo de una sola vez, base de datos y observabilidad:
> ```bash
> docker compose --profile nodo-bd --profile monitoreo up -d --build
> ```

**📸 Evidencia Fase 1:** `patronictl list` con los tres sanos, dashboard de
HAProxy en verde, dashboard *BD2 — Estado del clúster* con los tres nodos, y
salida de `tailscale status`.

### 1.6 Cargar el dataset — lo hace nodo3

```bash
set -a && source .env && set +a
PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5000 -U postgres -d postgres -v ON_ERROR_STOP=1 -f carga/dataset/01-esquema.sql
```

---

## Fase 2 — Replicación normal

Todo se ejecuta **a través del proxy**, no contra nodos directos.

**Insertar desde el líder (puerto 5000):**

```bash
PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5000 -U postgres -c "INSERT INTO databugs.bitacora_pruebas (fase, nota) VALUES ('fase2','insert inicial') RETURNING id, servidor, creado_en;"
```

**Verificar en las réplicas (puerto 5001, ejecutar varias veces):**

```bash
for i in 1 2 3 4; do PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5001 -U postgres -tAc "select inet_server_addr()||' -> '||count(*) from databugs.bitacora_pruebas;"; done
```

**Resultado esperado:** el conteo coincide y las IPs alternan entre las dos
réplicas (round-robin de HAProxy).

**Confirmar que 5001 es solo lectura:**

```bash
PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5001 -U postgres -c "INSERT INTO databugs.bitacora_pruebas (fase, nota) VALUES ('fase2','debe fallar');"
```

**Esperado:** `ERROR: cannot execute INSERT in a read-only transaction`.

Repetir `UPDATE` y `DELETE` por el 5000 y verificar propagación, tal como pide el
enunciado.

**📸 Evidencia Fase 2:** capturas antes/después, la salida del INSERT rechazado,
y el panel de lag de replicación en Grafana en ~0.

---

## Fase 3 — Caída de nodo 1

**nodo3 arranca la carga primero** (para tener métricas durante la falla):

```bash
docker run --rm --network host -v "$PWD/carga/k6:/scripts:ro" -e PROXY_HOST=localhost -e PGPASS=$SUPERUSER_PASSWORD -e DURACION=3m -e K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write -e K6_PROMETHEUS_RW_TREND_STATS='p(95),p(99),avg,max' bd2-k6-sql run -o experimental-prometheus-rw /scripts/carga-mixta.js
```

**nodo1 provoca la caída** y anota la hora exacta:

```bash
date -Ins && docker compose stop patroni && date -Ins
```

**Cualquiera verifica el failover** y anota la hora en que nodo2 asume:

```bash
until docker compose exec patroni patronictl list 2>/dev/null | grep -q 'nodo2.*Leader'; do sleep 2; done; date -Ins; docker compose exec patroni patronictl list
```

La diferencia entre ambas marcas es el **RTO**.

**Escribir a través del proxy** para confirmar que el servicio volvió:

```bash
PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5000 -U postgres -c "INSERT INTO databugs.bitacora_pruebas (fase, nota) VALUES ('fase3','escritura tras failover') RETURNING servidor, creado_en;"
```

**Reintegrar nodo1:**

```bash
docker compose start patroni
```

**Esperado:** vuelve como réplica usando `pg_rewind` (funciona porque el clúster
se creó con `data-checksums`), y HAProxy lo agrega al pool de lectura.

**📸 Evidencia Fase 3:** las dos marcas de tiempo, `patronictl list` antes y
después, dashboard de HAProxy con nodo1 en rojo y luego verde, y el dashboard
*BD2 — Carga y fallos* mostrando el hueco de throughput sobre el salto de
`patroni_primary`.

---

## Fase 4 — Caída de nodo 2

Idéntico procedimiento, pero tumbando `patroni` en **nodo2** con nodo1 activo
como líder. Misma captura de tiempos y misma evidencia.

---

## Fase 5 — Fallo múltiple y contingencia

> **Hagan las dos variantes.** El enunciado dice "apagar el nodo", y en la Fase 9
> el auxiliar elige el escenario — puede ser cualquiera de las dos, y dan
> resultados distintos.

### Variante A — solo Patroni abajo (etcd sigue vivo)

nodo1 y nodo2 ejecutan:

```bash
docker compose stop patroni
```

El quórum de etcd se conserva (3 miembros vivos). nodo3 sigue como réplica.

### Variante B — nodos completos abajo (sin quórum)

nodo1 y nodo2 ejecutan:

```bash
docker compose --profile nodo-bd stop
```

Aquí etcd queda en 1 de 3 y **nodo3 pierde el DCS**. Hay que verificar
explícitamente que su PostgreSQL siga sirviendo lecturas y que su Patroni siga
respondiendo `200` en `/replica`, porque de eso depende que HAProxy mantenga vivo
el puerto 5001.

### Verificaciones (ambas variantes)

Escrituras deben fallar:

```bash
PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5000 -U postgres -c "INSERT INTO databugs.bitacora_pruebas (fase, nota) VALUES ('fase5','no debe pasar');"
```

Lecturas deben seguir, atendidas solo por nodo3:

```bash
PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5001 -U postgres -tAc "select inet_server_addr()||' -> '||count(*) from databugs.transacciones;"
```

Carga de solo lectura sostenida (nodo3):

```bash
docker run --rm --network host -v "$PWD/carga/k6:/scripts:ro" -e PROXY_HOST=localhost -e PGPASS=$SUPERUSER_PASSWORD -e DURACION=2m -e K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write bd2-k6-sql run -o experimental-prometheus-rw /scripts/carga-lectura.js
```

En Grafana, el panel **Clúster sin líder** debe ponerse en rojo.

**Recuperación:** levantar primero uno de los dos, verificar que el servicio de
escritura vuelve, levantar el restante y confirmar que los tres se sincronizan.

**📸 Evidencia Fase 5:** el INSERT rechazado, los SELECT exitosos desde nodo3, el
dashboard en estado de contingencia, y los resultados de k6 en modo solo lectura.

---

## Fase 6 — Pruebas de carga

Los tres escenarios que pide el enunciado. Los ejecuta **nodo3**, siempre contra
su **HAProxy local**: si se apuntara al proxy de nodo1 y se apagara nodo1, se
perdería el generador de carga junto con el nodo.

| # | Escenario | Comando base | Qué se provoca a mitad |
|---|---|---|---|
| 1 | Carga mixta | `carga-mixta.js` con `DURACION=4m` | Caída de nodo1 al ~50 % |
| 2 | Carga mixta | `carga-mixta.js` con `DURACION=4m` | Caída de nodo2 al ~50 % |
| 3 | Solo lectura | `carga-lectura.js` con `DURACION=2m` | nodo1 y nodo2 ya abajo |

Respaldo sin compilar nada, si k6 diera problemas en la sesión:

```bash
./carga/pgbench/run-carga.sh mixta 240 10
```

**Métricas a registrar** (el enunciado las exige explícitamente): operaciones
totales, completadas antes de la falla, completadas después, fallidas, tiempo de
respuesta, latencia y disponibilidad. Todas salen del resumen de k6 y de los
paneles del dashboard *BD2 — Carga y fallos*.

---

## Fase 7 — Monitoreo durante las pruebas

Se ejecuta **junto con la Fase 6**, no después: el enunciado pide observar el
dashboard mientras corre la carga.

Capturas mínimas exigidas:

1. Dashboard en operación normal.
2. Dashboard durante la prueba de carga.
3. Dashboard durante la caída de un nodo.
4. Dashboard durante la contingencia (nodo1 y nodo2 fuera).

Los mínimos del enunciado (CPU, memoria, estado del servicio, disponibilidad,
latencia de replicación, latencia de consultas) están cubiertos entre los dos
dashboards; el detalle de qué métrica cubre qué requisito está en
`docs/RESUMEN_TECNICO_MONITOREO_CARGA.md`.

---

## Fase 8 — RTO y RPO

**RTO:** diferencia entre la marca de tiempo de la caída y la de la recuperación
del servicio. Se toman con `date -Ins` en cada fase y se contrastan con el hueco
de throughput en Grafana.

> El RTO **depende de cómo se tumbe el nodo** y hay que documentar ambos casos:
> con `docker compose stop patroni` Patroni libera el leader lock y el failover
> toma segundos; con una caída abrupta hay que esperar a que expire el `ttl: 30`,
> y sube a ~30 s o más.

**RPO:** con `nodo2` como réplica **síncrona** el RPO esperado es **cero**. Se
demuestra comparando el último registro escrito antes de la caída contra lo que
sobrevivió:

```bash
PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5001 -U postgres -c "select fase, servidor, creado_en from databugs.bitacora_pruebas order by id desc limit 10;"
```

---

## Trampas conocidas (leer antes de la sesión)

| Trampa | Por qué pasa | Qué hacer |
|---|---|---|
| **`docker kill` revive el contenedor** | Los servicios tienen `restart: unless-stopped`; `kill` no cuenta como parada explícita | Usar `docker compose stop`, o `sudo tailscale down` para simular caída abrupta |
| **Docker Desktop rompe `network_mode: host`** | El engine corre en una VM; el nodo queda invisible para los demás | `docker context use default` y verificar con `docker info` |
| **etcd reporta `3.0.0` para siempre** | Falta un miembro por unirse; la cluster version no sube hasta conocerlos a los tres | Revisar los logs del que falte; con los 3 arriba sube solo a `3.5.0` |
| **`dependency failed to start: etcd-1 is unhealthy`** | Alguien tardó más de ~60 s en levantar y el healthcheck agotó sus reintentos sin quórum | Repetir `up -d` con los tres listos, o subir `retries` en el healthcheck |
| **La VIP de keepalived no responde entre nodos** | Tailscale solo enruta IPs registradas en la tailnet; una VIP inventada sale por el gateway por defecto | Probarla explícitamente antes de afirmar que funciona, o documentarla como limitación |
| **`weight 2` en keepalived** | Un peso positivo solo suma al éxito; al fallar HAProxy la prioridad baja 2 puntos, insuficiente frente a una brecha de 50 | Verificar si la VIP realmente migra cuando se mata HAProxy |
| **El standby síncrono tarda en aparecer** | Patroni necesita un ciclo de `loop_wait` tras conectar las réplicas | Esperar 30 s antes de diagnosticar |

---

## Plantilla de bitácora

> Llenar **solo con resultados realmente medidos**. Una tabla con valores
> verosímiles que nadie observó es exactamente lo que el enunciado penaliza.

| Fecha y hora | Fase | Nodo / componente | Acción realizada | Resultado esperado | Resultado obtenido | RTO | Evidencia |
|---|---|---|---|---|---|---|---|
| | Fase 1 | Los 3 | `--profile nodo-bd up -d --build` | 4 contenedores arriba; `etcdcluster 3.5.0` | | N/A | |
| | Fase 1 | Los 3 | `patronictl list` | Leader + Sync Standby + Replica | | N/A | |
| | Fase 2 | Proxy | INSERT por 5000, SELECT por 5001 | Réplicas con el mismo conteo | | N/A | |
| | Fase 3 | nodo1 | `docker compose stop patroni` | Failover a nodo2 | | | |
| | Fase 3 | nodo1 | `docker compose start patroni` | Reintegración vía `pg_rewind` | | | |
| | Fase 4 | nodo2 | `docker compose stop patroni` | nodo1 atiende escrituras | | | |
| | Fase 5A | nodo1+2 | `stop patroni` (etcd vivo) | 5000 caído, 5001 responde | | N/A | |
| | Fase 5B | nodo1+2 | `stop` completo (sin quórum) | 5001 sigue respondiendo | | N/A | |
| | Fase 6 | nodo3 | Carga mixta + caída al 50 % | Operaciones continúan tras el failover | | | |
