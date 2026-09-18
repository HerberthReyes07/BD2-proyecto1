-- Script de ESCRITURA para pgbench. Se ejecuta contra el puerto 5000 del proxy,
-- que HAProxy enruta siempre al lider vigente (GET /primary).
\set cliente  random(1, 1000)
\set producto random(1, 200)
\set cantidad random(1, 5)
BEGIN;
INSERT INTO databugs.transacciones (cliente_id, producto_id, cantidad, monto, origen)
VALUES (:cliente, :producto, :cantidad, (:cantidad * 99.90)::numeric(12,2), 'pgbench');
COMMIT;
