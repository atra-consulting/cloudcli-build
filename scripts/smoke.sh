#!/usr/bin/env bash
# =============================================================================
# Smoketest für ein fertiges Bundle (Linux x64): entpacken, starten und
# nachweisen, dass Platform-Modus, Wächter, Einrichtung, Claude-Aufruf,
# Datenbank und Terminal funktionieren.
# Aufruf: scripts/smoke.sh out/cloudcli-...-linux-x64.tar.gz
# Braucht: curl, git, ss (iproute2)
# =============================================================================
set -euo pipefail
tarball=${1:?Pfad zum Bundle}

work=$(mktemp -d)
pid=""
cleanup() {
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT
fail() {
  echo "SMOKETEST FEHLGESCHLAGEN: $*" >&2
  echo "--- Server-Log" >&2
  tail -n 40 "$work/server.log" >&2 || true
  exit 1
}
ok() { echo "  ok: $*"; }

tar -xzf "$tarball" -C "$work"
bundle="$work/cloudcli"
[ -x "$bundle/bin/cloudcli-start" ] || fail "bin/cloudcli-start fehlt"

# Leeres HOME: keine Spuren eines früheren Laufs
export HOME="$work/home"
mkdir -p "$HOME/projekt"

# Platzhalter für Claude Code: schreibt eine Marke, wenn CloudCLI ihn aufruft
mkdir -p "$work/stub"
cat >"$work/stub/claude" <<EOF
#!/bin/sh
echo "\$*" >>"$work/claude-called"
exit 1
EOF
chmod 755 "$work/stub/claude"
export PATH="$work/stub:$PATH"

export SERVER_PORT=3901 CLOUDCLI_INTERNAL_PORT=13901
# Ein geerbtes HOST=0.0.0.0 darf nichts öffnen (cloudcli-guard ignoriert HOST)
export HOST=0.0.0.0
unset CLOUDCLI_HOST
url="http://127.0.0.1:$SERVER_PORT"

"$bundle/bin/cloudcli-start" >"$work/server.log" 2>&1 &
pid=$!

echo "-- Einrichtung"
"$bundle/bin/cloudcli-ensure-user" smoke-user "Smoke Test" smoke@example.com || fail "Einrichtung fehlgeschlagen"
second=$("$bundle/bin/cloudcli-ensure-user" smoke-user "Anderer Name" other@example.com) || fail "zweiter Aufruf fehlgeschlagen"
echo "$second" | grep -q "existiert schon" || fail "zweiter Aufruf legt Benutzer erneut an"
echo "$second" | grep -q "schon erledigt" || fail "zweiter Aufruf überschreibt die Git-Identität"
ok "Benutzer angelegt, zweiter Aufruf ändert nichts"

curl -fsS "$url/api/user/onboarding-status" | grep -q '"hasCompletedOnboarding":true' || fail "Einrichtungsassistent nicht erledigt"
curl -fsS "$url/api/user/git-config" | grep -q 'smoke@example.com' || fail "Git-Identität fehlt in CloudCLI"
[ "$(git config --global user.email)" = smoke@example.com ] || fail "git config --global user.email nicht gesetzt"
ok "Git-Identität in CloudCLI und git, Einrichtungsassistent erledigt"

echo "-- Server"
code=$(curl -s -o /dev/null -w '%{http_code}' "$url/health")
[ "$code" = 200 ] || fail "/health: HTTP $code"
body=$(curl -fsS "$url/api/auth/user") || fail "/api/auth/user ohne Token abgelehnt (kein Platform-Modus?)"
echo "$body" | grep -q '"smoke-user"' || fail "/api/auth/user liefert nicht smoke-user: $body"
curl -fsS "$url/" | grep -q '<div id="root"' || fail "Startseite ohne Frontend"
ok "Platform-Modus: API ohne Token, Frontend wird ausgeliefert"

echo "-- Adressen"
listening=$(ss -Hltn "( sport = :$SERVER_PORT or sport = :$CLOUDCLI_INTERNAL_PORT )" | awk '{print $4}')
[ -n "$listening" ] || fail "nichts lauscht auf $SERVER_PORT/$CLOUDCLI_INTERNAL_PORT"
echo "$listening" | grep -qv '^127\.0\.0\.1:' && fail "lauscht nicht nur auf 127.0.0.1: $(echo "$listening" | tr '\n' ' ')"
ok "nur 127.0.0.1 ($(echo "$listening" | tr '\n' ' '))"

echo "-- Wächter"
status_of() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" || true; }
[ "$(status_of -H 'Sec-Fetch-Site: same-origin' -H 'Sec-Fetch-Mode: cors' "$url/api/auth/user")" = 200 ] || fail "eigene Seite abgelehnt"
[ "$(status_of -H 'Sec-Fetch-Site: same-site' -H 'Sec-Fetch-Mode: cors' "$url/api/auth/user")" = 403 ] || fail "Anfrage einer anderen Seite derselben Site nicht abgelehnt"
[ "$(status_of -X POST -H 'Sec-Fetch-Site: cross-site' -H 'Content-Type: application/x-www-form-urlencoded' --data 'message=x' "$url/api/agent")" = 403 ] || fail "fremdes Formular an /api/agent nicht abgelehnt"
[ "$(status_of -X POST -H 'Origin: https://fremd.example' --data 'message=x' "$url/api/agent")" = 403 ] || fail "fremder Origin ohne Fetch Metadata nicht abgelehnt"
[ "$(status_of -H 'Sec-Fetch-Site: cross-site' -H 'Sec-Fetch-Mode: navigate' -H 'Sec-Fetch-Dest: document' "$url/")" = 200 ] || fail "Öffnen der App über einen Link abgelehnt"
[ "$(status_of -H 'Sec-Fetch-Site: cross-site' -H 'Sec-Fetch-Mode: navigate' -H 'Sec-Fetch-Dest: iframe' "$url/")" = 403 ] || fail "Einbetten in fremdes iframe nicht abgelehnt"
# Service Worker von CloudCLI holt Navigationen neu: Chromium navigate/empty, Standard same-origin/document
[ "$(status_of -H 'Sec-Fetch-Site: same-site' -H 'Sec-Fetch-Mode: navigate' -H 'Sec-Fetch-Dest: empty' "$url/")" = 200 ] || fail "Navigation über den Service Worker (Chromium) abgelehnt"
[ "$(status_of -X POST -H 'Sec-Fetch-Site: same-site' -H 'Sec-Fetch-Mode: navigate' -H 'Sec-Fetch-Dest: empty' -H 'Content-Type: application/json' --data '{}' "$url/api/agent")" = 403 ] || fail "POST mit Modus navigate nicht abgelehnt"
[ "$(status_of -H 'Sec-Fetch-Site: same-site' -H 'Sec-Fetch-Mode: same-origin' -H 'Sec-Fetch-Dest: document' "$url/")" = 200 ] || fail "Navigation über den Service Worker abgelehnt"
[ "$(status_of -H 'Sec-Fetch-Site: same-site' -H 'Sec-Fetch-Mode: same-origin' -H 'Sec-Fetch-Dest: empty' "$url/api/auth/user")" = 403 ] || fail "same-origin-Modus ohne Dest document nicht abgelehnt"
[ "$(status_of -X POST -H 'Sec-Fetch-Site: same-site' -H 'Sec-Fetch-Mode: same-origin' -H 'Sec-Fetch-Dest: document' -H 'Content-Type: application/json' --data '{}' "$url/api/agent")" = 403 ] || fail "POST mit Dest document nicht abgelehnt"
[ "$(status_of -X POST -H 'Sec-Fetch-Site: same-origin' -H 'Content-Type: application/json' --data '{}' "$url/api/auth/register")" = 403 ] || fail "Registrierung aus dem Browser nicht abgelehnt"
ws=(-H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==')
[ "$(status_of --max-time 3 "${ws[@]}" -H 'Origin: https://fremd.example' -H 'Sec-Fetch-Site: cross-site' -H 'Sec-Fetch-Mode: websocket' "$url/shell")" = 403 ] || fail "fremder WebSocket an /shell nicht abgelehnt"
[ "$(status_of --max-time 3 "${ws[@]}" -H 'Sec-Fetch-Site: same-origin' -H 'Sec-Fetch-Mode: websocket' "$url/shell")" = 101 ] || fail "eigener WebSocket an /shell nicht durchgereicht"
ok "fremde Seiten, iframe, Browser-Registrierung und fremder WebSocket abgelehnt; eigene Anfragen durch"

echo "-- Claude Code aus PATH"
curl -s -o /dev/null --max-time 90 -X POST -H 'Content-Type: application/json' \
  --data-binary "{\"projectPath\":\"$HOME/projekt\",\"message\":\"Smoketest\",\"provider\":\"claude\",\"stream\":false}" \
  "$url/api/agent" || true
[ -s "$work/claude-called" ] || fail "CloudCLI hat claude aus PATH nicht aufgerufen"
ok "claude aus PATH aufgerufen"

echo "-- Bundle"
(cd "$bundle/app" && "$bundle/node/bin/node" -e '
  require("better-sqlite3");
  const pty = require("node-pty");
  const p = pty.spawn("/bin/sh", ["-c", "echo pty-ok; sleep 1"], {});
  const timer = setTimeout(() => { console.error("node-pty ohne Ausgabe"); process.exit(1); }, 10000);
  let out = "";
  p.onData((d) => {
    out += d;
    if (out.includes("pty-ok")) { clearTimeout(timer); p.kill(); process.exit(0); }
  });
') || fail "native Module (better-sqlite3, node-pty) laden nicht"
ok "better-sqlite3 und node-pty"

if find "$bundle/app/node_modules" -type d \( -name codex-linux-x64 -o -name claude-agent-sdk-linux-x64 \) | grep -q .; then
  fail "Codex- oder SDK-Binary noch im Bundle"
fi
ok "ohne Codex- und SDK-Binary"

echo "Smoketest bestanden."
