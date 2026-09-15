# Propuesta de trabajo — Proyecto 1 BD2 (Grupo 5, PostgreSQL)

> Documento para discutir y validar en la primera reunión de grupo. Todo lo marcado como "propuesta" es negociable.

---

## 1. Arquitectura general propuesta

- **4 nodos en total:** Nodo 1, Nodo 2 y Nodo 3 (base de datos), más un **Nodo 4 dedicado a monitoreo** (justificación en la sección 2).
- **Infraestructura:** cada nodo corre en **Docker**, sobre la máquina física de cada integrante (sin VM intermedia), conectados por una **red privada con Tailscale**. Esto cumple "entornos independientes" porque cada host físico es distinto — si la laptop de uno falla, solo cae ese nodo.
- **Roles de los nodos de BD:**
  - Nodo 1: primario (lectura y escritura). Réplica síncrona hacia Nodo 2.
  - Nodo 2: réplica síncrona, promovible a primario (lectura y escritura tras failover).
  - Nodo 3: réplica asíncrona, **no promocionable** (`nofailover: true`), solo lectura y contingencia.
- **Proxy simétrico en los 3 nodos de BD:** cada uno corre su propio HAProxy + keepalived, compitiendo por una IP virtual (VIP) con prioridad Nodo1 > Nodo2 > Nodo3. Así el acceso sigue disponible incluso si caen dos de los tres nodos (cubre la Fase 5 del enunciado).
- **Monitoreo centralizado en el Nodo 4:** Prometheus + Grafana, separado de los nodos de BD para no perder visibilidad justo durante las pruebas de falla.

---

## 2. Tecnologías a usar: para qué sirve cada una

| Tecnología | Rol en la arquitectura | Por qué esta y no otra |
|---|---|---|
| **PostgreSQL** | Motor de base de datos, asignado por ser grupo impar | Requisito del enunciado |
| **Docker** | Empaqueta cada componente (Postgres, Patroni, etcd, HAProxy, etc.) en contenedores, uno por host físico | Más liviano que una VM completa; reproducible vía `docker-compose.yml`; fácil de reiniciar limpio entre pruebas (`docker stop/start`, `docker kill` para fallos abruptos) |
| **Tailscale** | Red privada (VPN mesh) que conecta los 3-4 hosts físicos con IPs privadas fijas (100.x.x.x), sin importar en qué red/casa esté cada quien | Gratis hasta 3 usuarios/100 dispositivos, configuración mínima (sin abrir puertos en el router), cumple el requisito de "red privada" entre entornos independientes |
| **Streaming replication (nativo de Postgres)** | Copia continua del WAL del primario hacia las réplicas | Es el mecanismo nativo del motor; Nodo 2 en modo síncrono (cero pérdida de datos en failover), Nodo 3 en modo asíncrono (tolera algo de lag, ya que es solo contingencia) |
| **Patroni + etcd** | Orquestación automática del clúster: etcd guarda el estado (quién es el líder) por consenso de mayoría (quorum 2 de 3); Patroni en cada nodo decide si su Postgres local debe ser primario o réplica, y promueve automáticamente ante una caída | Es el estándar de la industria para HA en PostgreSQL; automatiza exactamente el comportamiento que piden las Fases 3-5 (failover sin intervención manual) |
| **HAProxy** | Recibe las conexiones de los clientes y las enruta al nodo correcto, consultando el endpoint REST de Patroni (`/primary` para escrituras, `/replica` para lecturas) | Es el "mecanismo de acceso/distribución de conexiones" mínimo que exige el enunciado |
| **keepalived (VRRP)** | Mantiene una IP virtual (VIP) siempre apuntando a un HAProxy vivo; si el nodo que la tiene cae, otro la reclama en segundos, con prioridad Nodo1 > Nodo2 > Nodo3 | Evita que el proxy mismo se vuelva un punto único de falla; corriendo en los 3 nodos, sobrevive incluso a la caída de dos de ellos (Fase 5) |
| **Prometheus** | Recolecta métricas (pull) desde cada nodo cada 10-15s: `node_exporter` (CPU/memoria/disco), `postgres_exporter` (conexiones, transacciones), endpoint de Patroni (estado del clúster, lag de replicación) | Estándar de facto para monitoreo de sistemas distribuidos; se integra de forma nativa con Grafana y con k6 |
| **Grafana** | Dashboard unificado que consulta a Prometheus y grafica los 3 nodos lado a lado (CPU, lag de replicación, líder actual, etc.) | Visualización clara para la bitácora y la sustentación en vivo |
| **pgBackRest o Barman** *(extra)* | Backups físicos con PITR, mecanismo de recuperación independiente de la replicación | Cubre corrupción de datos, no solo caída de nodo — complementa la replicación |
| **xk6-sql** (o alternativamente **pgbench** como plan B) | Genera carga controlada de lectura/escritura apuntando a la VIP (no directo a un nodo), mide tiempo de respuesta/latencia/disponibilidad durante una caída provocada a mitad de la prueba | El enunciado permite "k6 o equivalente"; xk6-sql se integra con el stack de Prometheus/Grafana; si da problemas de compilación, pgbench es el respaldo simple y confiable |
| **Alertmanager** *(extra)* | Alertas automáticas (Slack/Telegram/correo) cuando un nodo cae o el lag de replicación supera un umbral | Complementa el monitoreo mínimo yendo más allá de solo mostrar métricas |

---

## 3. Extras propuestos sobre cada "mínimo" del enunciado

| Sección | Mínimo exigido | Extensión propuesta |
|---|---|---|
| Arquitectura general | 3 nodos | 4to nodo dedicado a monitoreo (justificado arriba) |
| Proxy/balanceo | Distribución de conexiones | keepalived + VIP para que el proxy mismo no sea punto único de falla |
| Recuperación ante fallos | Mecanismo de recuperación | Sumar backups PITR (pgBackRest/Barman) como capa adicional independiente de la replicación |
| Monitoreo | CPU, memoria, estado, disponibilidad, latencia de replicación y de consultas | Alertmanager con notificaciones automáticas; logs centralizados (Loki, si alcanza el tiempo) |
| Pruebas de carga | Operaciones totales/completadas/fallidas, tiempo de respuesta, latencia, disponibilidad | Percentiles p95/p99, throughput graficado en el tiempo, comparar escenarios (80/20 vs 50/50 lectura/escritura) |
| Bitácora | Fecha, fase, componente, acción, resultado, tiempo de recuperación, evidencia | Responsable de la prueba + captura del dashboard de Grafana en el momento exacto del evento |
| Informe final | Puntos listados en el enunciado | Video corto de un escenario de falla en vivo; repositorio reproducible (Docker Compose + plantillas parametrizadas) |

*(No hace falta implementar todos los extras — elegir 3-4 que el grupo pueda sostener bien en la sustentación.)*

---

## 4. Decisiones de configuración ya resueltas (para no reabrir debate en la reunión)

- **Red:** Docker en `network_mode: host` si todos corren Linux nativo/WSL2; si hay Mac/Windows con Docker Desktop, alternativa de bridge con puertos publicados explícitamente atados a la IP de Tailscale de cada host (no a `0.0.0.0`).
- **Replicación:** Nodo 2 síncrona, Nodo 3 asíncrona.
- **Proxy:** dos pools separados en HAProxy — `postgres_primario` (health check `/primary`) para escrituras, `postgres_lectura` (health check `/replica`) para lecturas, disponible en los 3 nodos vía Patroni.
- **Carga:** apuntar siempre a la VIP, nunca directo a un nodo, para probar el balanceo real.
- **Configuración parametrizada:** una sola plantilla de `docker-compose.yml`/`patroni.yml` por componente, con variables de entorno (`.env`, no versionado) para IP de Tailscale y rol de cada nodo — nunca 3 archivos hardcodeados distintos.

---

## 5. Plan de trabajo por capas

Reparto en forma de pipeline (no 100% paralelo), pensado para minimizar reuniones — cada quien avanza en solitario en su diseño y solo se sincronizan para integrar.

| Persona | Capas que lidera | Depende de |
|---|---|---|
| **A - Nodo1** | Entorno base (Tailscale + plantillas Docker) + Replicación (Postgres + Patroni + etcd) | Nada — punto de partida |
| **B - Nodo2** | Proxy (HAProxy + keepalived) + pruebas de failover (Fases 3-5) | Trabajo de A ya validado |
| **C - Nodo3 y - Nodo4** | Monitoreo (Nodo 4: Prometheus + Grafana) + Carga (xk6-sql/pgbench, Fase 6) | Trabajo de A y B ya validado |

**Flujo por capa (aplica a cada persona con su capa):**
1. Diseñar la configuración parametrizada (variables de entorno, no IPs/roles hardcodeados).
2. Validar la lógica en solitario, simulando los nodos en un solo `docker-compose.yml` local.
3. Subir a una rama de GitHub con instrucciones claras (qué valor de variable le toca a cada quien).
4. Sesión de integración en vivo: cada quien levanta su propio contenedor, ya conectado por Tailscale — esto no se puede reemplazar por pruebas en solitario porque el punto es validar hosts físicamente independientes.
5. Ejecutar en esa misma sesión las pruebas de la fase correspondiente del enunciado (la sesión de integración *es* la evidencia de la fase).
6. Ajustar y documentar cualquier diferencia entre lo local y lo distribuido.
7. Merge a `main` una vez validado en conjunto.

**Reuniones necesarias (4 en total, no continuas):**
1. Kickoff — crear el tailnet, confirmar conectividad, repartir capas y convención de `.env`.
2. Integración de replicación (Fase 2).
3. Integración de proxy + failover (Fases 3-5) — la más larga, requiere apagar/encender nodos en vivo.
4. Integración de carga (Fase 6).

El monitoreo (parte de la capa de C) casi no requiere reunión: mientras A y B dejen sus nodos encendidos, C puede hacer scraping remoto por Tailscale de forma asíncrona.

**Para reducir fricción entre reuniones:**
- Canal async fijo (WhatsApp/Discord) para avisos tipo "mi nodo está prendido, ya pueden probar".
- El README del repo documenta, por capa, qué se configuró y cómo probarlo — hace de "reunión escrita" para dudas simples.
- Bloquear de una vez horarios tentativos para las 4 reuniones.

**Antes de la entrega/calificación:** cada integrante hace un *dry run* individual completo (levantar el clúster desde cero, tumbar un nodo, recuperarlo, correr una prueba de carga) — el enunciado permite que en la calificación le pidan a cualquiera ejecutar, explicar, modificar o recuperar cualquier componente, no solo el suyo.

---

## 6. Preguntas para resolver en la primera reunión

- ¿Confirmar el reparto de capas (A/B/C) tal como está, o prefieren otro orden?
- ¿Quién crea el repositorio de GitHub y define la estructura de carpetas?
- ¿Cuáles 3-4 extras de la sección 3 se comprometen a implementar?
- ¿Calendario: cuántas semanas hay hasta la entrega? Ubicar las 4 sesiones de integración en fechas tentativas.
- ¿Todos tienen Docker instalado y pueden confirmar que corren Linux nativo/WSL2 (para decidir `network_mode: host` vs. bridge)?
