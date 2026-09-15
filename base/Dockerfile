# Imagen base para un nodo del cluster: Postgres + Patroni en el mismo contenedor.
# etcd corre en un contenedor APARTE, construido desde Dockerfile.etcd.
FROM postgres:16

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3-pip python3-venv curl gettext-base \
    && pip install --break-system-packages --no-cache-dir "patroni[etcd3]" psycopg2-binary \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /data/postgres \
    && chmod 0700 /data/postgres \
    && chown -R postgres:postgres /data/postgres

# Plantilla compartida (igual para los 3 nodos): la seccion "bootstrap"
# (solo se usa la primera vez que el cluster nace) y "tags" (nofailover,
# nosync -- estos NO se pueden pasar por variables PATRONI_* sueltas,
# hay que ponerlos directo en el archivo de config).
COPY bootstrap.yml.template /bootstrap.yml.template
COPY entrypoint.sh /entrypoint.sh
RUN chmod 644 /bootstrap.yml.template && chmod 755 /entrypoint.sh

USER postgres
ENTRYPOINT ["/entrypoint.sh"]