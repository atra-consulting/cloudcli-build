// =============================================================================
// Wächter vor CloudCLI im Platform-Modus.
//
// Im Platform-Modus prüft CloudCLI weder Anmeldung noch Herkunft einer Anfrage
// (CORS offen, WebSocket ohne Origin-Prüfung, /api/agent ohne Key). Coder
// lässt nur den Besitzer des Platzes an die App, sein Browser schickt das
// Coder-Cookie aber auch bei Anfragen, die eine andere Seite derselben Site
// auslöst (z. B. die App eines anderen Teilnehmers unter *.<coder-domain>).
// Ohne Prüfung könnte so eine Seite Terminal und Agent des Platzes benutzen.
//
// Dieser Wächter startet CloudCLI als Kindprozess auf einem internen Port
// und nimmt selbst die Anfragen an. CloudCLI lauscht auf 127.0.0.3, nicht auf
// 127.0.0.1: Die Port-Weiterleitung von Coder (<port>--<agent>--…) verbindet
// sich immer mit 127.0.0.1:<port> und käme so nicht am Wächter vorbei.
// Der Wächter reicht Anfragen weiter, außer:
//   - Host ist weder der Host der App (<prefix><…><suffix>, z. B.
//     cloudcli--main--platz--user.coder.example) noch lokal (127.0.0.1,
//     localhost, [::1]). Damit führt eine Port-Freigabe des Wächter-Ports
//     (3001--…, auch „public“) nicht zu CloudCLI. Coder reicht den Host der
//     Anfrage unverändert durch und leitet nach ihm weiter. Die Endung schützt
//     vor fremden Namen wie cloudcli--x.example, die per DNS auf 127.0.0.1
//     zeigen (DNS-Rebinding mit einem Browser auf dem Platz).
//   - mehrere Host-Zeilen, Anfrage-Ziel nicht in der Form /pfad
//   - Browser-Anfragen von einer anderen Seite (Sec-Fetch-Site same-site oder
//     cross-site). Erlaubt bleibt nur das Öffnen der App als Seite (GET,
//     Navigation, auch über den Service Worker, kein iframe).
//   - Browser ohne Fetch Metadata: Origin muss zum Host passen.
//   - Registrierung und Login aus dem Browser. Im Platform-Modus braucht sie
//     niemand; den Benutzer legt cloudcli-ensure-user lokal an.
// Anfragen ohne Browser-Merkmale (curl, Coder-Healthcheck) gehen sonst durch.
//
// Der Quellcode von CloudCLI bleibt unverändert. Nur Node-Bordmittel.
//
// Umgebung:
//   CLOUDCLI_HOST           Adresse des Wächters, Standard 127.0.0.1. Eine andere
//                           Adresse nur mit CLOUDCLI_ALLOW_ANY_HOST=1.
//   SERVER_PORT             Port des Wächters, Standard 3001
//   CLOUDCLI_INTERNAL_PORT  Port von CloudCLI auf 127.0.0.3, Standard 13001
//   CLOUDCLI_APP_HOST_PREFIX  Anfang des Hosts der Coder-App: Slug mit „--“,
//                           z. B. cloudcli--
//   CLOUDCLI_APP_HOST_SUFFIX  Ende des Hosts der Coder-App: Punkt und Domain der
//                           Wildcard-Apps, z. B. .coder.example
//   CLOUDCLI_ALLOW_ANY_HOST=1 keine Host-Prüfung, nur lokal im Container
//                           (run-local.sh). Ohne diese Variable startet der
//                           Wächter nur mit PREFIX und SUFFIX.
// Die allgemeine Variable HOST wird bewusst ignoriert: CloudCLI würde sonst
// mit einem geerbten HOST=0.0.0.0 ohne Login auf allen Adressen lauschen.
// =============================================================================
import { spawn } from 'node:child_process';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const bundle = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function port(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1 || n > 65535) {
    console.error(`cloudcli-guard: ${name} ist kein gültiger Port: ${raw}`);
    process.exit(2);
  }
  return n;
}

const listenHost = process.env.CLOUDCLI_HOST || '127.0.0.1';
const listenPort = port('SERVER_PORT', 3001);
const innerHost = '127.0.0.3';
const appHostPrefix = (process.env.CLOUDCLI_APP_HOST_PREFIX || '').toLowerCase();
const appHostSuffix = (process.env.CLOUDCLI_APP_HOST_SUFFIX || '').toLowerCase();
const allowAnyHost = process.env.CLOUDCLI_ALLOW_ANY_HOST === '1';
if (allowAnyHost) {
  if (appHostPrefix || appHostSuffix) {
    console.error('cloudcli-guard: CLOUDCLI_ALLOW_ANY_HOST=1 schließt CLOUDCLI_APP_HOST_PREFIX und _SUFFIX aus');
    process.exit(2);
  }
} else {
  if (!/^[a-z0-9-]+--$/.test(appHostPrefix)) {
    console.error(`cloudcli-guard: CLOUDCLI_APP_HOST_PREFIX fehlt oder hat nicht die Form <slug>--: ${appHostPrefix}`);
    process.exit(2);
  }
  // Auf einer anderen Adresse könnte jeder Client den Host der App vortäuschen
  if (listenHost !== '127.0.0.1') {
    console.error(`cloudcli-guard: CLOUDCLI_HOST=${listenHost} nur mit CLOUDCLI_ALLOW_ANY_HOST=1 (Container)`);
    process.exit(2);
  }
  if (!/^(\.[a-z0-9-]+){2,}$/.test(appHostSuffix)) {
    console.error(`cloudcli-guard: CLOUDCLI_APP_HOST_SUFFIX fehlt oder hat nicht die Form .<domain>: ${appHostSuffix}`);
    process.exit(2);
  }
}
const innerPort = port('CLOUDCLI_INTERNAL_PORT', 13001);
if (innerPort === listenPort) {
  console.error('cloudcli-guard: CLOUDCLI_INTERNAL_PORT und SERVER_PORT müssen verschieden sein');
  process.exit(2);
}

// --- Regeln -------------------------------------------------------------------

const BROWSER_FORBIDDEN_PATHS = new Set(['/api/auth/register', '/api/auth/login']);
const HOP_BY_HOP = ['connection', 'keep-alive', 'proxy-connection', 'upgrade', 'te', 'trailer'];
const LOCAL_HOSTNAMES = new Set(['127.0.0.1', 'localhost', '[::1]']);

/** Hostname ohne Port, klein geschrieben. */
function hostnameOf(host) {
  const h = String(host ?? '').trim().toLowerCase();
  if (h.startsWith('[')) return h.slice(0, h.indexOf(']') + 1);
  return h.replace(/:\d*$/, '');
}

/** Host der App: <prefix><ein Label ohne Punkt><suffix> */
function isAppHost(hostname) {
  if (!hostname.startsWith(appHostPrefix) || !hostname.endsWith(appHostSuffix)) return false;
  const middle = hostname.slice(appHostPrefix.length, hostname.length - appHostSuffix.length);
  return /^[a-z0-9-]+$/.test(middle);
}

/** Grund, warum der Host nicht passt, oder null. */
function hostRejection(req) {
  if (allowAnyHost) return null;
  let hostLines = 0;
  for (let i = 0; i < req.rawHeaders.length; i += 2) {
    if (req.rawHeaders[i].toLowerCase() === 'host') hostLines += 1;
  }
  if (hostLines !== 1) return `${hostLines} Host-Zeilen`;
  const hostname = hostnameOf(req.headers.host);
  if (LOCAL_HOSTNAMES.has(hostname) || isAppHost(hostname)) return null;
  return `Host gehört nicht zur App (${hostname || 'leer'})`;
}

/** Grund für eine Ablehnung oder null. */
function rejection(req) {
  const site = req.headers['sec-fetch-site'];
  const mode = req.headers['sec-fetch-mode'];
  const dest = req.headers['sec-fetch-dest'];
  const origin = req.headers.origin;
  const fromBrowser = site !== undefined || origin !== undefined;
  // Nur /pfad: sonst griffe der Vergleich mit BROWSER_FORBIDDEN_PATHS nicht
  // (z. B. GET http://h/api/auth/register HTTP/1.1)
  if (!(req.url || '').startsWith('/')) return 'Anfrage-Ziel nicht in der Form /pfad';
  const pathname = req.url.split('?')[0].replace(/\/+$/, '') || '/';

  const badHost = hostRejection(req);
  if (badHost) return badHost;

  if (fromBrowser && BROWSER_FORBIDDEN_PATHS.has(pathname)) {
    return 'Registrierung und Login sind im Platform-Modus nur lokal möglich';
  }

  if (site === 'same-site' || site === 'cross-site') {
    // Öffnen als Seite: Navigation (Link, Knopf im Coder-Dashboard), kein
    // iframe. Der Service Worker von CloudCLI (public/sw.js) holt Navigationen
    // mit fetch(event.request) neu. Chromium schickt dann Modus navigate mit
    // Dest empty (auf einem Platz beobachtet), laut Fetch-Standard wäre es
    // Modus same-origin mit Dest document. Beides ist erlaubt. Sicher: Den
    // Modus navigate kann fetch() einer fremden Seite nicht setzen, dest=document
    // gibt es nur bei Navigationen, und ein same-origin-Request an eine fremde
    // Origin verlässt den Browser nicht.
    const asPage = (mode === 'navigate' && (dest === undefined || dest === 'document' || dest === 'empty'))
      || (mode === 'same-origin' && dest === 'document');
    const openAsPage = asPage && (req.method === 'GET' || req.method === 'HEAD');
    return openAsPage ? null : `Anfrage von einer anderen Seite (Sec-Fetch-Site: ${site})`;
  }

  // Ältere Browser ohne Fetch Metadata: Origin gegen Host prüfen
  if (site === undefined && origin !== undefined) {
    let originHost;
    try {
      originHost = new URL(origin).host;
    } catch {
      return 'ungültiger Origin';
    }
    const hosts = [req.headers.host, ...String(req.headers['x-forwarded-host'] ?? '').split(',')]
      .map((h) => (h ?? '').trim())
      .filter(Boolean);
    if (!hosts.includes(originHost)) return 'Origin passt nicht zum Host';
  }
  return null;
}

function logRejection(req, why) {
  const h = (name) => req.headers[name] ?? '-';
  console.warn(`cloudcli-guard: abgelehnt ${req.method} ${(req.url || '').split('?')[0]}: ${why}`
    + ` (mode ${h('sec-fetch-mode')}, dest ${h('sec-fetch-dest')})`);
}

// --- CloudCLI als Kindprozess ---------------------------------------------------

const child = spawn(process.execPath, ['dist-server/server/index.js'], {
  cwd: path.join(bundle, 'app'),
  env: {
    ...process.env,
    VITE_IS_PLATFORM: 'true',
    NODE_ENV: 'production',
    HOST: innerHost,
    SERVER_PORT: String(innerPort),
  },
  stdio: 'inherit',
});

let stopping = false;
child.on('exit', (code, signal) => {
  if (!stopping) console.error(`cloudcli-guard: CloudCLI beendet (Code ${code}, Signal ${signal})`);
  process.exit(code ?? 1);
});
for (const sig of ['SIGTERM', 'SIGINT', 'SIGHUP']) {
  process.on(sig, () => {
    stopping = true;
    child.kill(sig);
  });
}

// --- Weiterleitung --------------------------------------------------------------

function withoutHopByHop(headers) {
  const out = { ...headers };
  for (const h of HOP_BY_HOP) delete out[h];
  return out;
}

const server = http.createServer((req, res) => {
  const why = rejection(req);
  if (why) {
    logRejection(req, why);
    res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end(`Abgelehnt: ${why}\n`);
    return;
  }

  const upstream = http.request(
    { host: innerHost, port: innerPort, method: req.method, path: req.url, headers: withoutHopByHop(req.headers) },
    (upRes) => {
      res.writeHead(upRes.statusCode ?? 502, upRes.statusMessage, withoutHopByHop(upRes.headers));
      upRes.pipe(res);
    },
  );
  upstream.on('error', () => {
    // CloudCLI startet noch oder ist weg
    if (!res.headersSent) {
      res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('CloudCLI nicht erreichbar\n');
    } else {
      res.destroy();
    }
  });
  // Abbruch durch den Browser (z. B. gestreamte Antworten): weiterreichen
  res.on('close', () => {
    if (!res.writableFinished) upstream.destroy();
  });
  req.pipe(upstream);
});

server.on('upgrade', (req, socket, head) => {
  const why = rejection(req);
  if (why) {
    logRejection(req, why);
    socket.end(`HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\nAbgelehnt: ${why}\n`);
    return;
  }
  const upstream = net.connect(innerPort, innerHost, () => {
    let lines = `${req.method} ${req.url} HTTP/${req.httpVersion}\r\n`;
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      lines += `${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}\r\n`;
    }
    upstream.write(`${lines}\r\n`);
    if (head && head.length) upstream.write(head);
    upstream.pipe(socket);
    socket.pipe(upstream);
  });
  const closeBoth = () => {
    upstream.destroy();
    socket.destroy();
  };
  upstream.on('error', closeBoth);
  socket.on('error', closeBoth);
  upstream.on('close', () => socket.destroy());
  socket.on('close', () => upstream.destroy());
});

// Gestreamte Antworten (Claude) können lange dauern
server.requestTimeout = 0;
server.timeout = 0;

server.on('error', (err) => {
  console.error(`cloudcli-guard: ${listenHost}:${listenPort} nicht verfügbar: ${err.message}`);
  stopping = true;
  child.kill('SIGTERM');
  process.exitCode = 1;
});

server.listen(listenPort, listenHost, () => {
  console.log(`cloudcli-guard: lauscht auf ${listenHost}:${listenPort}, CloudCLI intern auf ${innerHost}:${innerPort}, `
    + (allowAnyHost ? 'ohne Host-Prüfung' : `Host ${appHostPrefix}…${appHostSuffix} oder lokal`));
});
