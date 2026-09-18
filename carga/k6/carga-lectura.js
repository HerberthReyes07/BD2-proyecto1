// Fase 6, escenario 3 / Fase 5 — contingencia: nodo1 y nodo2 caidos.
// Solo lectura por el puerto 5001, que debe seguir respondiendo atendido
// exclusivamente por nodo3. Las escrituras deben estar bloqueadas.
import sql from 'k6/x/sql';
import driver from 'k6/x/sql/driver/postgres';
import { Trend, Counter } from 'k6/metrics';
import { sleep } from 'k6';

const HOST     = __ENV.PROXY_HOST  || 'localhost';
const P_READ   = __ENV.PUERTO_READ || '5001';
const PASS     = __ENV.PGPASS      || 'postgres';
const DURACION = __ENV.DURACION    || '1m';

const dbLectura = sql.open(
  driver,
  `postgres://postgres:${PASS}@${HOST}:${P_READ}/postgres?sslmode=disable`
);

const lecturaDuracion  = new Trend('lectura_duracion', true);
const operacionesOk    = new Counter('operaciones_ok');
const operacionesError = new Counter('operaciones_error');

export const options = {
  scenarios: {
    lector: {
      executor: 'constant-vus',
      vus: parseInt(__ENV.VUS_LECTURA || '10', 10),
      duration: DURACION,
      exec: 'leer',
    },
  },
  thresholds: {},
};

export function leer() {
  const inicio = Date.now();
  try {
    dbLectura.query(
      `SELECT count(*) FROM databugs.transacciones
        WHERE cliente_id = ${Math.floor(Math.random() * 1000) + 1}`
    );
    lecturaDuracion.add(Date.now() - inicio);
    operacionesOk.add(1, { tipo: 'lectura' });
  } catch (e) {
    operacionesError.add(1, { tipo: 'lectura' });
  }
  sleep(0.1);
}

export function teardown() { dbLectura.close(); }
