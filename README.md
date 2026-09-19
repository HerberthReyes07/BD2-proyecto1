# Proyecto 1 — Arquitectura de Alta Disponibilidad para PostgreSQL

**Grupo 5 · Bases de Datos 2**

Manual técnico del repositorio: arquitectura implementada, topología de red, función de cada nodo, mecanismo de replicación, proxy y balanceo, estrategia de failover, monitoreo, pruebas de carga, guía de despliegue, guía de pruebas de integración y plantilla de bitácora.

## Tabla de contenidos

1. [Introducción](#1-introducción)
2. [Arquitectura implementada](#2-arquitectura-implementada)
3. [Topología de red](#3-topología-de-red)
4. [Función de cada nodo](#4-función-de-cada-nodo)
5. [Replicación utilizada](#5-replicación-utilizada)
6. [Proxy y balanceo de conexiones](#6-proxy-y-balanceo-de-conexiones)
7. [Estrategia de failover](#7-estrategia-de-failover)
8. [Monitoreo y observabilidad](#8-monitoreo-y-observabilidad)
9. [Pruebas de carga](#9-pruebas-de-carga)
10. [RTO y RPO](#10-rto-y-rpo)
11. [Estructura del repositorio](#11-estructura-del-repositorio)
12. [Guía de despliegue](#12-guía-de-despliegue)
13. [Guía de pruebas de integración (Fases 1-8)](#13-guía-de-pruebas-de-integración-fases-1-8)
14. [Plantilla de bitácora de pruebas](#14-plantilla-de-bitácora-de-pruebas)
15. [Troubleshooting general](#15-troubleshooting-general)
16. [Ventajas y limitaciones](#16-ventajas-y-limitaciones)
17. [Extras implementados sobre el mínimo exigido](#17-extras-implementados-sobre-el-mínimo-exigido)

---

## 1. Introducción

La empresa ficticia **Data Bug's** administra una plataforma cuya información crítica reside en un único servidor de base de datos, lo que constituye un punto único de fallo: cualquier caída del servidor, pérdida de conectividad o error del sistema operativo deja a la plataforma completamente indisponible. Este proyecto implementa una arquitectura distribuida de alta disponibilidad para **PostgreSQL** (motor asignado por tratarse de un grupo impar) que resuelve ese problema.

La solución está compuesta por **tres nodos de base de datos** ejecutándose en máquinas físicas independientes de cada integrante del grupo, interconectadas mediante una red privada (Tailscale), con replicación en streaming gestionada automáticamente por **Patroni** sobre un clúster de consenso **etcd**, y una capa de enrutamiento inteligente con **HAProxy + keepalived** que expone un único punto de acceso resiliente (una IP virtual) hacia el clúster. Una capa de **observabilidad** (Prometheus + Grafana) y de **generación de carga** (k6 y pgbench) permite medir el comportamiento del sistema — disponibilidad, latencia, tiempo de recuperación (RTO) y pérdida potencial de datos (RPO) — ante escenarios controlados de falla.

El objetivo es que la plataforma siga operando, con distintos niveles de servicio, incluso ante la caída de uno o dos de sus tres nodos, minimizando los puntos únicos de fallo y automatizando la recuperación sin intervención manual.

---

## 2. Arquitectura implementada

La arquitectura se organiza en tres capas funcionales que corren de forma **simétrica y distribuida** sobre tres hosts físicos independientes (uno por integrante), conectados por una VPN mesh de Tailscale. No existe una cuarta máquina física: la capa de observabilidad se hospeda en la misma máquina del Nodo 3 (justificación en la sección 16).

**Capa de datos (persistencia y consenso).** Cada nodo ejecuta PostgreSQL 16 gestionado por Patroni 4.1.5, que administra el ciclo de vida del motor (arranque, promoción, reintegración) y decide automáticamente quién es el primario. La coordinación entre los tres Patroni se resuelve mediante un clúster **etcd 3.5.17** (algoritmo Raft): el estado de "quién es el líder" se guarda como un *lease* con TTL, y solo puede haber un titular a la vez. Detalle completo en [`base/README.md`](base/README.md).

**Capa de proxy y alta disponibilidad de acceso.** Cada nodo corre además, de forma simétrica, un contenedor de **HAProxy 2.8** y uno de **keepalived**. HAProxy consulta la API REST de Patroni (`:8008`) para enrutar en tiempo real: escrituras al líder (`5000`), lecturas balanceadas en round-robin entre réplicas (`5001`). keepalived gestiona una **IP Virtual (VIP)** mediante VRRP en modo *unicast*, con prioridades Nodo1 (150) > Nodo2 (100) > Nodo3 (50). Detalle completo en [`proxy/README.md`](proxy/README.md).

**Capa de observabilidad y carga.** `node_exporter` y `postgres_exporter` corren en los tres nodos exportando métricas de sistema y de Postgres; Patroni expone además sus propias métricas nativas en `:8008/metrics`. Prometheus y Grafana se centralizan en la máquina del Nodo 3. La generación de carga (k6 con `xk6-sql`, con respaldo en pgbench) se ejecuta desde el Nodo 3 contra su propio HAProxy local. Detalle en [`monitoreo/README.md`](monitoreo/README.md) y [`carga/README.md`](carga/README.md).

**Tecnologías utilizadas:**

| Componente | Tecnología | Rol |
|---|---|---|
| Motor de base de datos | PostgreSQL 16 | Almacenamiento y ejecución de consultas |
| Orquestación de HA | Patroni 4.1.5 | Gestión del ciclo de vida y failover automático de Postgres |
| Consenso distribuido | etcd 3.5.17 (Raft) | Elección de líder por quorum (2 de 3) |
| Proxy/enrutamiento | HAProxy 2.8 | Enrutamiento de escrituras/lecturas según rol del nodo |
| Alta disponibilidad del proxy | keepalived (VRRP unicast) | IP virtual resiliente, elimina al proxy como SPOF |
| Red privada | Tailscale (WireGuard) | VPN mesh entre hosts físicamente independientes |
| Contenerización | Docker / Docker Compose | Empaquetado y orquestación local por nodo (`network_mode: host`) |
| Monitoreo | Prometheus 3.1.0 + Grafana 11.5.2 | Métricas y dashboards en tiempo real |
| Pruebas de carga | k6 (xk6-sql) + pgbench | Carga controlada de lectura/escritura y medición de latencia |

*(Insertar aquí el diagrama de arquitectura general.)*

---

## 3. Topología de red

La comunicación entre nodos se realiza íntegramente sobre **Tailscale**, una VPN mesh basada en WireGuard que asigna a cada host una IP privada fija en el rango `100.x.x.x`, independiente de la red física de cada integrante. Esto cumple el requisito de "entornos independientes conectados por red privada": si la máquina de un integrante pierde conectividad a Internet, solo ese nodo cae.

Es una **topología en malla completa (full mesh)**: los tres nodos se ven entre sí directamente por su IP de Tailscale, sin un nodo central que actúe como *hub*. Cada contenedor corre con `network_mode: host`, exponiendo sus puertos directamente sobre la interfaz `tailscale0` del host.

**Nodos y direccionamiento:**

| Nodo | IP Tailscale (`IP_NODOx`) | Rol físico |
|---|---|---|
| Nodo 1 | `${IP_NODO1}` | BD (líder) + proxy (MASTER inicial) |
| Nodo 2 | `${IP_NODO2}` | BD (standby síncrono) + proxy (BACKUP 1) |
| Nodo 3 | `${IP_NODO3}` | BD (réplica asíncrona) + proxy (BACKUP 2) + observabilidad y carga |
| VIP (virtual) | `${VIRTUAL_IP}` (por defecto `100.124.30.200`) | Punto único de acceso, gestionado por keepalived |

**Puertos expuestos por nodo:**

| Puerto | Servicio | Alcance |
|---|---|---|
| 2379 / 2380 | etcd (cliente / peers Raft) | Los 3 nodos |
| 5432 | PostgreSQL | Los 3 nodos |
| 8008 | API REST de Patroni (`/primary`, `/replica`, `/metrics`) | Los 3 nodos |
| 5000 | HAProxy — escritura (solo primario) | Los 3 nodos (simétrico) |
| 5001 | HAProxy — lectura (round-robin réplicas) | Los 3 nodos (simétrico) |
| 7000 | Dashboard web de HAProxy | Los 3 nodos |
| 9100 / 9187 | node_exporter / postgres_exporter | Los 3 nodos |
| 9090 / 3000 | Prometheus / Grafana | Solo Nodo 3 |

Todo el tráfico de clientes (aplicación, `psql`, generadores de carga) se dirige a la **VIP**, nunca a la IP fija de un nodo en particular; keepalived decide, mediante VRRP en modo *unicast* (Tailscale no reenvía multicast), a qué máquina física llega efectivamente esa IP en cada momento.

*(Insertar aquí el diagrama de topología de red.)*

---

## 4. Función de cada nodo

| Nodo | Rol en la BD | Rol en el proxy | Otras funciones |
|---|---|---|---|
| **Nodo 1** | **Líder (primario):** atiende lectura y escritura; origen de la replicación en streaming hacia Nodo 2 y Nodo 3 | keepalived prioridad **150** → dueño inicial de la VIP; HAProxy enruta escrituras aquí mientras sea líder | — |
| **Nodo 2** | **Standby síncrono:** candidato preferente a promoción; recibe cada transacción de forma síncrona antes del commit en Nodo 1 (RPO = 0); atiende lecturas | keepalived prioridad **100** → asume la VIP si Nodo 1 cae | Tras un failover, pasa a atender lectura **y** escritura |
| **Nodo 3** | **Réplica asíncrona, solo lectura:** tags `nofailover: true` (nunca promovible) y `nosync: true` (no bloquea el commit del primario); nodo de contingencia | keepalived prioridad **50** → última línea, asume la VIP solo si caen Nodo 1 y Nodo 2 | Hospeda la capa de observabilidad (Prometheus + Grafana) y el generador de carga, por ser el único nodo que sobrevive a todos los escenarios de falla de las Fases 3-5 |

Los tres nodos ejecutan además, de forma **simétrica e idéntica**, una instancia de etcd (participando en el quorum Raft de 2/3) y una instancia de HAProxy + keepalived, de modo que tanto la elección de líder de base de datos como el acceso a través del proxy toleran la caída de cualquier nodo individual, y el proxy en particular tolera la caída de **dos** de los tres.

---

## 5. Replicación utilizada

El mecanismo es la **replicación en streaming nativa de PostgreSQL** (envío continuo del WAL del primario a las réplicas), en configuración **híbrida síncrona/asíncrona**, orquestada declarativamente por Patroni y sembrada en etcd al nacer el clúster (`base/bootstrap.yml.template`), sin necesidad de `patronictl edit-config` manual:

- **`synchronous_mode: true`** (global): activa la replicación síncrona en el clúster.
- **Nodo 1 → Nodo 2 (síncrona):** el primario espera la confirmación de escritura en disco de Nodo 2 antes de reportar el `COMMIT` como exitoso. Garantiza **RPO = 0** frente a la caída del líder.
- **Nodo 1 → Nodo 3 (asíncrona):** Nodo 3 recibe el WAL sin bloquear el commit del primario (tag `nosync: true`), tolerando cierto lag a cambio de no penalizar la latencia de escritura. Con `nofailover: true`, nunca es candidato a ser promovido.
- **Elección de líder:** depende del clúster **etcd** (Raft, quorum = ⌊3/2⌋+1 = 2 votos), no de la replicación de datos en sí. Patroni renueva un *lease* de liderazgo con `ttl: 30s` (`loop_wait: 10s`); si el líder deja de renovarlo, los demás negocian automáticamente quién asume, respetando los tags.
- **Reintegración tras una caída:** el nodo usa **`pg_rewind`** (`use_pg_rewind: true` + `data-checksums`) para rebobinar solo las transacciones divergentes, sin reconstruir la base completa.
- **Verificación de sincronía:** `GET :8008/patroni` reporta `sync_state` (`sync` para Nodo 2, `async` para Nodo 3) y los `tags` de cada nodo.

En resumen: replicación síncrona de un nodo (para no perder datos confirmados) + replicación asíncrona de un segundo nodo (tercer punto de acceso de solo lectura sin penalizar el rendimiento de escritura), coherente con el modelo mínimo del enunciado. Detalle de implementación en [`base/README.md`](base/README.md).

---

## 6. Proxy y balanceo de conexiones

**HAProxy 2.8** corre de forma simétrica en los tres nodos, consultando cada 3 segundos la API REST de Patroni (`option httpchk`, `inter 3s fall 3 rise 2`):

- **Puerto `5000` (escritura):** `backend postgres_write_back`, `GET /primary`. Solo el líder responde `200`. `on-marked-down shutdown-sessions` cierra de inmediato cualquier conexión colgada hacia un primario que acaba de caer, evitando que el cliente quede esperando a un nodo zombi.
- **Puerto `5001` (lectura):** `backend postgres_read_back`, `GET /replica`, `balance roundrobin` entre todas las réplicas que respondan `200`.
- **Puerto `7000`:** dashboard web de HAProxy con el estado de cada backend en tiempo real.

**keepalived** elimina al proxy mismo como punto único de fallo: gestiona una **VIP** (`100.124.30.200` por defecto) mediante **VRRP en modo unicast** (necesario porque Tailscale, al ser una red overlay WireGuard punto a punto, no reenvía tráfico multicast). Prioridades Nodo1 (150) > Nodo2 (100) > Nodo3 (50); un script (`check_haproxy.sh`) verifica cada 2s que el HAProxy local esté vivo, y si no, cede la VIP al siguiente nodo disponible. Con esto, el acceso al clúster sobrevive incluso a la caída de **dos** de los tres nodos (Fase 5).

Las aplicaciones cliente se conectan siempre a la VIP, nunca a la IP fija de un nodo — así un failover de base de datos es transparente para el cliente: HAProxy detecta el nuevo líder y redirige el tráfico de escritura automáticamente. Detalle completo en [`proxy/README.md`](proxy/README.md).

---

## 7. Estrategia de failover

El failover es **automático**, gestionado por Patroni sobre el consenso de etcd, sin intervención manual:

1. El líder renueva su *lease* en etcd cada `loop_wait` (10s), con un `ttl` de 30s.
2. Si el líder deja de renovarlo (caída, red cortada), el lease expira y los demás nodos Patroni compiten por el nuevo liderazgo.
3. Solo puede ganar un nodo con `nofailover: false` y con el WAL suficientemente al día (`maximum_lag_on_failover`). Nodo 3 (`nofailover: true`) nunca es candidato.
4. HAProxy detecta el cambio en su siguiente *health check* (máx. 3s) y empieza a enrutar `5000` hacia el nuevo líder.
5. El nodo caído, al reincorporarse, usa `pg_rewind` para resincronizarse como réplica automáticamente.

También existe un **failover planificado** (mantenimiento, sin esperar una caída real):

```bash
docker compose --profile nodo-bd exec patroni patronictl failover --candidate nodo2 --force
```

**Dos escenarios de caída con RTO distinto** (documentar ambos en la bitácora):

| Escenario | Comando | Comportamiento |
|---|---|---|
| Parada controlada | `docker compose stop patroni` | Patroni libera el *leader lock* explícitamente al apagarse → failover en segundos |
| Caída abrupta | `sudo tailscale down` en el nodo, o apagado físico | El lease debe expirar por `ttl: 30s` → failover más lento (~30s o más) |

⚠️ **`docker kill` no sirve para simular una caída:** todos los servicios llevan `restart: unless-stopped`, así que un contenedor matado con `kill` se reinicia solo de inmediato. Usar `docker compose stop` (parada controlada) o `sudo tailscale down` (caída de red abrupta y realista).

**Fallo múltiple (Fase 5):** si caen Nodo 1 y Nodo 2, etcd puede quedarse sin quorum (1 de 3) dependiendo de si solo se detiene Patroni (etcd sigue vivo, quorum 3/3 intacto) o el nodo completo (`--profile nodo-bd stop`, etcd cae a 1/3). En ambos casos, el puerto `5000` deja de responder (bloqueo de escrituras) y el puerto `5001` sigue sirviendo lecturas desde Nodo 3, mientras su Patroni siga respondiendo `200` en `/replica` — de eso depende que HAProxy mantenga vivo el pool de lectura incluso sin DCS con quorum.

---

## 8. Monitoreo y observabilidad

Prometheus + Grafana, centralizados en la máquina de Nodo 3, scrapean cada 5s: Patroni nativo (`:8008/metrics` — rol, timeline, lag de WAL), `node_exporter` (CPU/memoria/disco) y `postgres_exporter` (conexiones, `pg_up`) de los tres nodos. Dos dashboards aprovisionados desde JSON versionado en git:

- **BD2 — Estado del clúster:** líder actual, nodos alcanzables, estado de Postgres, clúster sin líder, lag de replicación, rol de cada nodo, timeline, disponibilidad de targets, CPU, memoria, conexiones.
- **BD2 — Carga y fallos:** operaciones completadas/fallidas, throughput, latencia de escritura/lectura, comportamiento durante la falla, CPU y lag bajo carga.

Detalle completo (arquitectura de scraping, métricas de Patroni, variables de entorno, operación) en [`monitoreo/README.md`](monitoreo/README.md).

---

## 9. Pruebas de carga

Dos generadores, ambos apuntando siempre al **proxy** (nunca a un nodo directo), ejecutados desde Nodo 3 contra su propio HAProxy local:

- **k6 + xk6-sql** (principal): carga mixta lectura/escritura o solo lectura, exporta latencias (`escritura_duracion`, `lectura_duracion`) y contadores de éxito/error a Prometheus vía remote-write.
- **pgbench** (respaldo): no requiere compilación; da TPS y latencia media directos.

Los tres escenarios que exige la Fase 6 (mixta con caída de Nodo 1 al 50%, mixta con caída de Nodo 2 al 50%, solo lectura con Nodo 1 y 2 abajo) están descritos con comandos exactos en la [sección 13](#13-guía-de-pruebas-de-integración-fases-1-8) y en [`carga/README.md`](carga/README.md), incluyendo el dataset de prueba (`databugs.clientes/productos/transacciones/bitacora_pruebas`).

---

## 10. RTO y RPO

**RTO (Recovery Time Objective):** diferencia entre la marca de tiempo de la caída del nodo y la marca de tiempo en que el servicio de escritura vuelve a responder a través del proxy. Se mide con `date -Ins` inmediatamente antes de detener el nodo, y con un polling de `patronictl list` hasta ver al nuevo líder:

```bash
date -Ins && docker compose stop patroni && date -Ins
until docker compose exec patroni patronictl list 2>/dev/null | grep -q 'nodo2.*Leader'; do sleep 2; done; date -Ins
```

El RTO depende de **cómo** se tumbe el nodo (ver [sección 7](#7-estrategia-de-failover)): segundos con parada controlada, hasta ~30s o más con caída abrupta (expiración del `ttl`). Ambos casos deben medirse y documentarse por separado.

**RPO (Recovery Point Objective):** con Nodo 2 como réplica **síncrona**, el RPO esperado es **cero** frente a la caída del líder. Se demuestra comparando el último registro de `databugs.bitacora_pruebas` escrito antes de la caída contra lo que sobrevivió en las réplicas:

```bash
PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5001 -U postgres -c \
  "select fase, servidor, creado_en from databugs.bitacora_pruebas order by id desc limit 10;"
```

Frente a Nodo 3 (asíncrono), sí existe RPO potencial distinto de cero: puede quedar con lag si la caída ocurre a mitad de una transferencia de WAL; esto se documenta como limitación conocida, no como falla.

---

## 11. Estructura del repositorio

```
.
├── README.md                          # este archivo — manual técnico
├── .env.example                       # plantilla de variables (copiar a .env, no versionado)
├── docker-compose.yml                 # compose principal, perfiles: nodo-bd | proxy | monitoreo | monitoreo-agente
├── docker-compose.2nodes.yml          # override para probar sin nodo3 (etcd 2/2)
├── docker-compose.local-sim.yml       # simulación de los 3 nodos en una sola máquina
├── docker-compose.local-sim.proxy.yml       # override: agrega HAProxy a la simulación local
├── docker-compose.local-sim.monitoreo.yml   # override: agrega Prometheus/Grafana a la simulación local
│
├── base/           # Capa de datos: PostgreSQL + Patroni + etcd       → base/README.md
├── proxy/          # Capa de proxy: HAProxy + keepalived (VIP)        → proxy/README.md
├── monitoreo/       # Observabilidad: Prometheus + Grafana             → monitoreo/README.md
├── carga/          # Dataset de prueba y generadores de carga (k6/pgbench) → carga/README.md
└── docs/           # Enunciado del proyecto, informe final y evidencias
```

Cada carpeta de componente tiene su propio `README.md` con el detalle de archivos, configuración y comandos de operación específicos de esa capa. Este documento es el punto de entrada que consolida arquitectura, topología y las guías operativas que cruzan varias capas a la vez (despliegue completo, pruebas de integración, bitácora).

---

## 12. Guía de despliegue

### 12.1 Pre-requisitos (cada integrante, en su máquina)

```bash
docker info --format '{{.OperatingSystem}}'   # debe decir la distro, NUNCA "Docker Desktop"
ss -lntp | grep -E ':5432|:2379|:2380|:8008|:5000|:5001|:7000|:9090|:3000'   # debe estar todo libre
```

Con Docker Desktop, `network_mode: host` es la red de una VM y el nodo queda invisible para los demás: corregir con `docker context use default`. Si el 5432 está ocupado, suele ser el PostgreSQL del sistema: `sudo systemctl disable --now postgresql@17-main` (ajustar versión).

### 12.2 Configurar `.env`

Copiar `.env.example` a `.env` y completar:

```bash
cp .env.example .env
```

| Variable | Valor |
|---|---|
| `NODE_NAME` | `nodo1` / `nodo2` / `nodo3` según la máquina |
| `MY_TAILSCALE_IP` | salida de `tailscale ip -4` en esta máquina |
| `IP_NODO1`, `IP_NODO2`, `IP_NODO3` | idénticas en los 3 `.env` |
| `NOFAILOVER`, `NOSYNC` | `true` únicamente en el `.env` de quien tenga nodo3 |
| `REPLICATION_PASSWORD`, `SUPERUSER_PASSWORD` | idénticas en los 3 `.env`; se siembran al nacer el clúster (cambiarlas después requiere `down -v`) |
| `VIRTUAL_IP`, `KEEPALIVED_INTERFACE` | idénticas en los 3 `.env` (por defecto `100.124.30.200` / `tailscale0`) |

### 12.3 Limpieza coordinada antes de un primer arranque

```bash
docker compose --profile nodo-bd down -v
docker ps -a | grep proyecto1; docker volume ls | grep proyecto1   # confirmar que no queda nada
```

⚠️ El `-v` es obligatorio: etcd guarda la membresía del clúster dentro de su volumen de datos, no en las variables de entorno. Un miembro inicializado creyendo que el clúster es de 2 nodos rechaza al tercero para siempre.

### 12.4 Levantar

```bash
docker compose --profile nodo-bd up -d --build
```

Ese único comando levanta, en cada nodo: `etcd`, `patroni`, `haproxy`, `keepalived`, `node-exporter`, `postgres-exporter`. El escalonamiento (etcd antes que Patroni) lo garantiza `depends_on: service_healthy`. Solo **nodo3** levanta además el stack de observabilidad:

```bash
docker compose --profile monitoreo up -d
# o, todo de una vez en nodo3:
docker compose --profile nodo-bd --profile monitoreo up -d --build
```

> La ventana de arranque de etcd es de ~60s. Si un nodo tarda más, los demás pueden marcar su etcd como `unhealthy` y Compose aborta con `dependency failed to start`. No es un error de configuración: repetir `up -d` cuando los tres estén listos.

### 12.5 Verificar

```bash
curl -s localhost:2379/version                       # "etcdcluster":"3.5.x" en los 3
docker compose exec etcd etcdctl member list -w table # 3 miembros con client URL
docker compose exec patroni patronictl list           # nodo1 Leader · nodo2 Sync Standby · nodo3 Replica
```

Abrir `http://localhost:7000/` (HAProxy) y, desde nodo3, `http://localhost:3000/` (Grafana, admin/admin).

### 12.6 Cargar el dataset (una sola vez, desde cualquier nodo)

```bash
set -a && source .env && set +a
PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5000 -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f carga/dataset/01-esquema.sql
```

### 12.7 Validación en un solo host (antes de ir a Tailscale)

```bash
docker compose -f docker-compose.local-sim.yml \
               -f docker-compose.local-sim.proxy.yml \
               -f docker-compose.local-sim.monitoreo.yml up -d --build
```

Simula los 3 nodos como contenedores en una sola máquina, con HAProxy y el stack de Grafana incluidos. Útil para validar cambios antes de la sesión distribuida real. Limpieza: agregar `down -v` al mismo comando.

---

## 13. Guía de pruebas de integración (Fases 1-8)

> Ejecutar **a través del proxy** (`localhost:5000`/`5001`), nunca contra un nodo directo, salvo que se indique lo contrario.

### Fase 1 — Preparación y arranque

Ejecutar la [guía de despliegue](#12-guía-de-despliegue) completa en los tres nodos. Evidencia: `patronictl list` con los tres sanos, dashboard de HAProxy en verde, dashboard *BD2 — Estado del clúster* con los tres nodos, salida de `tailscale status`.

### Fase 2 — Replicación normal

```bash
# Insertar desde el líder (puerto 5000)
PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5000 -U postgres -c \
  "INSERT INTO databugs.bitacora_pruebas (fase, nota) VALUES ('fase2','insert inicial') RETURNING id, servidor, creado_en;"

# Verificar en réplicas (puerto 5001, round-robin)
for i in 1 2 3 4; do PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5001 -U postgres -tAc \
  "select inet_server_addr()||' -> '||count(*) from databugs.bitacora_pruebas;"; done

# Confirmar que 5001 es solo lectura
PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5001 -U postgres -c \
  "INSERT INTO databugs.bitacora_pruebas (fase, nota) VALUES ('fase2','debe fallar');"
# Esperado: ERROR: cannot execute INSERT in a read-only transaction
```

Repetir `UPDATE`/`DELETE` por el puerto 5000 y verificar propagación. Evidencia: capturas antes/después, el INSERT rechazado, panel de lag de replicación en Grafana en ~0.

### Fase 3 — Caída de Nodo 1

```bash
# nodo3 arranca la carga primero (para tener métricas durante la falla)
docker run --rm --network host -v "$PWD/carga/k6:/scripts:ro" -e PROXY_HOST=localhost \
  -e PGPASS=$SUPERUSER_PASSWORD -e DURACION=3m \
  -e K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write \
  bd2-k6-sql run -o experimental-prometheus-rw /scripts/carga-mixta.js

# nodo1 provoca la caída y anota la hora exacta
date -Ins && docker compose stop patroni && date -Ins

# Verificar failover (RTO = diferencia entre marcas)
until docker compose exec patroni patronictl list 2>/dev/null | grep -q 'nodo2.*Leader'; do sleep 2; done; date -Ins

# Escribir a través del proxy para confirmar el servicio
PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5000 -U postgres -c \
  "INSERT INTO databugs.bitacora_pruebas (fase, nota) VALUES ('fase3','escritura tras failover') RETURNING servidor, creado_en;"

# Reintegrar
docker compose start patroni   # vuelve como réplica vía pg_rewind
```

Evidencia: las dos marcas de tiempo, `patronictl list` antes/después, dashboard de HAProxy (nodo1 rojo → verde), dashboard *BD2 — Carga y fallos* con el hueco de throughput.

### Fase 4 — Caída de Nodo 2

Idéntico procedimiento de la Fase 3, tumbando `patroni` en nodo2 con nodo1 como líder activo.

### Fase 5 — Fallo múltiple y contingencia

Dos variantes (ejecutar ambas — dan resultados distintos):

```bash
# Variante A — solo Patroni abajo (etcd sigue con quorum 3/3)
docker compose stop patroni   # en nodo1 y nodo2

# Variante B — nodos completos abajo (etcd cae a 1/3, nodo3 pierde el DCS)
docker compose --profile nodo-bd stop   # en nodo1 y nodo2
```

Verificaciones (ambas variantes):

```bash
# Escrituras deben fallar
PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5000 -U postgres -c \
  "INSERT INTO databugs.bitacora_pruebas (fase, nota) VALUES ('fase5','no debe pasar');"

# Lecturas deben seguir, atendidas solo por nodo3
PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5001 -U postgres -tAc \
  "select inet_server_addr()||' -> '||count(*) from databugs.transacciones;"
```

En la variante B, verificar explícitamente que el Postgres y Patroni de nodo3 sigan respondiendo `200` en `/replica` (de eso depende que HAProxy mantenga vivo el puerto 5001 sin DCS). Recuperación: levantar primero uno de los dos nodos, confirmar que vuelve la escritura, levantar el restante y confirmar sincronización de los tres. Evidencia: INSERT rechazado, SELECTs exitosos desde nodo3, dashboard en contingencia, panel *Clúster sin líder* en rojo.

### Fase 6 — Pruebas de carga

Ejecutadas siempre por **nodo3**, contra su HAProxy local:

| # | Escenario | Comando | Qué se provoca a mitad |
|---|---|---|---|
| 1 | Carga mixta | `carga-mixta.js`, `DURACION=4m` | Caída de nodo1 al ~50% |
| 2 | Carga mixta | `carga-mixta.js`, `DURACION=4m` | Caída de nodo2 al ~50% |
| 3 | Solo lectura | `carga-lectura.js`, `DURACION=2m` | nodo1 y nodo2 ya abajo |

Respaldo sin compilar nada: `./carga/pgbench/run-carga.sh mixta 240 10`. Métricas mínimas a registrar: operaciones totales, completadas antes/después de la falla, fallidas, tiempo de respuesta, latencia, disponibilidad (todas salen del resumen de k6 y del dashboard *BD2 — Carga y fallos*). Detalle en [`carga/README.md`](carga/README.md).

### Fase 7 — Monitoreo durante las pruebas

Se ejecuta **junto con** la Fase 6, no después. Capturas mínimas: dashboard en operación normal, durante la carga, durante la caída de un nodo, y durante la contingencia (nodo1 y nodo2 fuera). Detalle de métricas y paneles en [`monitoreo/README.md`](monitoreo/README.md).

### Fase 8 — RTO y RPO

Ver [sección 10](#10-rto-y-rpo). Registrar ambos escenarios de caída (controlada vs. abrupta) por separado.

### Fase 9 — Prueba de resiliencia durante la calificación

El auxiliar puede seleccionar cualquier nodo o componente para simular una falla durante la evaluación. El grupo debe poder explicar en el momento: qué ocurrió, cómo respondió la arquitectura, qué componente asumió el servicio, si hubo pérdida de disponibilidad, y cómo se recuperó — usando las mismas verificaciones (`patronictl list`, dashboard de HAProxy, dashboards de Grafana) descritas en las fases anteriores.

---

## 14. Troubleshooting general

| Problema | Causa | Solución |
|---|---|---|
| `docker kill` revive el contenedor | `restart: unless-stopped`; `kill` no cuenta como parada explícita | Usar `docker compose stop`, o `sudo tailscale down` para simular caída abrupta |
| Docker Desktop rompe `network_mode: host` | El engine corre en una VM; el nodo queda invisible para los demás | `docker context use default` y verificar con `docker info` |
| etcd reporta `3.0.0` para siempre | Falta un miembro por unirse; la cluster version no sube hasta conocer a los tres | Revisar logs del que falte; con los 3 arriba sube a `3.5.x` (detalle en [`base/README.md`](base/README.md)) |
| `dependency failed to start: etcd-1 is unhealthy` | Alguien tardó más de ~60s en levantar y el healthcheck agotó reintentos sin quorum | Repetir `up -d` con los tres listos, o subir `retries` en el healthcheck |
| La VIP no responde entre nodos | Tailscale solo enruta IPs registradas en la tailnet | Probarla explícitamente antes de asumir que funciona (detalle en [`proxy/README.md`](proxy/README.md)) |
| El standby síncrono tarda en aparecer | Patroni necesita un ciclo de `loop_wait` tras conectar las réplicas | Esperar ~10-30s antes de diagnosticar |
| Puerto `5432`/`5000`/`5001`/`7000` ocupado | Servicio nativo del sistema o corrida anterior sin limpiar | `ss -lntp \| grep -E '5432\|5000\|5001\|7000'`; deshabilitar el PostgreSQL nativo si aplica |

Troubleshooting específico de cada capa (con más detalle) en su propio `README.md`: [`base/`](base/README.md), [`proxy/`](proxy/README.md), [`monitoreo/`](monitoreo/README.md), [`carga/`](carga/README.md).

---

## 15. Ventajas y limitaciones

**Ventajas:**

- Sin punto único de fallo en el acceso: el proxy corre simétricamente en los 3 nodos y sobrevive a la caída de 2 de ellos gracias a la VIP con VRRP.
- Failover completamente automático (Patroni + etcd), sin intervención humana, con RPO = 0 garantizado por replicación síncrona hacia Nodo 2.
- Toda la configuración es parametrizada por `.env` — el mismo `docker-compose.yml` sirve para los 3 nodos sin archivos hardcodeados distintos.
- Observabilidad y generación de carga reproducibles: dashboards versionados como JSON, datasets y scripts de carga versionados en git.

**Limitaciones y puntos únicos de fallo residuales:**

- **Observabilidad colocada con Nodo 3:** al no existir una cuarta máquina física, si el host de Nodo 3 se apaga se pierden simultáneamente el nodo de contingencia (solo lectura) *y* toda la visibilidad del clúster (Prometheus/Grafana). Es la limitación más importante de la arquitectura y se documenta explícitamente.
- **etcd sin quorum en fallo múltiple:** si caen los hosts completos de Nodo 1 y Nodo 2 (no solo Patroni), etcd queda en 1/3 y pierde quorum; el clúster de datos ya no puede tomar decisiones de liderazgo (aunque Nodo 3 sigue sirviendo lecturas directamente desde su Postgres local).
- **Ruido de métricas bajo carga:** Prometheus, Grafana y los generadores de carga corren en la misma máquina que Nodo 3, consumiendo CPU que se mezcla con las métricas del propio nodo durante las pruebas de la Fase 6.
- **VIP dependiente de Tailscale:** si la conectividad de Tailscale se degrada (no solo la conectividad a Internet de un host), la migración de la VIP puede no ser instantánea; debe probarse explícitamente en cada sesión, no asumirse.
- **RPO potencialmente > 0 en Nodo 3:** al ser réplica asíncrona, puede perder las últimas transacciones si la caída del líder ocurre a mitad de un envío de WAL hacia ese nodo específico.

**Mejoras futuras consideradas pero no implementadas:** backups físicos con PITR (pgBackRest/Barman) como capa de recuperación independiente de la replicación; Alertmanager para notificaciones automáticas ante caída de nodo o lag elevado; logs centralizados (Loki); un cuarto nodo físico dedicado exclusivamente a observabilidad para eliminar el SPOF descrito arriba.

---

## 16. Extras implementados sobre el mínimo exigido

| Mínimo exigido por el enunciado | Extensión implementada en este proyecto |
|---|---|
| Mecanismo de acceso/distribución de conexiones | keepalived + VIP (VRRP unicast) para que el proxy mismo no sea un punto único de fallo, tolerando la caída de 2 de los 3 nodos |
| Herramienta de generación de carga (k6, JMeter, Locust o equivalente) | Dos generadores independientes: k6 (compilado con `xk6-sql`, integrado con Prometheus/Grafana) + pgbench como respaldo sin compilación |
| Medición de tiempo de respuesta y latencia | Percentiles p95/p99 y promedio, graficados en el tiempo en el dashboard *BD2 — Carga y fallos* |
| Dataset de prueba | Esquema relacional con 3 tablas de negocio (`clientes`, `productos`, `transacciones`) más una tabla dedicada (`bitacora_pruebas`) diseñada específicamente para calcular RPO comparando marcas de tiempo por servidor |
| Monitoreo del estado de los nodos | Sin exporter adicional para el estado del clúster: se reutilizan las métricas nativas que Patroni ya expone en `/metrics` sobre el mismo puerto que consulta HAProxy |
