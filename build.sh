#!/usr/bin/env bash
# =============================================================================
# Baut das CloudCLI-Bündel für Coder-Arbeitsplätze (linux-x64, Ubuntu 24.04).
#
# Läuft auf dem Mac wie in GitHub Actions gleich: Der eigentliche Bau
# (scripts/build-bundle.sh) läuft in einem Container ubuntu:24.04 für
# linux/amd64, fest auf einen Digest gepinnt. So passen glibc und die nativen
# Module zu den Plätzen. Auf Apple Silicon emuliert Docker Desktop amd64
# (Rosetta), das dauert einige Minuten.
#
# Ergebnis: out/cloudcli-<tag>-atra.<n>-linux-x64.tar.gz und .sha256
# Versionen: cloudcli.version, cloudcli.commit, node.version, node.sha256,
#            release.version
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# ubuntu:24.04 (Multi-Arch-Index), Stand 2026-11-16
image="ubuntu:24.04@sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8"
mkdir -p out

# Stand der Bau-Skripte für SOURCE.txt; "-dirty" bei lokalen Änderungen
build_commit=$(git rev-parse --verify -q HEAD 2>/dev/null || echo unbekannt)
if [ "$build_commit" != unbekannt ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  build_commit="$build_commit-dirty"
fi

# npm-Cache als benanntes Volume: zweiter Bau lädt nicht alles neu
docker run --rm --platform linux/amd64 \
  -v "$PWD":/repo:ro \
  -v "$PWD/out":/out \
  -v cloudcli-build-npm:/root/.npm \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  -e BUILD_SCRIPTS_COMMIT="$build_commit" \
  "$image" bash /repo/scripts/build-bundle.sh
