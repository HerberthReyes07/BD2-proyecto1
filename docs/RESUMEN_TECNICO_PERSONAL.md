# Documento Técnico Personal — Proyecto 1 BD2
**Arquitectura de Alta Disponibilidad con PostgreSQL, Patroni, etcd, HAProxy y keepalived**

> 📖 **Propósito de este documento:**  
> Servir como guía de estudio, referencia técnica y libreto de sustentación personal. Explica con claridad qué construyó tu compañero en la **Fase 1 (Capa A: Replicación y Consenso)** y qué construimos en la **Fase 2 (Capa B: Proxy, Enrutamiento Inteligente y Alta Disponibilidad con VIP)**, detallando el *por qué* de cada decisión técnica.

---

```mermaid
flowchart TD
    subgraph Clientes["👥 Aplicaciones / Clientes"]
        APP["App / psql / Pruebas de Carga"]
    end

    subgraph CapaProxy["🛡️ CAPA B (TÚ - NODO 2): Proxy y Alta Disponibilidad"]
        VIP["🌐 IP Virtual (VIP): 100.124.30.200<br/>Gestionada por keepalived (VRRP Unicast)"]
        HAP["🔀 HAProxy (Escucha en los 3 nodos)<br/>• Puerto 5000: Escrituras (GET /primary)<br/>• Puerto 5001: Lecturas (GET /replica - Round Robin)<br/>• Puerto 7000: Dashboard Web"]
    end

    subgraph CapaDatos["🛢️ CAPA A (COMPA 1 - NODO 1): Consenso y Replicación"]
        subgraph Nodo1["💻 Nodo 1 (debian - 100.67.149.67)"]
            ETCD1["etcd (Puerto 2379/2380)"]
            PAT1["Patroni (REST :8008)"]
            PG1["PostgreSQL 16 (Líder / RW)"]
        end
        subgraph Nodo2["💻 Nodo 2 (ronyr304 - 100.124.30.113)"]
            ETCD2["etcd (Puerto 2379/2380)"]
            PAT2["Patroni (REST :8008)"]
            PG2["PostgreSQL 16 (Sync Standby / RW)"]
        end
        subgraph Nodo3["💻 Nodo 3 (desktop - 100.126.127.120)"]
            ETCD3["etcd (Puerto 2379/2380)"]
            PAT3["Patroni (REST :8008)"]
            PG3["PostgreSQL 16 (Async / Solo Lectura)"]
        end
    end

    APP --> VIP
    VIP --> HAP
    HAP -.->|GET /primary (Solo Líder)| PAT1
    HAP -.->|GET /primary (Solo Líder)| PAT2
    HAP -.->|GET /replica (Réplicas)| PAT2
    HAP -.->|GET /replica (Réplicas)| PAT3
    PAT1 <--> ETCD1
    PAT2 <--> ETCD2
    PAT3 <--> ETCD3
    ETCD1 <-->|Raft Quorum 2/3| ETCD2
    ETCD2 <-->|Raft Quorum 2/3| ETCD3
    PG1 ===|Streaming Replicación Síncrona| PG2
    PG1 -.->|Streaming Replicación Asíncrona| PG3
```

---

# ==========================================
# PARTE 1: LO QUE HIZO TU COMPA 1 (Persona A — Nodo 1)
# ==========================================

### Objetivo de su Fase:
Poner a funcionar los tres nodos de base de datos en hosts físicamente independientes, interconectados por red privada (Tailscale), con replicación síncrona/asíncrona y failover automático gestionado por consenso.

---

### 1. Los Componentes que configuró y su rol

#### A. Red Privada con Tailscale
* **¿Qué es?** Una VPN mesh basada en WireGuard que crea una red privada cifrada punto a punto.
* **¿Por qué se usó?** Permite que la computadora de Compa 1 (`100.67.149.67`), tu máquina (`100.124.30.113`) y la de Compa 3 (`100.126.127.120`) se comuniquen por IPs privadas fijas sin importar en qué red WiFi o casa esté cada quien, sin necesidad de abrir puertos en el router. Cumple el requisito de **entornos independientes**.

#### B. etcd 3.5.17 (El Cerebro del Consenso)
* **¿Qué es?** Es un almacén distribuido de clave-valor que implementa el algoritmo **Raft**.
* **¿Para qué sirve en este clúster?**
  * Es el que guarda el estado de la verdad: quién es el líder actual del clúster (`leader lock`).
  * Para que el clúster tome decisiones, requiere **Quorum (mayoría)**:
    $$\text{Quorum} = \left\lfloor \frac{N}{2} \right\rfloor + 1 = \left\lfloor \frac{3}{2} \right\rfloor + 1 = 2 \text{ votos}$$
  * Si cae 1 nodo, quedan 2 vivos $\rightarrow$ hay quórum $\rightarrow$ el clúster sigue operando.
  * Si caen 2 nodos, queda 1 vivo $\rightarrow$ se pierde quórum $\rightarrow$ se bloquean escrituras para evitar que dos nodos crean que son líderes a la vez (**Split-Brain**).
* **Puertos:**
  * `2379`: Puerto de clientes (donde Patroni consulta y renueva su liderazgo).
  * `2380`: Puerto de comunicación entre los pares de etcd (heartbeats internos de Raft).

#### C. Patroni 4.1.5 (El Administrador Inteligente de PostgreSQL)
* **¿Qué es?** Un demonio en Python que gestiona el ciclo de vida de PostgreSQL.
* **¿Por qué no usar PostgreSQL solo?**
  * PostgreSQL nativo **no** sabe auto-promoverse si el primario muere, ni sabe quién tiene la versión más reciente del WAL.
  * Patroni toma el control: arranca PostgreSQL, revisa etcd cada 10 segundos (`loop_wait`), renueva el candado de líder (`ttl: 30s`), y si el líder deja de renovarlo, Patroni en los otros nodos negocia quién asume como nuevo Líder.
  * Si un nodo caído vuelve, Patroni usa **`pg_rewind`** para rebobinar las transacciones sobrantes y sincronizarlo como réplica sin necesidad de rehacer la base desde cero.
* **REST API de Patroni (`puerto 8008`):**
  * `GET /primary`: Devuelve `HTTP 200 OK` si el nodo es el Líder activo. Si es réplica devuelve `503`.
  * `GET /replica`: Devuelve `HTTP 200 OK` si el nodo es una réplica funcional. Si es líder devuelve `503`.
  * Esta API es el puente vital que luego aprovecha HAProxy.

---

### 2. La "Artesanía Técnica" de Compa 1 (Archivos en `base/`)

1. **`base/Dockerfile`:**
   * Imagen base de `postgres:16`.
   * Instala Python 3, `pip`, `patroni[etcd3]`, `pg_rewind` y utilidades de red.
2. **`base/Dockerfile.etcd`:**
   * Descarga y compila el binario oficial de `etcd` y `etcdctl` versión 3.5.17 desde GitHub Releases.
3. **`base/bootstrap.yml.template` y `base/entrypoint.sh`:**
   * **El problema que resolvió:** Patroni no permite definir tags como `nofailover` o `nosync` mediante simples variables de entorno tipo `PATRONI_TAGS_*`.
   * **La solución:** Creó una plantilla YAML con variables `${NOFAILOVER}` y `${NOSYNC}`, y un script `entrypoint.sh` que ejecuta `envsubst` al arrancar el contenedor para generar `/tmp/bootstrap.yml` con los valores de cada nodo.
   * **Configuraciones clave sembradas en etcd:**
     * `synchronous_mode: true`: Fuerza que las transacciones en Nodo 1 esperen la confirmación en disco de Nodo 2 antes de hacer commit (cero pérdida de datos / RPO = 0).
     * `Nodo 3` lleva `nofailover: true` (nunca será promovido a líder) y `nosync: true` (nunca frena las escrituras de los otros nodos, opera como contingencia asíncrona).
4. **El problema de versión resuelto por Compa 1:**
   * Un clúster nuevo de etcd arranca reportando versión interna `3.0.0` hasta que todos los miembros del `initial-cluster` se presentan.
   * Si Patroni arrancaba de golpe, leía `3.0.0` e intentaba usar la API `/v3alpha` (ya retirada en etcd 3.5), quedándose colgado en `"waiting on etcd"`.
   * Compa 1 descubrió esto y documentó el **bootstrap en fases** (etcd primero, verificar `curl localhost:2379/version` en `3.5.x`, y luego Patroni), además de crear el override `docker-compose.2nodes.yml` para pruebas de solo dos personas.

---

# ==========================================
# PARTE 2: LO QUE HICIMOS NOSOTROS (Persona B — Nodo 2)
# ==========================================

### Objetivo de nuestra Fase:
Resolver el acceso y enrutamiento inteligente de las aplicaciones clientes, balancear lecturas, garantizar que un failover sea completamente transparente para el usuario final, y blindar al proxy para que **no sea un punto único de fallo (SPOF)**.

---

### 1. El Problema que resolvimos
Hasta la Fase 1, la base de datos ya replicaba, pero tenía dos problemas graves:
1. **Conexiones a ciegas:** Si una aplicación quería escribir datos, tenía que saber explícitamente la IP de Nodo 1 (`100.67.149.67`). Si Nodo 1 caía y Patroni promovía a Nodo 2, la aplicación fallaba porque seguía intentando pegarle a la IP vieja de Nodo 1.
2. **El Proxy como nuevo SPOF:** Si poníamos un solo balanceador (por ejemplo HAProxy solo en la máquina de Nodo 1), y la máquina de Nodo 1 se apagaba físicamente, ¡se moría el balanceador y nadie podía acceder a Nodo 2 ni a Nodo 3, aunque estuvieran vivos!

---

### 2. Los Componentes que diseñamos e implementamos

#### A. HAProxy 2.8 (`proxy/Dockerfile` y `proxy/haproxy.cfg.template`)
Implementamos un balanceador TCP de alto rendimiento que corre de forma simétrica en los 3 nodos, consultando activamente el API REST de Patroni (`:8008`) cada 3 segundos:

* **Puerto `5000` (Canal de Escritura — Primario):**
  ```haproxy
  backend postgres_write_back
      mode tcp
      option httpchk GET /primary
      http-check expect status 200
      default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
      server nodo1 ${IP_NODO1}:5432 maxconn 100 check port 8008
      server nodo2 ${IP_NODO2}:5432 maxconn 100 check port 8008
      server nodo3 ${IP_NODO3}:5432 maxconn 100 check port 8008
  ```
  * **Cómo funciona:** Solo el nodo que sea Líder responderá `200 OK` en `/primary`. Los demás responden `503 Service Unavailable`.
  * **Failover instantáneo:** Si Nodo 1 cae, Patroni promueve a Nodo 2. En la siguiente comprobación, HAProxy ve que Nodo 2 responde `200` y empieza a mandarle todas las escrituras que lleguen al puerto 5000.
  * **`on-marked-down shutdown-sessions`:** Si un nodo primario cae o es degradado, HAProxy liquida inmediatamente cualquier conexión TCP que haya quedado abierta hacia él, evitando que la aplicación se quede colgada esperando respuesta de un nodo zombi.

* **Puerto `5001` (Canal de Lectura — Réplicas):**
  ```haproxy
  backend postgres_read_back
      mode tcp
      balance roundrobin
      option httpchk GET /replica
      http-check expect status 200
      default-server inter 3s fall 3 rise 2
      server nodo1 ${IP_NODO1}:5432 maxconn 100 check port 8008
      server nodo2 ${IP_NODO2}:5432 maxconn 100 check port 8008
      server nodo3 ${IP_NODO3}:5432 maxconn 100 check port 8008
  ```
  * **Cómo funciona:** Consulta `/replica`. Solo las réplicas activas responden `200 OK`.
  * **Balanceo Round-Robin:** Si consultas el puerto 5001 cuatro veces seguidas, la consulta 1 va a Nodo 2, la 2 a Nodo 3, la 3 a Nodo 2, la 4 a Nodo 3. Esto descarga por completo al nodo Líder de la carga de lectura.
  * **Cumplimiento de la Fase 5 (Fallo múltiple):** Si caen Nodo 1 y Nodo 2 al mismo tiempo, el puerto 5000 queda bloqueado, pero el puerto 5001 detecta que Nodo 3 sigue respondiendo `200` en `/replica`, permitiendo que el sistema siga sirviendo consultas `SELECT` de contingencia.

* **Puerto `7000` (Dashboard Web):**
  * Una interfaz gráfica web accesible desde el navegador (`http://localhost:7000/`) donde se ven los servidores en verde (UP) o rojo (DOWN) en tiempo real con estadísticas de tráfico, errores y latencias.

#### B. keepalived con VRRP en Unicast (`proxy/Dockerfile.keepalived` y `proxy/keepalived.conf.template`)
Para eliminar el SPOF del balanceador, instalamos `keepalived` en las 3 computadoras para gestionar una **IP Virtual compartida (VIP)**:

* **El Reto de Tailscale resuelto:**
  * El protocolo estándar VRRP envía paquetes multicast a la IP `224.0.0.18`.
  * **Problema:** Tailscale (por ser una red overlay de WireGuard punto a punto) **no transmite paquetes multicast**. Si dejábamos keepalived por defecto, fallaría en silencio.
  * **Solución:** Lo configuramos en modo **Unicast** estricto:
    ```
    unicast_src_ip 100.124.30.113        # Mi IP en Tailscale
    unicast_peer {
        100.67.149.67                    # IP de Compa 1
        100.126.127.120                  # IP de Compa 3
    }
    ```
* **Prioridades jerárquicas dinámicas:**
  * `entrypoint-keepalived.sh` detecta el `NODE_NAME` y asigna automáticamente:
    * **Nodo 1:** Prioridad `150` (MASTER inicial $\rightarrow$ tiene la VIP).
    * **Nodo 2:** Prioridad `100` (BACKUP 1 $\rightarrow$ toma la VIP si Nodo 1 muere).
    * **Nodo 3:** Prioridad `50` (BACKUP 2 $\rightarrow$ toma la VIP si caen N1 y N2).
* **Vigilante de HAProxy (`check_haproxy.sh`):**
  * keepalived corre periódicamente un script que hace `curl` al puerto 7000 de HAProxy. Si HAProxy muere o se traba en el nodo que sostiene la VIP, keepalived baja su prioridad y cede la VIP al siguiente nodo en menos de 2 segundos.

---

### 3. Las Pruebas que ejecutamos y validamos (Paso 2)

Creamos el archivo `docker-compose.local-sim.proxy.yml` y sometimos nuestra arquitectura a un test exhaustivo antes de subir el código a GitHub:

1. **Prueba de Enrutamiento Base:**
   * Puerto 5000 $\rightarrow$ Escribió en Nodo 1 (`pg_is_in_recovery = false`).
   * Puerto 5001 $\rightarrow$ Leyó de réplicas (`pg_is_in_recovery = true`) alternando en Round-Robin perfecto entre Nodo 2 y Nodo 3.
   * Intentar un `INSERT` en el puerto 5001 fue rechazado por Postgres: `cannot execute INSERT in a read-only transaction`.
2. **Prueba de Failover (Fase 3):**
   * Matamos `patroni-nodo1`.
   * Patroni promovió a `nodo2` a nuevo Líder.
   * HAProxy detectó la conmutación en segundos y empezó a aceptar escrituras en el puerto 5000 directamente sobre `nodo2`.
3. **Prueba de Reintegración:**
   * Levantamos `patroni-nodo1` de nuevo.
   * Se reintegró como réplica vía `pg_rewind`.
   * HAProxy lo agregó de inmediato al pool de lectura del puerto 5001.
4. **Prueba de Fallo Múltiple y Contingencia (Fase 5):**
   * Apagamos `nodo1` y `nodo2` simultáneamente.
   * Las escrituras al puerto 5000 fallaron como debía ser.
   * El puerto 5001 continuó respondiendo consultas `SELECT` atendidas exclusivamente por `nodo3`.

---

# ==========================================
# RESUMEN EJECUTIVO: CÓMO EXPLICARLO AL GRUPO O AUXILIAR
# ==========================================

Si en la calificación o reunión te preguntan:  
**"¿Cómo interactúan la parte de tu compañero y la tuya?"**

> *"La capa de mi compañero (Capa A) resolvió la **persistencia y el consenso**: garantizó que PostgreSQL replique sincrónicamente entre Nodo 1 y 2, asincrónicamente a Nodo 3, y que etcd junto a Patroni elijan un nuevo líder sin intervención humana si el primario cae.*  
>  
> *Mi capa (Capa B) resolvió el **acceso y la resiliencia del cliente**: las aplicaciones no se conectan directo a las IPs de las bases de datos; se conectan a una IP Virtual (VIP) administrada por keepalived vía VRRP Unicast sobre Tailscale. Esa VIP apunta al HAProxy activo, el cual monitorea en tiempo real la API REST de Patroni en el puerto 8008. Si Patroni promueve a Nodo 2, HAProxy redirige las escrituras al nuevo líder en el puerto 5000 de forma transparente, mientras reparte las lecturas en Round-Robin en el puerto 5001. Y si el host que tiene el balanceador se apaga, keepalived migra la VIP al siguiente host en 2 segundos, eliminando cualquier punto único de fallo en la capa de red."*
