# proxy/ — Capa de Proxy y Alta Disponibilidad (HAProxy + keepalived)

Contiene la configuración, templates e imágenes para el enrutamiento inteligente de conexiones hacia PostgreSQL y la alta disponibilidad del proxy mediante una IP Virtual (VIP) con VRRP en modo Unicast sobre Tailscale.

---

## 1. Arquitectura y Componentes

| Componente | Rol en la arquitectura | Mecanismo |
|---|---|---|
| **HAProxy** | Enrutamiento de conexiones hacia la base de datos | Consulta la API REST de Patroni (`:8008`) en tiempo real |
| **keepalived** | Evita que el propio HAProxy sea un punto único de fallo (SPOF) | Mantiene una VIP compartida mediante VRRP en modo **Unicast** |

### Puertos Expuestos

* **Puerto `5000` (Escritura / Primario):**
  * Backend `postgres_write_back` con `option httpchk GET /primary`.
  * Solo el nodo que sea actualmente Líder del clúster de Patroni responderá `HTTP 200 OK`.
  * Incluye `on-marked-down shutdown-sessions` para cerrar de inmediato conexiones inactivas cuando un primario cae.
* **Puerto `5001` (Lectura / Réplicas):**
  * Backend `postgres_read_back` con `option httpchk GET /replica`.
  * Distribuye el tráfico de lectura en modo **Round-Robin** entre las réplicas activas sincronizadas.
* **Puerto `7000` (Dashboard de Estadísticas en Vivo):**
  * Interfaz web en tiempo real: `http://localhost:7000/` o `http://<IP_TAILSCALE>:7000/`.
  * Muestra el estado de salud de cada nodo (verde = UP, rojo = DOWN).

---

## 2. Configuración de keepalived (VIP sobre Tailscale)

Por defecto, VRRP usa multicast (`224.0.0.18`), el cual **no es soportado por redes overlay como Tailscale**. Para resolver esto:

1. **Modo Unicast:** `keepalived` se configuró con `unicast_src_ip` y `unicast_peer`, enviando latidos directamente a las IPs de Tailscale de los compañeros.
2. **Prioridades VRRP pactadas:**
   * **Nodo 1:** Prioridad `150` (MASTER inicial).
   * **Nodo 2:** Prioridad `100` (BACKUP 1, asume si cae Nodo 1).
   * **Nodo 3:** Prioridad `50` (BACKUP 2, contingencia).
3. **Monitoreo de HAProxy:** El script `check_haproxy.sh` verifica cada 2 segundos que HAProxy responda. Si el proceso cae en el nodo que tiene la VIP, cede la IP virtual inmediatamente al siguiente nodo vivo.

---

## 3. Guía Rápida para el Equipo (Despliegue Distribuido)

Cada integrante ejecuta esto en su propia máquina física:

### Paso 1 — Actualizar el repositorio y variables de entorno
```bash
git pull origin main
```
Revisar tu archivo `.env` y asegurar que contiene la sección de la Capa B:
```bash
# --- Configuración del Proxy y Alta Disponibilidad (Capa B) ---
VIRTUAL_IP=100.124.30.200
KEEPALIVED_INTERFACE=tailscale0
# KEEPALIVED_PRIORITY se autoasigna según tu NODE_NAME (150, 100 o 50)
```

### Paso 2 — Levantar el clúster con la capa de proxy
Para levantar la base de datos junto con el proxy (en un solo comando):
```bash
docker compose --profile nodo-bd up -d --build
```
*(Si solo deseas levantar o reiniciar la capa del proxy por separado:)*
```bash
docker compose --profile proxy up -d --build
```

### Paso 3 — Verificar estado
Revisar que los 4 contenedores (`etcd`, `patroni`, `haproxy`, `keepalived`) estén arriba:
```bash
docker compose ps
```
Acceder al navegador en `http://localhost:7000/` para confirmar que el dashboard de HAProxy reporta:
* `postgres_write_back`: Solo el Líder en verde (UP).
* `postgres_read_back`: Las réplicas en verde (UP).

---

## 4. Guía de Pruebas para la Sesión en Vivo (Fases 3, 4 y 5)

Estas pruebas se ejecutan durante la reunión de integración del grupo, registrando capturas de pantalla y tiempos para la bitácora:

### Prueba A — Validación de Enrutamiento y Balanceo Normal (Fase 2)
1. **Escritura por puerto 5000:**
   ```bash
   PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5000 -U postgres -c \
     "CREATE TABLE IF NOT EXISTS test_bitacora (id serial primary key, msg text);
      INSERT INTO test_bitacora (msg) VALUES ('prueba normal');"
   ```
2. **Lectura balanceada por puerto 5001:**
   ```bash
   for i in {1..4}; do
     PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5001 -U postgres -c \
       "SELECT inet_server_addr(), * FROM test_bitacora;"
   done
   ```
   *Resultado esperado:* Alternancia de IPs entre las réplicas en cada iteración.
3. **Validación de solo lectura en 5001:**
   ```bash
   PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5001 -U postgres -c \
     "INSERT INTO test_bitacora (msg) VALUES ('falla');"
   # Esperado: ERROR: cannot execute INSERT in a read-only transaction
   ```

---

### Prueba B — Caída y Failover de Nodo 1 (Fase 3 del enunciado)
1. **Simular caída:** En la máquina de **Nodo 1**, detener Patroni:
   ```bash
   docker compose stop patroni
   ```
2. **Verificar failover en Patroni:** En Nodo 2 o 3:
   ```bash
   docker compose exec patroni patronictl list
   # Esperado: Nodo 2 asciende a Leader (TL incrementa).
   ```
3. **Verificar detección en HAProxy:**
   * En el dashboard `http://localhost:7000/`, `nodo1` pasa a rojo y `nodo2` pasa a verde en `postgres_write_back`.
4. **Escribir a través del proxy:**
   ```bash
   PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5000 -U postgres -c \
     "INSERT INTO test_bitacora (msg) VALUES ('escritura tras failover a nodo 2');
      SELECT inet_server_addr(), * FROM test_bitacora;"
   ```
   *Resultado esperado:* Inserción exitosa atendida por la IP de Nodo 2.
5. **Reintegrar Nodo 1:**
   ```bash
   docker compose start patroni
   docker compose exec patroni patronictl list
   # Esperado: Nodo 1 se reintegra como Replica usando pg_rewind.
   ```

---

### Prueba C — Caída de Nodo 2 (Fase 4 del enunciado)
1. Con Nodo 1 como Líder activo (o promovido nuevamente):
   ```bash
   docker compose stop patroni  # en Nodo 2
   ```
2. Ejecutar escrituras y lecturas en el proxy:
   ```bash
   PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5000 -U postgres -c \
     "INSERT INTO test_bitacora (msg) VALUES ('escritura con nodo 2 caido');"
   ```
3. Reactivar Nodo 2 y confirmar sincronización:
   ```bash
   docker compose start patroni
   ```

---

### Prueba D — Fallo Múltiple y Modo Contingencia (Fase 5 del enunciado)
1. Detener simultáneamente los servicios de base de datos en **Nodo 1 y Nodo 2**:
   ```bash
   docker compose stop patroni  # en Nodo 1 y Nodo 2
   ```
2. **Comprobar que las escrituras se bloquean:**
   ```bash
   PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5000 -U postgres -c \
     "INSERT INTO test_bitacora (msg) VALUES ('no debe permitir');"
   # Esperado: Conexión rechazada / error de servidor no disponible.
   ```
3. **Comprobar modo contingencia en Nodo 3:**
   ```bash
   PGPASSWORD=$SUPERUSER_PASSWORD psql -h localhost -p 5001 -U postgres -c \
     "SELECT inet_server_addr(), * FROM test_bitacora;"
   ```
   *Resultado esperado:* Consulta exitosa atendida exclusivamente por **Nodo 3** en modo de solo lectura.
4. **Recuperación total:**
   ```bash
   docker compose start patroni  # en Nodo 1 y Nodo 2
   ```
   Verificar con `patronictl list` que los 3 nodos vuelven a sincronizarse al 100%.

---

## 5. Plantilla para la Bitácora de Pruebas

Durante la sesión en vivo, registren cada acción con este formato para el informe final:

| Fecha y Hora | Fase | Nodo / Componente | Acción Realizada | Resultado Esperado | Resultado Obtenido | RTO (Tiempo Recup.) | Evidencia (Captura) |
|---|---|---|---|---|---|---|---|
| YYYY-MM-DD HH:MM | Fase 3 | Nodo 1 (Líder) | `docker compose stop patroni` | Failover a Nodo 2; HAProxy conmuta puerto 5000 | Conexión redirigida a Nodo 2; INSERT exitoso | ~15-20 s | `evidencias/fase3_failover.png` |
| YYYY-MM-DD HH:MM | Fase 3 | Nodo 1 | `docker compose start patroni` | Reintegración como réplica con pg_rewind | Nodo 1 streaming lag 0; balancea en puerto 5001 | ~8 s | `evidencias/fase3_reintegro.png` |
| YYYY-MM-DD HH:MM | Fase 4 | Nodo 2 | `docker compose stop patroni` | Nodo 1 atiende escrituras; servicio continuo | Sin interrupción en puerto 5000 | Inmediato | `evidencias/fase4_nodo2_down.png` |
| YYYY-MM-DD HH:MM | Fase 5 | Nodos 1 y 2 | Apagado simultáneo de N1 y N2 | Bloqueo de escritura; Nodo 3 atiende SELECTs | Puerto 5000 DOWN; Puerto 5001 responde SELECTs | N/A (Contingencia) | `evidencias/fase5_contingencia.png` |

---

## 6. Troubleshooting

* **El dashboard en `:7000` muestra los servidores en rojo:**
  Verificar que Patroni esté escuchando en el puerto `8008` del host:
  `curl http://<IP_TAILSCALE>:8008/primary` (debe responder 200 en el líder y 503 en réplicas).
* **El puerto 5000 o 5001 dice "Address already in use":**
  Verificar si hay otro proceso ocupando los puertos:
  `ss -lntp | grep -E '5000|5001|7000'`
* **keepalived no levanta la VIP:**
  Asegurar que el contenedor tenga permisos de red en Docker (`cap_add: [NET_ADMIN, NET_RAW, NET_BROADCAST]`) y que la interfaz coincida con `ip -br addr` (habitualmente `tailscale0`).
