'use strict';

// ============================================================
// meteo-api — Serviço de previsão do tempo (Atividade 4 de SD)
// Node puro (sem frameworks) + cliente prom-client para /metrics.
// Endpoints de apoio aos experimentos:
//   /fail?on=N                -> agenda crash do processo (Experimento 2)
//   /busy?sec=N&spin=K        -> gera carga real de CPU (Experimento 3)
// ============================================================

const http = require('http');
const os = require('os');
const client = require('prom-client');

const PORT = parseInt(process.env.PORT || '8080', 10);
const VERSION = process.env.APP_VERSION || '1.0.0';
const START = Date.now();

// ------------------------------------------------------------
// Métricas Prometheus
// ------------------------------------------------------------
const register = new client.Registry();
client.collectDefaultMetrics({ register, prefix: 'meteoapi_' });

const httpRequests = new client.Counter({
  name: 'meteoapi_http_requests_total',
  help: 'Total de requisições HTTP recebidas',
  labelNames: ['method', 'path', 'status'],
  registers: [register],
});

const httpDuration = new client.Histogram({
  name: 'meteoapi_http_duration_seconds',
  help: 'Duração das requisições HTTP em segundos',
  labelNames: ['method', 'path', 'status'],
  registers: [register],
});

// ------------------------------------------------------------
// "Banco de dados" em memória (apenas realismo)
// ------------------------------------------------------------
const cities = {
  'sao-paulo':      { temp: 22.4, cond: 'parcialmente nublado', umid: 68 },
  'rio-de-janeiro': { temp: 31.1, cond: 'ensolarado',           umid: 74 },
  'curitiba':       { temp: 15.8, cond: 'garoa',                umid: 81 },
  'manaus':         { temp: 33.5, cond: 'abafado',              umid: 88 },
};

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json',
    'X-App-Version': VERSION,
  });
  res.end(body);
}

// ------------------------------------------------------------
// Estado do "modo falha" (Experimento 2)
// ------------------------------------------------------------
let failOn = 0;      // 0 = inativo
let failCount = 0;   // quantas respostas 200 já demos desde o armamento

function healthz(req, res) {
  if (failOn > 0 && failCount >= failOn) {
    log(`liveness: falha programada ativa => 500 (failOn=${failOn})`);
    sendJson(res, 500, { status: 'simulated failure', failOn });
    return;
  }
  if (failOn > 0) failCount++;
  sendJson(res, 200, { status: 'ok', failOn, answered: failCount });
}

function handleFail(req, res) {
  const q = new URL(req.url, 'http://x').searchParams;
  if (!q.has('on')) {
    return sendJson(res, 200, {
      message: 'modo falha',
      failOn,
      note: 'use /fail?on=N para agendar: após N respostas 200 do /healthz, ele passa a devolver 500',
    });
  }
  const on = Math.max(0, parseInt(q.get('on'), 10) || 0);
  failOn = on;
  failCount = 0;
  log(`falha agendada: /healthz começará a falhar após ${on} respostas OK`);
  sendJson(res, 202, {
    message: `ok: /healthz falhará (500) depois de ${on} chamadas OK`,
    disable: 'chame /fail?on=0 para desarmar',
  });
}

// ------------------------------------------------------------
// Carga de CPU real (Experimento 3): /busy?sec=N&spin=K
// sec  = por quantos segundos o busy-loop roda (default 120)
// spin = fração de tempo ocupado 0..1 (default 1 = 100%)
// ------------------------------------------------------------
function handleBusy(req, res) {
  const q = new URL(req.url, 'http://x').searchParams;
  const sec = Math.min(600, parseInt(q.get('sec') || '120', 10));
  let spin = parseFloat(q.get('spin') || '1');
  if (Number.isNaN(spin) || spin < 0.05) spin = 0.05;
  if (spin > 1) spin = 1;

  log(`busy-loop: ${sec}s com spin=${spin}`);
  sendJson(res, 202, { message: `carga iniciada por ${sec}s (spin=${spin})` });

  const endAt = Date.now() + sec * 1000;
  const loop = () => {
    if (Date.now() >= endAt) {
      log('busy-loop: finalizado');
      return;
    }
    const busyMs = 50 * spin;
    const idleMs = 50 - busyMs;
    const busyUntil = Date.now() + busyMs;
    while (Date.now() < busyUntil) {
      // busy-loop puro: queima CPU de verdade (nada de sleep)
      Math.sqrt(Date.now() % 100000);
    }
    setTimeout(loop, idleMs);
  };
  loop();
}

// ------------------------------------------------------------
// Roteador
// ------------------------------------------------------------
const routes = {
  '/': (req, res) => {
    sendJson(res, 200, {
      service: 'meteo-api',
      version: VERSION,
      hostname: os.hostname(),
      pod: process.env.POD_NAME || os.hostname(),
      uptime_s: Math.round((Date.now() - START) / 1000),
      note: 'Atividade 4 - Sistemas Distribuídos (Kubernetes + Prometheus)',
      endpoints: ['/healthz', '/readyz', '/metrics', '/weather?city=X', '/fail?on=N', '/busy?sec=N&spin=K'],
    });
  },
  '/readyz': (req, res) => sendJson(res, 200, { ready: true }),
  '/fail': handleFail,
  '/busy': handleBusy,
  '/weather': (req, res) => {
    const city = new URL(req.url, 'http://x').searchParams.get('city');
    const data = city && cities[city.toLowerCase()];
    if (!data) {
      return sendJson(res, 404, { error: 'cidade desconhecida', known: Object.keys(cities) });
    }
    sendJson(res, 200, { city: city.toLowerCase(), ...data, servedBy: os.hostname() });
  },
};

routes['/healthz'] = healthz;

// ------------------------------------------------------------
// Servidor
// ------------------------------------------------------------
const server = http.createServer((req, res) => {
  const path = req.url.split('?')[0];
  const start = process.hrtime.bigint();

  res.on('finish', () => {
    const durSec = Number(process.hrtime.bigint() - start) / 1e9;
    httpRequests.inc({ method: req.method, path, status: res.statusCode });
    httpDuration.observe({ method: req.method, path, status: res.statusCode }, durSec);
  });

  if (path === '/metrics') {
    register.metrics().then((body) => {
      res.writeHead(200, { 'Content-Type': register.contentType });
      res.end(body);
    });
    return;
  }

  const handler = routes[path];
  if (!handler) {
    return sendJson(res, 404, { error: 'rota inexistente', path });
  }

  try {
    handler(req, res);
  } catch (err) {
    log('erro no handler:', err.message);
    sendJson(res, 500, { error: err.message });
  }
});

server.listen(PORT, () => {
  log(`meteo-api v${VERSION} escutando na porta ${PORT} (pod=${os.hostname()})`);
});

// Encerramento graceful: SIGTERM chega quando o Kubernetes reinicia/recria o pod.
process.on('SIGTERM', () => {
  log('SIGTERM recebido: encerrando com grace');
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 5000);
});
