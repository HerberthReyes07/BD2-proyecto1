-- Dataset de prueba — Proyecto 1 BD2, Grupo 5
-- Modela la plataforma de "Data Bug's" del enunciado: clientes que generan
-- transacciones sobre productos. Se carga UNA sola vez a traves del puerto
-- 5000 del proxy (escritura), por lo que aterriza en el lider y se replica
-- a nodo2 (sincrono) y nodo3 (asincrono).

CREATE SCHEMA IF NOT EXISTS databugs;

CREATE TABLE IF NOT EXISTS databugs.clientes (
    id          serial PRIMARY KEY,
    nombre      text        NOT NULL,
    correo      text        NOT NULL,
    creado_en   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS databugs.productos (
    id          serial PRIMARY KEY,
    nombre      text           NOT NULL,
    precio      numeric(10,2)  NOT NULL,
    existencias integer        NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS databugs.transacciones (
    id          bigserial PRIMARY KEY,
    cliente_id  integer     NOT NULL REFERENCES databugs.clientes(id),
    producto_id integer     NOT NULL REFERENCES databugs.productos(id),
    cantidad    integer     NOT NULL,
    monto       numeric(12,2) NOT NULL,
    origen      text        NOT NULL DEFAULT 'carga',
    creado_en   timestamptz NOT NULL DEFAULT now()
);

-- Indices pensados para que las consultas de lectura de la prueba de carga
-- no degeneren en seq scans y midan realmente la latencia de la arquitectura.
CREATE INDEX IF NOT EXISTS idx_tx_cliente  ON databugs.transacciones(cliente_id);
CREATE INDEX IF NOT EXISTS idx_tx_creado   ON databugs.transacciones(creado_en DESC);

-- Semilla: 1000 clientes y 200 productos.
INSERT INTO databugs.clientes (nombre, correo)
SELECT 'Cliente ' || i, 'cliente' || i || '@databugs.test'
FROM generate_series(1, 1000) AS i
WHERE NOT EXISTS (SELECT 1 FROM databugs.clientes);

INSERT INTO databugs.productos (nombre, precio, existencias)
SELECT 'Producto ' || i, (random() * 500 + 10)::numeric(10,2), (random() * 1000)::int
FROM generate_series(1, 200) AS i
WHERE NOT EXISTS (SELECT 1 FROM databugs.productos);

-- Semilla de transacciones para que las lecturas tengan volumen que recorrer.
INSERT INTO databugs.transacciones (cliente_id, producto_id, cantidad, monto, origen)
SELECT (random() * 999 + 1)::int, (random() * 199 + 1)::int,
       (random() * 5 + 1)::int, (random() * 2000 + 50)::numeric(12,2), 'semilla'
FROM generate_series(1, 20000)
WHERE NOT EXISTS (SELECT 1 FROM databugs.transacciones);

-- Tabla dedicada a la bitacora de pruebas de falla: cada INSERT lleva marca de
-- tiempo del servidor, lo que permite calcular el RPO comparando el ultimo
-- registro escrito antes de la caida contra lo que sobrevivio (Fase 8).
CREATE TABLE IF NOT EXISTS databugs.bitacora_pruebas (
    id         bigserial PRIMARY KEY,
    fase       text        NOT NULL,
    nota       text,
    servidor   inet        NOT NULL DEFAULT inet_server_addr(),
    creado_en  timestamptz NOT NULL DEFAULT clock_timestamp()
);
