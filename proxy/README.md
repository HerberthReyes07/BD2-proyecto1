# `proxy/` — Capa de Proxy y Alta Disponibilidad (HAProxy + keepalived)

Contiene la configuración, templates e imágenes para el enrutamiento inteligente de conexiones hacia PostgreSQL y la alta disponibilidad del proxy mediante una IP Virtual (VIP) con VRRP en modo Unicast sobre Tailscale. Corre de forma **simétrica en los 3 nodos**: cada uno tiene su propio HAProxy y su propio keepalived, compitiendo por la misma VIP.

Los `docker-compose*.yml` que se ejecutan viven en la raíz del repositorio; esta carpeta contiene los `Dockerfile`, templates y scripts de arranque que esos compose referencian.

## Contenido

| Archivo | Rol |
|---|---|
| `Dockerfile` | Imagen de HAProxy 2.8 (`haproxy:2.8-alpine`) + `entrypoint.sh`. |
| `haproxy.cfg.template` | Configuración de HAProxy con placeholders `${IP_NODO1..3}`, sustituidos por `envsubst` al arrancar. |
| `entrypoint.sh` | Genera `haproxy.cfg` real desde el template y arranca `haproxy`. |
| `Dockerfile.keepalived` | Imagen basada en `alpine:3.20` + paquete `keepalived`. |
| `keepalived.conf.template` | Configuración de la instancia VRRP, con placeholders sustituidos por `entrypoint-keepalived.sh`. |
| `entrypoint-keepalived.sh` | Autoasigna prioridad/estado/peers VRRP según `NODE_NAME`, genera `keepalived.conf`, y arranca `keepalived`. |
| `check_haproxy.sh` | Script de salud que usa keepalived (`vrrp_script`) para verificar que el HAProxy local siga vivo. |

## Arquitectura y componentes

| Componente | Rol | Mecanismo |
|---|---|---|
| **HAProxy** | Enrutamiento de conexiones hacia la base de datos | Consulta la API REST de Patroni (`:8008`) en tiempo real |
| **keepalived** | Evita que el propio HAProxy sea un punto único de fallo (SPOF) | Mantiene una VIP compartida mediante VRRP en modo **Unicast** |

### Puertos expuestos (en cada nodo)

* **`5000` — Escritura / Primario:** backend `postgres_write_back`, `option httpchk GET /primary`. Solo el Líder de Patroni responde `200 OK`. Incluye `on-marked-down shutdown-sessions` para cerrar de inmediato conexiones colgadas cuando un primario cae.
* **`5001` — Lectura / Réplicas:** backend `postgres_read_back`, `option httpchk GET /replica`. Distribuye tráfico de lectura en **Round-Robin** entre las réplicas activas.
* **`7000` — Dashboard de estadísticas:** `http://<IP>:7000/`. Estado de salud de cada nodo (verde = UP, rojo = DOWN).

### keepalived — VIP sobre Tailscale

VRRP usa multicast (`224.0.0.18`) por defecto, **no soportado por redes overlay como Tailscale**. Se resolvió con:

1. **Modo Unicast:** `unicast_src_ip` (esta máquina) + `unicast_peer` (las otras dos, explícitas por IP de Tailscale) en vez de multicast.
2. **Prioridades VRRP:** Nodo 1 = `150` (MASTER inicial) · Nodo 2 = `100` (BACKUP 1) · Nodo 3 = `50` (BACKUP 2, contingencia). Autoasignadas por `entrypoint-keepalived.sh` según `NODE_NAME` (override manual vía `KEEPALIVED_PRIORITY`).
3. **Monitoreo de HAProxy:** `check_haproxy.sh` verifica cada 2 segundos (`vrrp_script`, `interval 2`) que HAProxy responda en `:7000`. Si cae en el nodo que tiene la VIP, esta se cede al siguiente nodo vivo.

## Variables de entorno relevantes (`.env`)

| Variable | Uso |
|---|---|
| `VIRTUAL_IP` | IP virtual compartida (igual en los 3 `.env`), por defecto `100.124.30.200`. |
| `KEEPALIVED_INTERFACE` | Interfaz de red donde vive la VIP, por defecto `tailscale0`. |
| `KEEPALIVED_PRIORITY` | Opcional; si se omite se autoasigna (150/100/50) según `NODE_NAME`. |
| `NODE_NAME`, `MY_TAILSCALE_IP`, `IP_NODO1..3` | Compartidas con la capa de datos (ver [`base/README.md`](../base/README.md)). |

## Operación

Levantar junto con la base de datos:

```bash
docker compose --profile nodo-bd up -d --build
```

Levantar o reiniciar solo el proxy (sin tocar la base de datos):

```bash
docker compose --profile proxy up -d --build
```

Verificar: los 4 contenedores (`etcd`, `patroni`, `haproxy`, `keepalived`) arriba con `docker compose ps`, y `http://localhost:7000/` mostrando `postgres_write_back` con solo el Líder en verde y `postgres_read_back` con las réplicas en verde.

## Troubleshooting

* **El dashboard en `:7000` muestra los servidores en rojo:** verificar que Patroni escuche en el puerto `8008` del host: `curl http://<IP_TAILSCALE>:8008/primary` (200 en el líder, 503 en réplicas).
* **`Address already in use` en 5000/5001/7000:** `ss -lntp | grep -E '5000|5001|7000'`.
* **keepalived no levanta la VIP:** confirmar permisos de red del contenedor (`cap_add: [NET_ADMIN, NET_RAW, NET_BROADCAST]`) y que la interfaz coincida con `ip -br addr` (habitualmente `tailscale0`).
* **La VIP no responde entre nodos:** Tailscale solo enruta IPs registradas en la tailnet; una VIP "inventada" sale por el gateway por defecto y no viaja entre hosts. Probarla explícitamente antes de asumir que funciona.
* **`docker kill` revive el contenedor en vez de simular una caída:** los servicios llevan `restart: unless-stopped`; usar `docker compose stop` o `sudo tailscale down` en el nodo para simular una caída abrupta real.

Las pruebas de integración de esta capa (Fases 3, 4 y 5 del enunciado) están documentadas de forma consolidada en el [README.md](../README.md) principal, junto con las del resto de capas.
