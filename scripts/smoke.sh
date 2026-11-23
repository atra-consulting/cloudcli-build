#!/usr/bin/env bash
# =============================================================================
# Smoketest für ein fertiges Bundle (Linux x64): entpacken, starten und
# nachweisen, dass Platform-Modus, Wächter, Einrichtung, eigene Modelle, Claude-Aufruf,
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
# Wie auf dem Arbeitsplatz: nur Host der App oder lokal
export CLOUDCLI_APP_HOST_PREFIX=cloudcli-- CLOUDCLI_APP_HOST_SUFFIX=.coder.example
unset CLOUDCLI_ALLOW_ANY_HOST
# Ein geerbtes HOST=0.0.0.0 darf nichts öffnen (cloudcli-guard ignoriert HOST)
export HOST=0.0.0.0
unset CLOUDCLI_HOST
url="http://127.0.0.1:$SERVER_PORT"

echo "-- Start nur mit Host-Prüfung"
# Ohne PREFIX/SUFFIX, mit ungültigem Wert oder widersprüchlich: Start bricht ab
refuses() {
  local rc=0
  timeout 20 env "$@" "$bundle/bin/cloudcli-start" >"$work/refused.log" 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "Start mit $* nicht abgelehnt (Code $rc): $(head -n 3 "$work/refused.log")"
}
refuses -u CLOUDCLI_APP_HOST_PREFIX -u CLOUDCLI_APP_HOST_SUFFIX
refuses -u CLOUDCLI_APP_HOST_SUFFIX
refuses CLOUDCLI_APP_HOST_PREFIX=cloudcli
refuses CLOUDCLI_APP_HOST_SUFFIX=example
refuses CLOUDCLI_ALLOW_ANY_HOST=1
refuses CLOUDCLI_HOST=0.0.0.0
ok "Start ohne gültige Host-Prüfung abgelehnt"

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
# Wächter nur auf 127.0.0.1. CloudCLI nur auf 127.0.0.3: Die Port-Weiterleitung
# von Coder verbindet sich mit 127.0.0.1:<port> und darf CloudCLI nicht erreichen.
guard_listen=$(ss -Hltn "( sport = :$SERVER_PORT )" | awk '{print $4}')
inner_listen=$(ss -Hltn "( sport = :$CLOUDCLI_INTERNAL_PORT )" | awk '{print $4}')
[ "$guard_listen" = "127.0.0.1:$SERVER_PORT" ] || fail "Wächter lauscht nicht nur auf 127.0.0.1: $(echo "$guard_listen" | tr '\n' ' ')"
[ "$inner_listen" = "127.0.0.3:$CLOUDCLI_INTERNAL_PORT" ] || fail "CloudCLI lauscht nicht nur auf 127.0.0.3: $(echo "$inner_listen" | tr '\n' ' ')"
curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$CLOUDCLI_INTERNAL_PORT/health" && fail "CloudCLI über 127.0.0.1:$CLOUDCLI_INTERNAL_PORT erreichbar"
ok "Wächter $guard_listen, CloudCLI $inner_listen, 127.0.0.1:$CLOUDCLI_INTERNAL_PORT geschlossen"

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

# Host: nur App (cloudcli--…) oder lokal. Port-Freigabe 3001--… darf nicht durch.
app_host='cloudcli--main--platz--teilnehmer.coder.example'
[ "$(status_of -H "Host: $app_host" "$url/api/auth/user")" = 200 ] || fail "Host der App abgelehnt"
[ "$(status_of -H 'Host: CloudCLI--main--platz--teilnehmer.coder.example:443' "$url/api/auth/user")" = 200 ] || fail "Host der App mit Großbuchstaben und Port abgelehnt"
[ "$(status_of -H "Host: localhost:$SERVER_PORT" "$url/api/auth/user")" = 200 ] || fail "Host localhost abgelehnt"
[ "$(status_of -H "Host: [::1]:$SERVER_PORT" "$url/api/auth/user")" = 200 ] || fail "Host [::1] abgelehnt"
[ "$(status_of -H "Host: $SERVER_PORT--main--platz--teilnehmer.coder.example" "$url/api/auth/user")" = 403 ] || fail "Port-Freigabe ($SERVER_PORT--…) nicht abgelehnt"
[ "$(status_of -H 'Host: x-cloudcli--main--platz--teilnehmer.coder.example' "$url/api/auth/user")" = 403 ] || fail "fremder Host mit cloudcli-- in der Mitte nicht abgelehnt"
[ "$(status_of -H 'Host: 127.0.0.1.coder.example' "$url/api/auth/user")" = 403 ] || fail "Host mit 127.0.0.1 als Anfang nicht abgelehnt"
[ "$(status_of -H 'Host: cloudcli--x.evil.example' "$url/api/auth/user")" = 403 ] || fail "fremde Domain mit cloudcli-- (DNS-Rebinding) nicht abgelehnt"
[ "$(status_of -H 'Host: cloudcli--a.b.coder.example' "$url/api/auth/user")" = 403 ] || fail "Host mit mehreren Labels vor der Endung nicht abgelehnt"
[ "$(status_of -H "Host: $app_host." "$url/api/auth/user")" = 403 ] || fail "Host mit Punkt am Ende nicht abgelehnt"
# curl schickt nur eine Host-Zeile: rohe Anfrage über /dev/tcp
raw_status() {
  local line=""
  exec 3<>"/dev/tcp/127.0.0.1/$SERVER_PORT"
  printf '%s\r\n' "$@" "Connection: close" "" >&3
  IFS= read -r -t 10 line <&3 || true
  exec 3<&- 3>&-
  echo "$line" | awk '{print $2}'
}
code=$(raw_status 'GET /api/auth/user HTTP/1.1' "Host: $app_host" 'Host: 127.0.0.1')
[ "$code" = 400 ] || [ "$code" = 403 ] || fail "doppelte Host-Zeile nicht abgelehnt: HTTP $code"
[ "$(raw_status 'GET /api/auth/user HTTP/1.1' "Host: $app_host")" = 200 ] || fail "rohe Anfrage mit Host der App abgelehnt"
# Ohne Host antwortet Node selbst mit 400, der Wächter sieht die Anfrage nicht
code=$(status_of -H 'Host:' "$url/api/auth/user")
[ "$code" = 400 ] || [ "$code" = 403 ] || fail "fehlender Host nicht abgelehnt: HTTP $code"
[ "$(status_of -X POST --request-target "http://127.0.0.1:$SERVER_PORT/api/auth/register" -H 'Sec-Fetch-Site: same-origin' -H 'Content-Type: application/json' --data '{}' "$url/")" = 403 ] || fail "Anfrage-Ziel in absoluter Form nicht abgelehnt"
[ "$(status_of --max-time 3 "${ws[@]}" -H "Host: $SERVER_PORT--main--platz--teilnehmer.coder.example" -H 'Sec-Fetch-Site: same-origin' -H 'Sec-Fetch-Mode: websocket' "$url/shell")" = 403 ] || fail "WebSocket über Port-Freigabe nicht abgelehnt"
[ "$(status_of --max-time 3 "${ws[@]}" -H "Host: $app_host" -H 'Sec-Fetch-Site: same-origin' -H 'Sec-Fetch-Mode: websocket' "$url/shell")" = 101 ] || fail "WebSocket über Host der App nicht durchgereicht"
ok "Host: App und lokal durch, Port-Freigabe und fremde Hosts abgelehnt"

echo "-- Eigene Modelle"
# Der Arbeitsplatz trägt Modelle eines Gateways über diese API ein
# (anlegen, nur eigene Modelle zeigen, löschen). Ändert upstream die API,
# fällt das hier auf und nicht erst auf den Plätzen.
models="$url/api/providers/claude/models"
# js AUSDRUCK: JSON von stdin als d, Ergebnis des Ausdrucks ausgeben
js() { "$bundle/node/bin/node" -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{const d=JSON.parse(s);console.log(eval(process.argv[1]))})' "$1"; }
curl -fsS -X POST -H 'Content-Type: application/json' --data '{"model":"Smoke Modell","id":"smoke/modell-1"}' "$models" >/dev/null \
  || fail "eigenes Modell nicht angelegt"
list=$(curl -fsS "$models") || fail "Liste der Modelle nicht abrufbar"
record=$(echo "$list" | js 'd.data.models.OPTIONS.filter(o=>o.value==="smoke/modell-1"&&o.isCustom===true).map(o=>o.recordId).join(",")') \
  || fail "Liste der Modelle hat ein anderes Format: $list"
[ -n "$record" ] && [ "${record#*,}" = "$record" ] || fail "eigenes Modell nicht genau einmal in der Liste: $list"
list=$(curl -fsS -X PUT -H 'Content-Type: application/json' --data '{"enabled":true}' "$models/custom-only") || fail "nur eigene Modelle nicht einschaltbar"
[ "$(echo "$list" | js 'd.data.models.CUSTOM_MODELS_ONLY+" "+d.data.models.DEFAULT+" "+d.data.models.OPTIONS.map(o=>o.value).join(",")')" = "true smoke/modell-1 smoke/modell-1" ] \
  || fail "mit nur eigenen Modellen nicht nur das eigene als Standard: $list"
curl -fsS -X PUT -H 'Content-Type: application/json' --data '{"enabled":false}' "$models/custom-only" >/dev/null || fail "nur eigene Modelle nicht ausschaltbar"
curl -fsS -X DELETE "$models/$record" >/dev/null || fail "eigenes Modell nicht löschbar"
curl -fsS "$models" | js 'd.data.models.OPTIONS.some(o=>o.isCustom)' | grep -qx false || fail "eigenes Modell nach dem Löschen noch da"
ok "eigenes Modell angelegt, als einziges gezeigt, gelöscht"

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
