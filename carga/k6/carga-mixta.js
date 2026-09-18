// Fase 6 — carga mixta de lectura y escritura contra el PROXY, no contra un
// nodo directo. Escrituras por el puerto 5000 (HAProxy enruta al lider vigente)
// y lecturas por el 5001 (round-robin entre replicas).
//
// A mitad de la corrida se tumba un nodo a mano; el objetivo es que estas
// metricas muestren el hueco de indisponibilidad y la recuperacion.
import sql from 'k6/x/sql';
import driver from 'k6/x/sql/driver/postgres';
import { Trend, Counter } from 'k6/metrics';
import { sleep } from 'k6';

const HOST     = __ENV.PROXY_HOST   || 'localhost';
const P_WRITE  = __ENV.PUERTO_WRITE || '5000';
const P_READ   = __ENV.PUERTO_READ  || '5001';
const PASS     = __ENV.PGPASS       || 'postgres';
const DURACION = __ENV.DURACION     || '2m';

const dsn = (puerto) =>
  `postgres://postgres:${PASS}@${HOST}:${puerto}/postgres?sslmode=disable`;

const dbEscritura = sql.open(driver, dsn(P_WRITE));
const dbLectura   = sql.open(driver, dsn(P_READ));

// Nombres alineados con el dashboard "BD2 — Carga y fallos" de Grafana.
// Con la salida experimental-prometheus-rw llegan como k6_<nombre>_<stat>.
const escrituraDuracion = new Trend('escritura_duracion', true);
const lecturaDuracion   = new Trend('lectura_duracion', true);
const operacionesOk     = new Counter('operaciones_ok');
const operacionesError  = new Counter('operaciones_error');

export const options = {
  scenarios: {
    escritor: {
      executor: 'constant-vus',
      vus: parseInt(__ENV.VUS_ESCRITURA || '5', 10),
      duration: DURACION,
      exec: 'escribir',
    },
    lector: {
      executor: 'constant-vus',
      vus: parseInt(__ENV.VUS_LECTURA || '10', 10),
      duration: DURACION,
      exec: 'leer',
    },
  },
  // Sin umbrales que aborten: durante el failover DEBEN fallar operaciones.
  // Esa ventana de error es justamente la evidencia que se quiere medir.
  thresholds: {},
};

const aleatorio = (max) => Math.floor(Math.random() * max) + 1;

export function escribir() {
  const inicio = Date.now();
  try {
    dbEscritura.exec(
      `INSERT INTO databugs.transacciones
         (cliente_id, producto_id, cantidad, monto, origen)
       VALUES (${aleatorio(1000)}, ${aleatorio(200)}, ${aleatorio(5)},
               ${(Math.random() * 2000 + 50).toFixed(2)}, 'k6')`
    );
    escrituraDuracion.add(Date.now() - inicio);
    operacionesOk.add(1, { tipo: 'escritura' });
  } catch (e) {
    // Esperado mientras Patroni promueve un nuevo lider y HAProxy conmuta.
    operacionesError.add(1, { tipo: 'escritura' });
  }
  sleep(0.1);
}

export function leer() {
  const inicio = Date.now();
  try {
    dbLectura.query(
      `SELECT t.id, t.monto
         FROM databugs.transacciones t
        WHERE t.cliente_id = ${aleatorio(1000)}
        ORDER BY t.creado_en DESC
        LIMIT 20`
    );
    lecturaDuracion.add(Date.now() - inicio);
    operacionesOk.add(1, { tipo: 'lectura' });
  } catch (e) {
    operacionesError.add(1, { tipo: 'lectura' });
  }
  sleep(0.1);
}

export function teardown() {
  dbEscritura.close();
  dbLectura.close();
}
