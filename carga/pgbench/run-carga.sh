#!/usr/bin/env bash
# Generador de carga con pgbench para la Fase 6 del enunciado.
#
# pgbench viene dentro de la imagen de Postgres que ya usa el proyecto, asi que
# no hay nada que instalar ni compilar: es el camino garantizado. k6 + xk6-sql
# (carga/k6/) da la integracion con Grafana; esto da los numeros duros.
#
# Uso:
#   ./run-carga.sh escritura  [segundos] [clientes]
#   ./run-carga.sh lectura    [segundos] [clientes]
#   ./run-carga.sh mixta      [segundos] [clientes]   # escritura y lectura en paralelo
#
# Variables de entorno (o toma los valores de .env):
#   PGHOST_PROXY   host donde corre HAProxy      (default: localhost)
#   PUERTO_WRITE   puerto de escritura           (default: 5000)
#   PUERTO_READ    puerto de lectura             (default: 5001)
#   SUPERUSER_PASSWORD  contrasena de postgres
set -euo pipefail

MODO="${1:-mixta}"
DURACION="${2:-120}"
CLIENTES="${3:-10}"

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Lo que venga del entorno gana sobre .env: asi se puede apuntar a otro proxy o
# usar las credenciales de la simulacion local sin editar el .env del cluster.
_HOST="${PGHOST_PROXY:-}"; _PW="${PUERTO_WRITE:-}"
_PR="${PUERTO_READ:-}";   _PASS="${SUPERUSER_PASSWORD:-}"
[ -f "$RAIZ/.env" ] && { set -a; . "$RAIZ/.env"; set +a; }

HOST="${_HOST:-${PGHOST_PROXY:-localhost}}"
P_WRITE="${_PW:-${PUERTO_WRITE:-5000}}"
P_READ="${_PR:-${PUERTO_READ:-5001}}"
PASS="${_PASS:-${SUPERUSER_PASSWORD:-postgres}}"
SALIDA="$RAIZ/carga/resultados"
mkdir -p "$SALIDA"
SELLO="$(date +%Y%m%d-%H%M%S)"

command -v pgbench >/dev/null 2>&1 || {
    echo "ERROR: pgbench no esta instalado en este host." >&2
    echo "  Debian/Ubuntu:  sudo apt install postgresql-client-common postgresql-client" >&2
    exit 1
}

correr() {
    local etiqueta="$1" puerto="$2" script="$3" archivo
    archivo="$SALIDA/${SELLO}_${etiqueta}.txt"
    {
        echo "== pgbench: $etiqueta =="
        echo "inicio     : $(date -Ins)"
        echo "destino    : $HOST:$puerto"
        echo "duracion   : ${DURACION}s | clientes: $CLIENTES"
        echo "---------------------------------------------"
    } | tee "$archivo"

    PGPASSWORD="$PASS" pgbench \
        -h "$HOST" -p "$puerto" -U postgres -d postgres \
        --no-vacuum \
        --client="$CLIENTES" --jobs=2 \
        --time="$DURACION" \
        --progress=10 \
        --file="$script" 2>&1 | tee -a "$archivo"

    echo "fin        : $(date -Ins)" | tee -a "$archivo"
    echo "resultado guardado en: $archivo"
}

echo "###############################################################"
echo "# Fase 6 — carga '$MODO' durante ${DURACION}s con $CLIENTES clientes"
echo "# Marca de inicio (para el RTO de la bitacora): $(date -Ins)"
echo "###############################################################"

case "$MODO" in
    escritura) correr escritura "$P_WRITE" "$RAIZ/carga/pgbench/escritura.sql" ;;
    lectura)   correr lectura   "$P_READ"  "$RAIZ/carga/pgbench/lectura.sql" ;;
    mixta)
        # Escritura y lectura en paralelo, que es el escenario realista:
        # mientras se tumba un nodo se observan ambas curvas a la vez.
        correr escritura "$P_WRITE" "$RAIZ/carga/pgbench/escritura.sql" &
        PID_W=$!
        correr lectura "$P_READ" "$RAIZ/carga/pgbench/lectura.sql" &
        PID_R=$!
        wait $PID_W $PID_R
        ;;
    *) echo "modo desconocido: $MODO (usa escritura | lectura | mixta)" >&2; exit 1 ;;
esac

echo "# Marca de fin: $(date -Ins)"
