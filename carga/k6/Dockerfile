# Construye un binario propio de k6 con la extension xk6-sql y el driver de
# PostgreSQL. k6 no habla SQL de fabrica: solo HTTP/gRPC/WebSocket.
# Si esta construccion falla (necesita descargar modulos de Go), el plan B es
# carga/pgbench/run-carga.sh, que no requiere compilar nada.
FROM golang:1.26-bookworm AS build
RUN go install go.k6.io/xk6/cmd/xk6@latest
RUN xk6 build \
        --with github.com/grafana/xk6-sql@v0.4.1 \
        --with github.com/grafana/xk6-sql-driver-postgres@v0.1.0 \
        --output /k6

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /k6 /usr/local/bin/k6
ENTRYPOINT ["k6"]
