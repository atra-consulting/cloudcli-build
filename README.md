# cloudcli-build

[![Build](https://github.com/atra-consulting/cloudcli-build/actions/workflows/build.yml/badge.svg)](https://github.com/atra-consulting/cloudcli-build/actions/workflows/build.yml)

Fertig gebaute **[CloudCLI UI](https://github.com/siteboon/claudecodeui)** (früher „Claude Code UI“) für
Coder-Arbeitsplätze: Claude Code im Browser, mit Chat, Terminal, Dateien und Git, ohne eigenes Login.

Dieses Repo verändert den Code von CloudCLI nicht. Es baut den Quellcode eines festen upstream-Commits mit
einer anderen Build-Option, packt ihn mit allem, was er zur Laufzeit braucht, in ein einziges Archiv, setzt einen
kleinen Wächter davor und veröffentlicht das Ganze als GitHub Release.

---

## Inhalt

- [Warum es dieses Repo gibt](#warum-es-dieses-repo-gibt)
- [So spielt alles zusammen](#so-spielt-alles-zusammen)
- [Das Bundle](#das-bundle)
- [Schnellstart](#schnellstart)
- [Build](#build)
- [Lokal ausprobieren](#lokal-ausprobieren)
- [Versionen und Releases](#versionen-und-releases)
- [Neue upstream-Version übernehmen](#neue-upstream-version-übernehmen)
- [Einsatz auf einem Arbeitsplatz](#einsatz-auf-einem-arbeitsplatz)
- [Platform-Modus: was anders ist](#platform-modus-was-anders-ist)
- [Sicherheit](#sicherheit)
- [Fehlersuche](#fehlersuche)
- [Aufbau des Repos](#aufbau-des-repos)
- [Lizenz](#lizenz)

---

## Warum es dieses Repo gibt

CloudCLI hat ein eigenes Login mit genau einem Benutzer. Auf einem Coder-Arbeitsplatz meldet sich der
Teilnehmer aber schon bei [Coder](https://coder.com) an, und Coder lässt nur ihn selbst an die App. Ein
zweites Login mit eigenem Passwort wäre doppelt und müsste als Geheimnis auf den Platz.

CloudCLI kennt dafür den **Platform-Modus** (`VITE_IS_PLATFORM=true`): kein Login, alle Anfragen laufen als
der eine Benutzer der Datenbank, die Anmeldung übernimmt ein Proxy davor. Der Haken: Der Schalter wirkt
**beim Build**, Vite schreibt ihn fest ins Frontend. Das npm-Paket `@cloudcli-ai/cloudcli` ist ohne ihn
gebaut. Also bauen wir selbst, einmal zentral statt auf jedem Platz:

| | Build auf jedem Platz | Zentrales Bundle (dieses Repo) |
|---|---|---|
| Erster Start | 2–4 min, rund 2 GB RAM-Spitze | Download von rund 210 MB, Sekunden zum Entpacken |
| Abhängig von | npm-Registry, GitHub, Build-Werkzeugen | einem GitHub Release |
| Reproduzierbar | nein, jeder Platz baut neu | feste Versionen, SHA-256 im Template |
| Geprüft | nein | Smoketest vor jedem Release |

## So spielt alles zusammen

```
 Browser des Teilnehmers
        │  https://<app>--<agent>--<workspace>--<user>.<coder-domain>
        ▼
 ┌──────────────────────────┐   Login; nur der Besitzer des Platzes
 │ Coder (App, Subdomain)   │   (coder_app mit share = "owner")
 └────────────┬─────────────┘
              │ Tunnel des Coder-Agents, keine öffentliche IP nötig
              ▼
 ┌──────────────────────────────────────────── Arbeitsplatz (VM) ──┐
 │  127.0.0.1:3001   cloudcli-guard  (lehnt fremde Seiten ab)      │
 │        │                                                        │
 │  127.0.0.1:13001  CloudCLI (Platform-Modus)                     │
 │        ├── claude  (Claude Code des Platzes, aus PATH)          │
 │        ├── git, Terminal (node-pty), Dateien in ~/workspace     │
 │        └── ~/.cloudcli/auth.db (Benutzer, Einstellungen)        │
 └─────────────────────────────────────────────────────────────────┘
```

Beide Ports liegen nur auf `127.0.0.1`. Von außen kommt man ausschließlich über Coder heran, und auch dann
nur mit Anfragen, die von der App selbst stammen (siehe [Sicherheit](#sicherheit)).

## Das Bundle

Ein Release besteht aus `cloudcli-<tag>-atra.<n>-linux-x64.tar.gz` und der Prüfsumme `….tar.gz.sha256`.
Das Archiv hat genau einen Ordner:

```
cloudcli/
├── node/                     Node.js (node.version), passend zu den nativen Modulen
├── app/                      CloudCLI im Umfang des npm-Pakets, mit node_modules
│   ├── dist/                 Frontend, gebaut mit VITE_IS_PLATFORM=true
│   └── dist-server/          Server
├── bin/
│   ├── cloudcli-start        Startpunkt: startet Wächter und CloudCLI
│   ├── cloudcli-guard.mjs    Wächter vor CloudCLI (nur Node-Bordmittel)
│   └── cloudcli-ensure-user  richtet Benutzer und Git-Identität ein (wiederholbar)
├── LICENSE, NOTICE           aus upstream (AGPL-3.0-or-later)
└── SOURCE.txt                Quelle, Commit, Abweichungen, Stand der Build-Skripte
```

**Eigenes Node:** Die nativen Module (`better-sqlite3`, `node-pty`, `bcrypt`) sind für genau diese
Node-Version gebaut. Deshalb bringt das Bundle sein Node mit und hängt nicht davon ab, ob und welches Node
der Teilnehmer installiert hat. Auf dem Platz braucht es weder npm noch einen Compiler.

**Bewusst weggelassen** (rund 715 MB, das Archiv schrumpft von rund 500 auf rund 210 MB):

| Paket | Größe | Warum |
|---|---|---|
| `@openai/codex-linux-x64` | ~435 MB | Den Anbieter Codex bieten die Plätze nicht an. CloudCLI zeigt ihn als „nicht installiert“. |
| `@anthropic-ai/claude-agent-sdk-linux-x64` | ~280 MB | Eigenes Claude-Binary des Agent SDK. CloudCLI übergibt dem SDK unter Linux immer den Befehl aus `CLAUDE_CLI_PATH` (Standard: `claude` aus `PATH`). Das mitgelieferte Binary bleibt also ungenutzt. |

> **Wichtig:** Ohne Claude Code im `PATH` des Servers funktioniert der Chat nicht. Auf dem Platz liegt
> Claude Code in `~/.local/bin`.

### `bin/cloudcli-start`

Startet den Wächter, der seinerseits CloudCLI als Kindprozess startet. Endet CloudCLI, endet auch der
Wächter, damit systemd neu starten kann. Das Node des Bundles wird **hinten** an `PATH` angehängt:
Kindprozesse finden so ein `node`, im Terminal der UI bleibt das Node des Teilnehmers vorn.

| Variable | Standard | Bedeutung |
|---|---|---|
| `CLOUDCLI_HOST` | `127.0.0.1` | Adresse des Wächters. Nur für Container ändern (siehe `run-local.sh`). |
| `SERVER_PORT` | `3001` | Port des Wächters, auf den die Coder-App zeigt |
| `CLOUDCLI_INTERNAL_PORT` | `13001` | Port von CloudCLI, immer auf `127.0.0.1` |
| `DATABASE_PATH` | `~/.cloudcli/auth.db` | SQLite-Datenbank (Benutzer, Einstellungen, API-Keys) |
| `WORKSPACES_ROOT` | `$HOME` | Wurzel, unter der CloudCLI Projekte anlegen darf |
| `CLAUDE_CLI_PATH` | `claude` | Befehl oder Pfad von Claude Code |

Die allgemeine Variable `HOST` wird **ignoriert**. CloudCLI selbst würde sie lesen und mit einem geerbten
`HOST=0.0.0.0` ohne Login auf allen Adressen lauschen.

### `bin/cloudcli-ensure-user BENUTZER [GIT_NAME GIT_EMAIL]`

Wartet, bis der Server antwortet, und richtet ihn ein. Jeder Schritt läuft nur, solange er noch fehlt.
Scheitert ein Schritt, endet das Skript mit Fehler, ein neuer Aufruf holt ihn nach.

1. **Benutzer anlegen.** Der Platform-Modus braucht genau einen Benutzer in der Datenbank. Das Passwort ist
   zufällig und wird verworfen, in der Datenbank liegt nur sein Hash. CloudCLI fragt es im Platform-Modus nie
   ab.
2. **Git-Identität und Einrichtungsassistent** (nur mit `GIT_NAME` und `GIT_EMAIL`): CloudCLI speichert die
   Werte und schreibt sie nach `git config --global`, das Skript prüft das nach. Danach gilt der
   Einrichtungsassistent als erledigt. Das passiert nur beim ersten Mal. Ändert der Teilnehmer seine Werte
   später, bleiben sie.

## Schnellstart

```bash
./build.sh          # Bundle bauen, inklusive Smoketest (Docker nötig)
./run-local.sh      # im Container starten
open http://localhost:3001
```

## Build

Voraussetzung ist nur Docker. `build.sh` startet `scripts/build-bundle.sh` in einem Container
`ubuntu:24.04` für `linux/amd64`, fest auf einen Digest gepinnt. Damit passen glibc und native Module zu den
Arbeitsplätzen (Ubuntu 24.04, x86_64), egal ob auf einem Mac oder in GitHub Actions gebaut wird. Auf Apple
Silicon emuliert Docker Desktop amd64 über Rosetta. Ein Build dauert dort rund 2,5 Minuten, der npm-Cache
liegt im Volume `cloudcli-build-npm`.

Was der Build tut:

1. Node (`node.version`) von nodejs.org laden und gegen die feste Prüfsumme aus `node.sha256` prüfen
2. `siteboon/claudecodeui` am Tag aus `cloudcli.version` klonen; der Commit muss `cloudcli.commit`
   entsprechen, sonst bricht der Build ab (verschobener Tag)
3. `npm ci` (ohne Electron-Download), dann `VITE_IS_PLATFORM=true npm run build`
4. prüfen, dass das Frontend wirklich im Platform-Modus gebaut ist
5. Entwicklungsabhängigkeiten entfernen, Codex- und SDK-Binary löschen
6. App im Umfang der `files` aus `package.json` mit `node_modules`, Node, Wächter und Startskripten packen
7. **Smoketest** gegen das fertige Archiv (`scripts/smoke.sh`)

Der Smoketest entpackt das Archiv in ein leeres `HOME` und prüft:

| Bereich | Prüfung |
|---|---|
| Einrichtung | Benutzer und Git-Identität werden angelegt (in CloudCLI und `git config --global`), der Einrichtungsassistent gilt als erledigt, ein zweiter Aufruf ändert nichts |
| Server | `/health`, geschützte API antwortet **ohne** Token (Platform-Modus), Frontend wird ausgeliefert |
| Adressen | trotz geerbtem `HOST=0.0.0.0` lauschen beide Ports nur auf `127.0.0.1` |
| Wächter | Anfragen anderer Seiten, fremder Origin, Einbetten im iframe, Registrierung aus dem Browser und fremder WebSocket werden abgelehnt; eigene Anfragen, eigener WebSocket und das Öffnen über einen Link gehen durch |
| Claude | CloudCLI ruft `claude` aus `PATH` auf (mit einem Platzhalter-Skript) |
| Bundle | `better-sqlite3` und `node-pty` laden, ein Terminal liefert Ausgabe; Codex- und SDK-Binary fehlen |

Ergebnis: `out/cloudcli-<tag>-atra.<n>-linux-x64.tar.gz` und `.sha256`.

## Lokal ausprobieren

```bash
./run-local.sh                                   # neuestes Bundle aus out/
./run-local.sh out/cloudcli-…-linux-x64.tar.gz   # bestimmtes Bundle
GIT_NAME="Erika Muster" GIT_EMAIL=erika@example.com ./run-local.sh
```

Der Container `cloudcli-local` ist ein kleiner Arbeitsplatz: Ubuntu 24.04 (amd64), Benutzer `dev`, Claude
Code in `~/.local/bin`, Projekte in `~/workspace`. Ohne `GIT_NAME` und `GIT_EMAIL` setzt das Skript
Platzhalter. `run-local.sh` meldet „Bereit“ erst, wenn die Einrichtung fertig ist. Claude Code installiert der
Container beim ersten Start mit dem offiziellen Installer in der jeweils aktuellen Version; das ist nur für
den lokalen Test gedacht.

| Aufgabe | Befehl |
|---|---|
| Öffnen | http://localhost:3001 |
| Claude Code anmelden | in der UI im Tab „Shell“: `claude`, dann `/login` |
| Log ansehen | `docker logs -f cloudcli-local` |
| Stoppen | `docker rm -f cloudcli-local` |
| Alles zurücksetzen | `docker volume rm cloudcli-local-home` (Claude-Anmeldung, Projekte, Datenbank) |

> **Achtung:** Ohne Coder davor hat CloudCLI kein Login. Im Container lauscht der Wächter auf `0.0.0.0`,
> Docker veröffentlicht den Port aber nur auf `127.0.0.1` des eigenen Rechners. Nie weiter freigeben.

## Versionen und Releases

| Datei | Inhalt | Beispiel |
|---|---|---|
| `cloudcli.version` | Tag von `siteboon/claudecodeui` | `v1.37.9` |
| `cloudcli.commit` | Commit, auf den der Tag zeigen muss | `f86543f…` |
| `node.version` | Node.js, gleiche Hauptversion wie upstream (`.nvmrc`) | `v22.23.5` |
| `node.sha256` | SHA-256 von `node-<version>-linux-x64.tar.xz` | `cdeb867…` |
| `release.version` | Zähler für Rebuilds derselben upstream-Version | `1` |

Daraus ergibt sich der Name von Bundle und Release-Tag: `cloudcli-v1.37.9-atra.1-linux-x64`.

`.github/workflows/build.yml` hat zwei Jobs:

- **build** (nur Leserechte, kein Token im Checkout): bauen und Smoketest. Bei einem Pull Request endet
  der Workflow hier.
- **release** (Schreibrecht, nur auf `main`): nimmt das fertige Archiv aus dem Build-Job, prüft die
  Prüfsumme und legt das Release mit Archiv, Prüfsumme und Links auf den Quellcode an. Dieser Job führt
  keinen Code von upstream aus.

Der Workflow überschreibt **nie** ein Release. Gibt es den Tag schon, baut er nicht neu. Für einen Rebuild
derselben upstream-Version, etwa mit neuerem Node oder geändertem Skript, `release.version` erhöhen.

## Neue upstream-Version übernehmen

1. [Releases von claudecodeui](https://github.com/siteboon/claudecodeui/releases) und `CHANGELOG.md` lesen.
   Besonders Änderungen an Auth, Platform-Modus, Onboarding, WebSocket und `CLAUDE_CLI_PATH` beachten.
   [`CLAUDE.md`](CLAUDE.md) nennt die Stellen im Quellcode, von denen dieses Repo abhängt.
2. `cloudcli.version` auf den neuen Tag setzen, `cloudcli.commit` auf dessen Commit
   (`git ls-remote https://github.com/siteboon/claudecodeui.git refs/tags/<tag>`), `release.version` auf `1`.
3. Bei Bedarf `node.version` und `node.sha256` anheben (Hauptversion wie upstream; Prüfsumme aus
   `https://nodejs.org/dist/<version>/SHASUMS256.txt`, besser gegen die Signatur geprüft).
4. `./build.sh` und `./run-local.sh`, dann von Hand prüfen: Chat mit Claude, Shell, Dateien, Git.
5. Pull Request. Der Workflow baut und testet. Nach dem Merge entsteht das Release.
6. Im Coder-Template Release-Name und SHA-256 eintragen.

## Einsatz auf einem Arbeitsplatz

Das Coder-Template lädt ein festes Release. Im Kern:

```bash
release=cloudcli-v1.37.9-atra.1-linux-x64
sha256=<aus dem Release>
curl -fsSL -o /tmp/$release.tar.gz \
  https://github.com/atra-consulting/cloudcli-build/releases/download/$release/$release.tar.gz
echo "$sha256  /tmp/$release.tar.gz" | sha256sum -c -
tar -xzf /tmp/$release.tar.gz -C ~/.local          # ergibt ~/.local/cloudcli

# systemd-Dienst als Benutzer des Teilnehmers, PATH mit ~/.local/bin (Claude Code)
~/.local/cloudcli/bin/cloudcli-start
# danach, einmal nach jedem Start (wiederholbar)
~/.local/cloudcli/bin/cloudcli-ensure-user "$CODER_USER" "$GIT_NAME" "$GIT_EMAIL"
```

Davor steht eine Coder-App mit `subdomain = true` und `share = "owner"`, die auf `http://127.0.0.1:3001`
zeigt. Als Healthcheck eignet sich `http://127.0.0.1:3001/api/auth/user`: Er meldet erst Erfolg, wenn
`cloudcli-ensure-user` den Benutzer angelegt hat.

## Platform-Modus: was anders ist

| Bereich | Normal | Platform-Modus |
|---|---|---|
| Login | Benutzername und Passwort, Token im Browser | keins, alle Anfragen als erster Benutzer der Datenbank |
| Einrichtungsseite | erster Aufruf legt Benutzer an | entfällt, `cloudcli-ensure-user` legt ihn an |
| Externe Agent-API (`/api/agent`) | braucht einen API-Key | ohne Key |
| CLI-Updates aus der UI | möglich | abgeschaltet (Claude Code verwaltet der Platz) |
| Logo oben links | ohne Link | verlinkt auf das Dashboard von cloudcli.ai |
| Anmeldedialoge anderer Anbieter | Pfad leer | Pfad `/workspace` |
| GitHub-Stern-Hinweis | sichtbar | ausgeblendet |

## Sicherheit

Im Platform-Modus prüft CloudCLI weder Anmeldung noch Herkunft einer Anfrage: CORS ist offen, WebSocket
prüft keinen Origin, `/api/agent` startet Claude ohne Key. Wer CloudCLI erreicht, kann im Terminal alles,
was der Benutzer des Platzes kann. Drei Schichten schützen davor:

1. **Nur `127.0.0.1`.** Wächter und CloudCLI lauschen nur lokal. Die allgemeine Variable `HOST` wird
   ignoriert, der Smoketest prüft das.
2. **Coder davor.** Die Coder-App mit `share = "owner"` lässt nur den angemeldeten Besitzer des Platzes durch.
3. **Wächter (`cloudcli-guard.mjs`).** Der Browser des Besitzers schickt sein Coder-Cookie auch bei
   Anfragen, die eine andere Seite derselben Site auslöst, etwa die App eines anderen Teilnehmers unter
   `*.<coder-domain>`. Der Wächter lehnt deshalb ab:
   - Browser-Anfragen mit `Sec-Fetch-Site: same-site` oder `cross-site`, außer dem Öffnen der App als Seite
     (GET, Navigation, kein iframe)
   - bei Browsern ohne Fetch Metadata: einen `Origin`, der nicht zum Host passt
   - Registrierung und Login aus dem Browser; im Platform-Modus braucht sie niemand

   Anfragen ohne Browser-Merkmale (curl, Healthcheck von Coder) gehen durch.

Weitere Punkte:

- **Keine Geheimnisse im Bundle.** Das Passwort aus `cloudcli-ensure-user` ist zufällig und wird verworfen.
  Die Claude-Anmeldung liegt beim Teilnehmer in `~/.claude`.
- **Bis `cloudcli-ensure-user` gelaufen ist,** kann der erste lokale Aufruf von `/api/auth/register` den
  Benutzer festlegen. Aus dem Browser blockt das der Wächter; lokal hat ohnehin nur der Platz selbst Zugriff.
  Den Healthcheck der Coder-App auf `/api/auth/user` legen (siehe oben).
- **Herkunft prüfbar.** Node gegen eine feste Prüfsumme im Repo, Quellcode als fester Commit (ein
  verschobener Tag bricht den Build ab), Basis-Image als fester Digest, Actions als feste Commit-SHAs. Die
  Plätze prüfen das Archiv gegen die SHA-256 im Template.
- **Build ohne Schreibrecht.** Der Build führt fremden Code aus (npm-Skripte) und läuft deshalb in einem Job
  ohne Schreibrecht und ohne im Checkout gespeichertes Token. Der Build-Container bekommt nur das Job-Token
  mit reinen Leserechten (`GITHUB_TOKEN`), weil `@vscode/ripgrep` ripgrep über die GitHub-API lädt und
  anonym auf den geteilten IPs der Runner am Rate-Limit scheitert.

## Fehlersuche

| Symptom | Ursache und Lösung |
|---|---|
| Login-Seite statt Projekte | Frontend ohne Platform-Modus gebaut. Der Build bricht in diesem Fall eigentlich ab, `scripts/build-bundle.sh` prüfen. |
| `Platform mode: No user found in database` | `cloudcli-ensure-user` lief nicht. Aufrufen, während der Server läuft. |
| Einrichtungsassistent erscheint | `cloudcli-ensure-user` ohne `GIT_NAME` und `GIT_EMAIL` aufgerufen. |
| `Abgelehnt: …` (HTTP 403) | Der Wächter hat eine Anfrage abgelehnt. Grund steht in der Antwort und im Log (`cloudcli-guard: abgelehnt …`). |
| `CloudCLI nicht erreichbar` (HTTP 502) | CloudCLI startet noch oder ist abgestürzt. Log ansehen. |
| Chat: „Not logged in · Please run /login“ | Claude Code ist gefunden, aber nicht angemeldet. Im Tab „Shell“: `claude`, dann `/login`. |
| Chat: `spawn claude ENOENT` | Claude Code fehlt im `PATH` des Servers. `PATH` setzen oder `CLAUDE_CLI_PATH`. |
| `Tag … zeigt auf …, erwartet …` | Der upstream-Tag wurde verschoben. Änderung ansehen, dann `cloudcli.commit` bewusst anpassen. |
| `run-local.sh` hängt bei „Warte auf CloudCLI“ | Beim ersten Start installiert der Container Claude Code. `docker logs -f cloudcli-local` |
| Build scheitert bei `npm ci` | Netz oder neue upstream-Abhängigkeit. Log mit `./build.sh 2>&1 \| tee build.log` |

## Aufbau des Repos

```
cloudcli-build/
├── cloudcli.version, cloudcli.commit   upstream-Tag und erwarteter Commit
├── node.version, node.sha256           Node.js für das Bundle und seine Prüfsumme
├── release.version                     Zähler für Rebuilds
├── build.sh                            baut im Container (lokal und in CI gleich)
├── run-local.sh                        lokaler Test in Docker
├── scripts/
│   ├── build-bundle.sh                 eigentlicher Build (läuft im Container)
│   └── smoke.sh                        Smoketest gegen ein fertiges Archiv
├── bundle/bin/                         Startskript, Wächter, Einrichtung (kommen ins Bundle)
├── .github/workflows/build.yml         Build, Smoketest, Release
├── CLAUDE.md                           Hinweise für Claude Code und Betreuer
├── LICENSE                             AGPL-3.0
└── README.md
```

## Lizenz

CloudCLI UI ist © Siteboon AI B.V. und Mitwirkende und steht unter der
**GNU Affero General Public License v3.0 or later**. `LICENSE` und `NOTICE` liegen in jedem Bundle.

Der Quellcode von CloudCLI wird **unverändert** gebaut. Abweichend vom Quellstand enthält das Bundle ein mit
`VITE_IS_PLATFORM=true` gebautes Frontend, nur Laufzeit-Abhängigkeiten ohne das Codex- und das SDK-Binary,
sowie die Skripte aus `bundle/bin/`. `SOURCE.txt` im Archiv und die Beschreibung jedes Releases nennen den
upstream-Commit und den Stand dieses Repos. Zusammen ist das der vollständige Quellcode zu jedem Bundle.

Eigene Änderungen am Quellcode von CloudCLI gehören nicht hierher. Sie würden nach AGPL §13 verlangen, den
geänderten Quellcode allen Nutzern der Arbeitsplätze anzubieten.

Die Skripte in diesem Repo stehen ebenfalls unter AGPL-3.0-or-later.
