-- Script de LECTURA para pgbench. Se ejecuta contra el puerto 5001 del proxy,
-- que balancea en round-robin entre las replicas disponibles.
\set cliente random(1, 1000)
SELECT t.id, t.monto, c.nombre, p.nombre
FROM databugs.transacciones t
JOIN databugs.clientes  c ON c.id = t.cliente_id
JOIN databugs.productos p ON p.id = t.producto_id
WHERE t.cliente_id = :cliente
ORDER BY t.creado_en DESC
LIMIT 20;
