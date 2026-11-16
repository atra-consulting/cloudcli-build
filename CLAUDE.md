# CLAUDE.md

Baut CloudCLI UI (`siteboon/claudecodeui`) mit `VITE_IS_PLATFORM=true` als eigenständiges Bundle
(linux-x64, Ubuntu 24.04) für Coder-Arbeitsplätze, mit einem Wächter davor. Überblick, Ablauf, Sicherheit
und Fehlersuche: [README.md](README.md).

## Regeln

- **Quellcode von upstream nie ändern** (keine Patches, kein Fork, auch nicht `package.json`). Grund: AGPL §13.
  Anpassungen nur über Build-Optionen, Umgebungsvariablen und `bundle/bin/`.
- **Sicherheit des Platform-Modus:** CloudCLI hat dann kein Login. Nichts darf CloudCLI oder den Wächter auf
  eine andere Adresse als `127.0.0.1` bringen (Ausnahme: `CLOUDCLI_HOST` in `run-local.sh`, nur im
  Container). Regeln des Wächters nur mit Prüfung in `scripts/smoke.sh` ändern.
- **Releases nie überschreiben.** Rebuild derselben upstream-Version: `release.version` erhöhen.
  Immutable releases sind im Repo aktiv: Tag und Dateien sind nach der Veröffentlichung gesperrt, ein
  Tag-Name ist auch nach dem Löschen verbraucht.
- **Feste Versionen:** upstream-Commit, Node mit Prüfsumme, Basis-Image mit Digest, Actions mit Commit-SHA.
  Kein `latest`.
- **Workflow:** Der Build-Job führt fremden Code aus und bekommt nur Leserechte. Schreibrecht nur im
  Release-Job, der keinen Code aus dem Build ausführt.
- **Öffentliches Repo:** keine internen Adressen, Projekt-IDs, Personennamen, Repo-Pfade der
  Coder-Installation oder Secrets.
- Sprache in Doku, Kommentaren und Commits: Deutsch, kurze Sätze, ein Begriff pro Sache
  (Bundle, Arbeitsplatz/Platz, Platform-Modus, Wächter, Smoketest).
- Jede Änderung am Bundle: `./build.sh` (enthält den Smoketest) muss grün sein. Neues Verhalten bekommt
  eine Prüfung in `scripts/smoke.sh`.

## Befehle

```bash
./build.sh                  # Build + Smoketest im Container ubuntu:24.04 (linux/amd64)
./run-local.sh              # neuestes Bundle lokal starten, http://localhost:3001
docker logs -f cloudcli-local
bash -n build.sh run-local.sh scripts/*.sh && sh -n bundle/bin/cloudcli-start bundle/bin/cloudcli-ensure-user \
  && node --check bundle/bin/cloudcli-guard.mjs   # Syntax
```

## Wo was steht

| Thema | Datei |
|---|---|
| Build-Ablauf, Entfernen von Codex und SDK-Binary, Paketumfang | `scripts/build-bundle.sh` |
| Was als „funktioniert“ gilt | `scripts/smoke.sh` |
| Start, `PATH` | `bundle/bin/cloudcli-start` |
| Wächter: Adressen, Ports, Regeln gegen fremde Seiten | `bundle/bin/cloudcli-guard.mjs` |
| Benutzer, Git-Identität, Onboarding | `bundle/bin/cloudcli-ensure-user` |
| Release-Ablauf, Rechte | `.github/workflows/build.yml` |
| Einbindung in den Arbeitsplatz (Template, systemd, Coder-App) | internes Repo der Coder-Installation |

## Stellen in upstream, von denen dieses Repo abhängt

Bei jeder neuen upstream-Version prüfen (Pfade relativ zu `siteboon/claudecodeui`):

| Abhängigkeit | Stelle |
|---|---|
| Platform-Modus im Server (Laufzeit-Variable) | `server/shared/utils.ts` (`IS_PLATFORM`) |
| Auth im Platform-Modus: erster Benutzer der DB | `server/modules/auth/auth.middleware.ts` |
| Agent-API ohne Key im Platform-Modus | `server/modules/agent/agent.routes.ts` (`validateExternalApiKey`) |
| WebSocket-Pfade `/shell`, `/ws` und ihre Auth | `server/index.ts`, `server/modules/websocket/` |
| Platform-Modus im Frontend (Build-Zeit), Prüfmarke `username:"platform-user"` | `src/shared/utils.ts`, `src/modules/auth/context/AuthContext.tsx` |
| Registrierung, nur ohne Benutzer | `server/modules/auth/auth.service.ts`, `auth.routes.ts` |
| Git-Identität und Onboarding | `server/modules/user/user.routes.ts`, `user.service.ts` |
| Claude Code aus `PATH` statt SDK-Binary | `server/shared/claude-cli-path.ts`, `server/modules/providers/list/claude/claude-runtime.provider.ts` |
| `HOST`, `SERVER_PORT`, `.env`, `DATABASE_PATH` | `server/index.ts`, `server/load-env.ts` |
| Paketumfang (`files`), Skripte `prepare`, `build` | `package.json` |
| Node-Hauptversion | `.nvmrc` |
