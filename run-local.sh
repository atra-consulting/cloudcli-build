#!/usr/bin/env bash
# =============================================================================
# Probiert ein Bundle lokal aus: Container ubuntu:24.04 (linux/amd64) wie auf
# dem Arbeitsplatz, mit Claude Code und dem Benutzer dev.
#
#   ./run-local.sh [out/cloudcli-...-linux-x64.tar.gz]   (Standard: neuestes)
#   Öffnen:     http://localhost:3001
#   Log:        docker logs -f cloudcli-local
#   Stoppen:    docker rm -f cloudcli-local
#   Neu von 0:  docker volume rm cloudcli-local-home
#
# Achtung: Im Platform-Modus hat CloudCLI kein Login. Der Port ist deshalb nur
# auf 127.0.0.1 des Macs veröffentlicht. Claude Code meldet sich im Terminal
# der UI an (claude, dann /login); die Anmeldung bleibt im Volume.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

tarball=${1:-$(ls -t out/cloudcli-*-linux-x64.tar.gz 2>/dev/null | head -n 1 || true)}
[ -n "$tarball" ] && [ -f "$tarball" ] || {
  echo "Kein Bundle gefunden. Erst ./build.sh ausführen." >&2
  exit 1
}
tarball=$(cd "$(dirname "$tarball")" && pwd)/$(basename "$tarball")

image=cloudcli-local
name=cloudcli-local

# Image ohne Build-Kontext (Dockerfile über stdin): nur Grundwerkzeuge und dev
docker build -q --platform linux/amd64 -t "$image" - >/dev/null <<'EOF'
FROM ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl git less nano ripgrep \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash dev \
 && mkdir -p /home/dev/workspace && chown dev:dev /home/dev/workspace
USER dev
WORKDIR /home/dev
EOF

docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" --platform linux/amd64 \
  -p 127.0.0.1:3001:3001 \
  -v cloudcli-local-home:/home/dev \
  -v "$tarball":/bundle.tar.gz:ro \
  ${GIT_NAME:+-e GIT_NAME="$GIT_NAME"} ${GIT_EMAIL:+-e GIT_EMAIL="$GIT_EMAIL"} \
  "$image" bash -c '
    set -e
    rm -rf /tmp/cloudcli && tar -xzf /bundle.tar.gz -C /tmp
    mkdir -p "$HOME/workspace" "$HOME/.local/bin"
    export PATH="$HOME/.local/bin:$PATH"
    if ! command -v claude >/dev/null; then
      # Nur für den lokalen Test: offizieller Installer, aktuelle Version
      echo "Installiere Claude Code"
      curl -fsSL https://claude.ai/install.sh | bash
    fi
    # 0.0.0.0 nur im Container, nach außen nur 127.0.0.1 des Macs (docker -p)
    CLOUDCLI_HOST=0.0.0.0 /tmp/cloudcli/bin/cloudcli-start &
    # Auf dem Platz kommen Name und E-Mail aus dem Coder-Konto, hier Platzhalter
    /tmp/cloudcli/bin/cloudcli-ensure-user dev "${GIT_NAME:-Dummy Teilnehmer}" "${GIT_EMAIL:-dummy.teilnehmer@example.com}"
    cat /tmp/cloudcli/SOURCE.txt
    wait
  ' >/dev/null

echo "Gestartet: $(basename "$tarball")"
echo "Warte auf CloudCLI ..."
for _ in $(seq 1 180); do
  # SOURCE.txt erscheint im Log erst nach cloudcli-ensure-user
  if docker logs "$name" 2>/dev/null | grep -q '^Bundle:' &&
    curl -fsS -o /dev/null http://127.0.0.1:3001/health 2>/dev/null; then
    echo "Bereit: http://localhost:3001"
    exit 0
  fi
  if ! docker ps -q --filter "name=^${name}\$" | grep -q .; then
    echo "Container beendet:" >&2
    docker logs --tail 40 "$name" >&2
    exit 1
  fi
  sleep 2
done
echo "Keine Antwort nach 6 Minuten. Log: docker logs $name" >&2
exit 1
