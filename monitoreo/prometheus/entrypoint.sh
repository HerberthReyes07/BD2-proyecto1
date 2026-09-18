#!/bin/sh
# Genera prometheus.yml a partir de variables de entorno, para que el MISMO
# stack sirva en la simulacion local (nombres de contenedor) y en el despliegue
# distribuido (IPs de Tailscale), sin mantener dos configuraciones a mano.
#
# Cada job etiqueta sus series con nodo="nodo1|nodo2|nodo3", que es la etiqueta
# sobre la que se construyen todos los paneles de Grafana.
set -e

OUT=/tmp/prometheus.yml

# Destinos por job. En distribuido las 3 direcciones son las mismas IPs de
# Tailscale (cambia el puerto); en local-sim son contenedores distintos.
PATRONI_NODO1="${PATRONI_NODO1:-100.67.149.67:8008}"
PATRONI_NODO2="${PATRONI_NODO2:-100.124.30.113:8008}"
PATRONI_NODO3="${PATRONI_NODO3:-100.126.127.120:8008}"
NODEEXP_NODO1="${NODEEXP_NODO1:-100.67.149.67:9100}"
NODEEXP_NODO2="${NODEEXP_NODO2:-100.124.30.113:9100}"
NODEEXP_NODO3="${NODEEXP_NODO3:-100.126.127.120:9100}"
PGEXP_NODO1="${PGEXP_NODO1:-100.67.149.67:9187}"
PGEXP_NODO2="${PGEXP_NODO2:-100.124.30.113:9187}"
PGEXP_NODO3="${PGEXP_NODO3:-100.126.127.120:9187}"

emit_job() {
    job="$1"; t1="$2"; t2="$3"; t3="$4"; extra="$5"
    cat >> "$OUT" <<JOB

  - job_name: '${job}'
    scrape_timeout: 4s
${extra}    static_configs:
      - targets: ['${t1}']
        labels: { nodo: 'nodo1' }
      - targets: ['${t2}']
        labels: { nodo: 'nodo2' }
      - targets: ['${t3}']
        labels: { nodo: 'nodo3' }
JOB
}

cat > "$OUT" <<'HEAD'
# ARCHIVO GENERADO por monitoreo/prometheus/entrypoint.sh. No editar a mano:
# se regenera en cada arranque del contenedor a partir del entorno.
global:
  scrape_interval: 5s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['127.0.0.1:9090']
HEAD

# Patroni expone /metrics de forma nativa en su puerto REST (8008). De aqui
# salen rol, estado de Postgres, timeline y posiciones de WAL (lag).
emit_job patroni "$PATRONI_NODO1" "$PATRONI_NODO2" "$PATRONI_NODO3" ""
# node_exporter: CPU, memoria, disco y red del host de cada nodo.
emit_job node "$NODEEXP_NODO1" "$NODEEXP_NODO2" "$NODEEXP_NODO3" ""
# postgres_exporter: conexiones, transacciones y tamano de la base.
emit_job postgres "$PGEXP_NODO1" "$PGEXP_NODO2" "$PGEXP_NODO3" ""

echo "--- prometheus.yml generado ---"
cat "$OUT"
echo "-------------------------------"

exec /bin/prometheus \
    --config.file="$OUT" \
    --storage.tsdb.path=/prometheus \
    --storage.tsdb.retention.time=15d \
    --web.enable-remote-write-receiver \
    --web.enable-lifecycle
