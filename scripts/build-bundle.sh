#!/usr/bin/env bash
# =============================================================================
# Baut das Bündel im Container (aufgerufen von build.sh). Erwartet das Repo
# unter /repo (nur lesend) und schreibt nach /out.
#
# Schritte:
#   1. Node (node.version) von nodejs.org, Prüfsumme fest aus node.sha256
#   2. siteboon/claudecodeui am Tag aus cloudcli.version klonen, Commit muss
#      cloudcli.commit entsprechen (ein verschobener Tag bricht den Bau ab)
#   3. npm ci und Bau mit VITE_IS_PLATFORM=true: Frontend ohne eigenes Login,
#      die Anmeldung übernimmt Coder (App mit share = "owner")
#   4. Entwicklungsabhängigkeiten, Codex- und SDK-Binary entfernen
#   5. Bündel packen: Node, App (Umfang wie npm pack), Startskripte, Wächter,
#      LICENSE, NOTICE, SOURCE.txt
#   6. Rauchtest (scripts/smoke.sh) gegen das fertige Archiv
#
# Der Quellcode von upstream wird nicht verändert.
# =============================================================================
set -euo pipefail

repo=/repo
out=/out
fail() {
  echo "FEHLER: $*" >&2
  exit 1
}

read_version() { tr -d '[:space:]' <"$repo/$1"; }
upstream=$(read_version cloudcli.version)
upstream_commit=$(read_version cloudcli.commit)
node_version=$(read_version node.version)
node_sha256=$(read_version node.sha256)
release=$(read_version release.version)
build_commit=${BUILD_SCRIPTS_COMMIT:-unbekannt}
[[ $upstream =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "cloudcli.version: kein Tag wie v1.2.3: $upstream"
[[ $upstream_commit =~ ^[0-9a-f]{40}$ ]] || fail "cloudcli.commit: kein vollständiger Commit-Hash: $upstream_commit"
[[ $node_version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "node.version: keine Version wie v22.1.2: $node_version"
[[ $node_sha256 =~ ^[0-9a-f]{64}$ ]] || fail "node.sha256: keine SHA-256: $node_sha256"
[[ $release =~ ^[0-9]+$ ]] || fail "release.version: keine Zahl: $release"
[[ $build_commit =~ ^([0-9a-f]{40}(-dirty)?|unbekannt)$ ]] || fail "BUILD_SCRIPTS_COMMIT ungültig: $build_commit"
[ "$(uname -m)" = x86_64 ] || fail "Bau nur für x86_64, hier: $(uname -m)"

name="cloudcli-${upstream}-atra.${release}-linux-x64"
echo "== Baue $name (Node $node_version, Bau-Skripte $build_commit)"

echo "== Pakete für den Bau"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# iproute2: ss für den Rauchtest (Adressen, auf denen gelauscht wird)
apt-get install -y -qq --no-install-recommends \
  build-essential python3 git curl ca-certificates xz-utils iproute2 >/dev/null

work=/tmp/build
rm -rf "$work"
mkdir -p "$work/cloudcli/bin" "$work/cloudcli/node" "$work/cloudcli/app"
curl_opts=(-fsSL --retry 3 --connect-timeout 20 --max-time 900)

echo "== Node $node_version"
node_tar="node-${node_version}-linux-x64.tar.xz"
curl "${curl_opts[@]}" -o "$work/$node_tar" "https://nodejs.org/dist/${node_version}/${node_tar}"
# Feste Prüfsumme aus dem Repo, nicht vom selben Server wie das Archiv
echo "${node_sha256}  $work/$node_tar" | sha256sum -c --quiet - || fail "Prüfsumme von $node_tar passt nicht zu node.sha256"
tar -xJf "$work/$node_tar" --strip-components=1 -C "$work/cloudcli/node"
# Header und Handbuchseiten braucht zur Laufzeit niemand
rm -rf "$work/cloudcli/node/include" "$work/cloudcli/node/share"
export PATH="$work/cloudcli/node/bin:$PATH"
node --version

echo "== Quelle siteboon/claudecodeui $upstream"
git clone -q --depth 1 --branch "$upstream" https://github.com/siteboon/claudecodeui.git "$work/src"
commit=$(git -C "$work/src" rev-parse HEAD)
[ "$commit" = "$upstream_commit" ] || fail "Tag $upstream zeigt auf $commit, erwartet $upstream_commit (cloudcli.commit). Tag verschoben?"
echo "Commit $commit"
cd "$work/src"

echo "== npm ci"
# Electron braucht nur die Desktop-App, husky nur Entwickler
export ELECTRON_SKIP_BINARY_DOWNLOAD=1 HUSKY=0 CI=true
npm ci --no-audit --no-fund --loglevel=error

echo "== Bau mit VITE_IS_PLATFORM=true"
VITE_IS_PLATFORM=true npm run build
# Vite setzt den Schalter fest ein: Im Platform-Modus bleibt der Zweig mit dem
# festen Benutzer "platform-user" stehen, sonst entfernt ihn der Minifier.
grep -rqs 'username:"platform-user"' dist/assets || fail "Frontend ist nicht im Platform-Modus gebaut"

echo "== Laufzeit-Abhängigkeiten"
# --ignore-scripts: sonst startet npm "prepare" (husky), das gerade entfernt wurde
du -sh node_modules
npm prune --omit=dev --ignore-scripts --no-audit --no-fund --loglevel=error
du -sh node_modules

echo "== Nicht benötigte Binaries entfernen"
# - Codex (@openai/codex-linux-x64, rund 435 MB): Den Anbieter Codex bieten
#   die Plätze nicht an. CloudCLI zeigt ihn dann als nicht installiert.
# - Claude-Binary des Agent SDK (@anthropic-ai/claude-agent-sdk-linux-x64,
#   rund 280 MB): CloudCLI übergibt dem SDK unter Linux immer den Befehl aus
#   CLAUDE_CLI_PATH (Standard "claude" aus PATH), also das Claude Code des
#   Platzes. Das mitgelieferte Binary bleibt ungenutzt.
find node_modules -type d \( -name codex-linux-x64 -o -name claude-agent-sdk-linux-x64 \) -prune -print -exec rm -rf {} +
rm -f node_modules/.bin/codex
du -sh node_modules
du -s node_modules/* node_modules/@*/* 2>/dev/null | sort -rn | head -n 10 | awk '{printf "  %6d MB  %s\n", $1/1024, $2}'

echo "== App zusammenstellen (Umfang wie npm pack)"
# Die Liste "files" aus package.json, dazu package.json selbst. Kein npm pack:
# Das würde das Skript "prepare" (husky) starten.
mapfile -t entries < <(node -e 'for (const f of require("./package.json").files || []) console.log(f)')
[ "${#entries[@]}" -gt 0 ] || fail "package.json ohne files"
for entry in package.json "${entries[@]}"; do
  case "$entry" in *[*?{}[]* | /* | *..*) fail "Eintrag in files nicht unterstützt: $entry (Skript anpassen)" ;; esac
  entry=${entry%/}
  if [ ! -e "$entry" ]; then
    echo "  fehlt, übersprungen: $entry"
    continue
  fi
  mkdir -p "$work/cloudcli/app/$(dirname "$entry")"
  cp -a "$entry" "$work/cloudcli/app/$entry"
done
[ -f "$work/cloudcli/app/dist-server/server/index.js" ] || fail "dist-server/server/index.js fehlt im Bündel"
[ -f "$work/cloudcli/app/dist/index.html" ] || fail "dist/index.html fehlt im Bündel"
mv node_modules "$work/cloudcli/app/node_modules"

echo "== Bündel zusammenstellen"
install -m 755 "$repo"/bundle/bin/cloudcli-start "$repo"/bundle/bin/cloudcli-ensure-user "$work/cloudcli/bin/"
install -m 644 "$repo"/bundle/bin/cloudcli-guard.mjs "$work/cloudcli/bin/"
cp LICENSE NOTICE "$work/cloudcli/"
cat >"$work/cloudcli/SOURCE.txt" <<EOF
CloudCLI UI (siteboon/claudecodeui) als Bündel für Coder-Arbeitsplätze

Bündel:        ${name}
Gebaut:        $(date -u +%Y-%m-%dT%H:%M:%SZ)
Node:          ${node_version} (linux-x64, liegt unter node/)

Quellcode:     https://github.com/siteboon/claudecodeui/tree/${commit}
               (Tag ${upstream}), unverändert gebaut
Lizenz:        AGPL-3.0-or-later, siehe LICENSE und NOTICE

Abweichend vom Quellstand enthält das Bündel:
  - Frontend gebaut mit VITE_IS_PLATFORM=true (kein eigenes Login)
  - node_modules nur mit Laufzeit-Abhängigkeiten, ohne
    @openai/codex-linux-x64 und @anthropic-ai/claude-agent-sdk-linux-x64
  - bin/: Startskripte und Wächter aus den Bau-Skripten

Bau-Skripte:   https://github.com/atra-consulting/cloudcli-build/tree/${build_commit%-dirty}
               (Stand ${build_commit}, AGPL-3.0-or-later)
EOF

tar -C "$work" --owner=0 --group=0 --numeric-owner -czf "$out/$name.tar.gz" cloudcli
(cd "$out" && sha256sum "$name.tar.gz" >"$name.tar.gz.sha256")

echo "== Rauchtest"
bash "$repo/scripts/smoke.sh" "$out/$name.tar.gz"

if [ -n "${HOST_UID:-}" ]; then
  chown "$HOST_UID:${HOST_GID:-$HOST_UID}" "$out/$name.tar.gz" "$out/$name.tar.gz.sha256"
fi
echo "== Fertig"
du -sh "$work/cloudcli" "$out/$name.tar.gz"
cat "$out/$name.tar.gz.sha256"
