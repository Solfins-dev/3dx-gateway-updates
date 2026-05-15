# 3DX Gateway — Install Guide

End-to-end install of the 3DX Gateway at your site. Plan for ~30 minutes
on the server, plus ~5 minutes per workstation.

---

## What you're installing

| Component | Where | What it does |
| --- | --- | --- |
| **Backend container** (`ghcr.io/solfins-dev/3dx-gateway`) | One Docker host on your LAN | Web UI + REST API. Holds the 3DX / Pantheon credentials, runs BOM sync workers, serves the SPA. |
| **PostgreSQL container** | Same Docker host | Stores BOM snapshots, sync logs, audit trail. |
| **CadBridge agent** (`CadBridge.Agent.exe`) | Each CAD designer's workstation | Local-only HTTP service that talks to SolidWorks / CATIA over COM. Required for the **Generate & Export** flow. |

All three pull updates from a public manifest hourly. No outbound traffic
besides the manifest poll, the `ghcr.io` image pull, and the
`Solfins-dev/3dx-gateway-updates` GitHub Release for the CadBridge ZIP.

---

## Before you start — prerequisites

### Server (Docker host)

- **OS**: Linux (Ubuntu 22.04 / 24.04 verified) or Windows Server with WSL2
- **Docker Engine**: 20.10 or newer (`docker compose` v2 syntax)
- **CPU / RAM**: 2 vCPU, 2 GB RAM minimum. 4 vCPU, 4 GB recommended.
- **Disk**: ~3 GB for the image + a few hundred MB for the database (grows with BOM history)
- **Outbound network**: HTTPS to `ghcr.io` (image pull) and `raw.githubusercontent.com` (manifest poll)
- **Inbound network**: TCP 5000 reachable from every workstation (or behind your own reverse proxy on 443)

### Workstations

- **OS**: Windows 10 / 11 (64-bit)
- **CAD**: SolidWorks (any of: Connected, Connector, or 3DEXPERIENCE Launcher) or CATIA V5 / V6
- **Network**: HTTPS reach to the gateway host on whichever port you exposed
- **Admin rights**: needed once for the first install (Setup.bat installs the gateway's CA cert)

### From Solfins (out of band)

- **`license.lic`** — your signed license file. Delivered via email / download portal as part of your purchase. Includes your customer name, enabled modules, expiry date, and seat count.

---

## Step 1 — Start the gateway

There are two ways: the **one-line installer** (recommended for most
customers) and the **manual path** (for sysadmins who want to inspect
every file). Both produce the same end state — a Docker stack at
`/opt/3dx-gateway/` managed by a systemd unit.

### 1.A One-line installer (recommended)

**Note on the license file.** Solfins emails `license.lic` to you
separately from this installer (we don't bundle licenses in the public
installer for security reasons). You can:

- Provide the license at install time with `--license /path/to/license.lic`
  (Linux) or `-License C:\path\to\license.lic` (Windows), OR
- Run the installer first and add the license later — the gateway
  starts in an "awaiting license" state (containers running, but
  refuses logins). When Solfins emails the file, drop it in the install
  directory and restart the service.

#### Linux

```sh
curl -sSLO https://raw.githubusercontent.com/Solfins-dev/3dx-gateway-updates/main/install.sh
sudo bash install.sh
```

#### Windows Server

You don't need Docker pre-installed -- the installer detects it's
missing and offers to install Docker Desktop automatically (~600 MB
download, may need a reboot for WSL2 enablement on first run).

Pick one of three ways to launch the installer:

**A) Double-click `install.bat` (easiest, no shell needed)**

Download the [`install.bat`](https://raw.githubusercontent.com/Solfins-dev/3dx-gateway-updates/main/install.bat)
file (~1 KB), right-click -> **Run as administrator** (or just
double-click and accept the UAC prompt). The .bat self-elevates,
downloads the latest `install.ps1` from this same repo, and runs it.
Window stays open at the end so you can read the summary.

**B) PowerShell one-liner**

Open an **elevated PowerShell** and paste:

```pwsh
Set-ExecutionPolicy Bypass -Scope Process -Force; `
  irm https://raw.githubusercontent.com/Solfins-dev/3dx-gateway-updates/main/install.ps1 `
  -OutFile $env:TEMP\install.ps1; & $env:TEMP\install.ps1
```

**C) Manual download + run (advanced)**

For inspecting the script before execution, or behind a firewall that
needs proxy config:

```pwsh
Invoke-WebRequest -UseBasicParsing `
  https://raw.githubusercontent.com/Solfins-dev/3dx-gateway-updates/main/install.ps1 `
  -OutFile $env:TEMP\install.ps1
& $env:TEMP\install.ps1
```

All three flow into the same install.ps1 (interactive prompts, ~5 min
once Docker is up). The installer writes files under
`C:\ProgramData\3DX-Gateway` by default; override with
`-InstallDir D:\3dx-gateway` (one-liner: append after the script
invocation; .bat: edit the path inside or run install.ps1 directly).
Container auto-start across host reboots relies on Docker Desktop's
"Start when you log in" setting (Settings -> General).

The Apply Update host helper is **available on Windows** -- the
installer offers an optional install step that registers a Scheduled
Task running `scripts/host/3dx-gateway-helper.ps1` as SYSTEM. The task
listens on TCP 5171 (auth via a 32-byte token generated at install
time + stored in `%PROGRAMDATA%\3dx-gateway\helper-token.txt` with
ACL Admins+SYSTEM only) and lets the web UI's Settings -> Updates
card trigger `docker compose pull && up -d` from the host. The
gateway container reaches the helper via `host.docker.internal:5171`
(Docker Desktop's automatic bridge DNS) -- the `extra_hosts`
mapping in `docker-compose.helper.windows.yml` is added to the
compose flags by `install.ps1`. CadBridge updates on workstations
work the same way as on Linux.

#### Both platforms

The installer asks five questions (install dir, hostname, port, TLS
mode, license file path), runs pre-flight checks (Docker version,
free disk + RAM, free port), generates a strong Postgres password,
writes the compose files + `.env` + systemd unit, pulls the images,
starts the stack, and smoke-tests `/api/license/status`. Takes about
two minutes on a server with a warm Docker cache.

Defaults work for ~80% of installs:

| Question | Default | When to override |
|---|---|---|
| Install dir | `/opt/3dx-gateway` | You want a different mount point |
| Hostname | `hostname --fqdn` of the server | Workstations reach the gateway under a different DNS name |
| TLS mode | `auto` (Caddy + local CA) | You already run a reverse proxy; pick `none`. Public DNS + ports 80/443 reachable from the internet; pick `letsencrypt` |
| Port | `443` (TLS) or `5000` (no TLS) | Port is already used; the installer checks and fails clearly |
| Apply Update helper | Skipped in unattended (`--yes`) mode; install asks Y/N interactively | Enables the one-click "Apply Update" admin button in the web UI. Optional. |

**Unattended/scripted install** for CI or configuration management:

Linux:
```sh
curl -sSLO https://raw.githubusercontent.com/Solfins-dev/3dx-gateway-updates/main/install.sh
sudo bash install.sh -y \
    --hostname gateway.acme.local \
    --port 443 \
    --tls auto \
    --license /tmp/acme.lic \
    --helper
```

Windows:
```pwsh
& $env:TEMP\install.ps1 `
    -Hostname gateway.acme.local `
    -Port 443 `
    -Tls auto `
    -License C:\tmp\acme.lic `
    -Yes
```

Pass `--help` (Linux) or `Get-Help install.ps1 -Full` (Windows) to see
all flags. The installer is idempotent: if an install already exists at
the target directory it refuses with a clear error rather than
overwriting state.

**If Docker isn't installed yet,** the installer offers to run the
official `get.docker.com` script. Decline (`N`) if you prefer your
distribution's package manager — the installer prints the right
`docker.com` URL and exits.

### 1.B Manual path

Use this if you want full control over file placement, or you're
behind a corporate firewall that blocks `raw.githubusercontent.com`
but allows `ghcr.io` + your own mirror.

#### 1.B.1 Create a working directory

```sh
mkdir -p ~/3dx-gateway
cd ~/3dx-gateway
```

#### 1.B.2 Drop in `docker-compose.prod.yml`

```yaml
# docker-compose.prod.yml
services:
  app:
    image: ghcr.io/solfins-dev/3dx-gateway:latest
    container_name: 3dx-gateway-app
    restart: unless-stopped
    ports:
      - "${APP_PORT:-5000}:5000"
    environment:
      ASPNETCORE_ENVIRONMENT: Production
      ConnectionStrings__BomExplorer: "Host=postgres;Port=5432;Database=bom_explorer;Username=bomapp;Password=${POSTGRES_PASSWORD}"
    volumes:
      - app_data:/app/data
      - ./license.lic:/app/license.lic:ro
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5000/api/license/status"]
      interval: 30s
      timeout: 5s
      retries: 3

  postgres:
    image: postgres:16-alpine
    container_name: 3dx-gateway-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: bom_explorer
      POSTGRES_USER: bomapp
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U bomapp -d bom_explorer"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  pgdata:
  app_data:
```

> A canonical copy is in the public repo at
> [`docker-compose.prod.yml`](https://github.com/Solfins-dev/3dx-gateway-updates/blob/main/docker-compose.prod.yml).

#### 1.B.3 Create `.env`

```sh
cat > .env <<'EOF'
POSTGRES_PASSWORD=<choose a strong password and keep it>
APP_PORT=5000
EOF
chmod 600 .env
```

The PostgreSQL password is set ONCE at first start. Changing it later
requires either updating both the container and the existing data
volume (not covered here) or destroying `pgdata` and re-syncing.

#### 1.B.4 Drop in your license file

```sh
cp /path/to/license.lic ./license.lic
chmod 644 license.lic
```

The container mounts this file read-only at `/app/license.lic`.

#### 1.B.5 Pull and start

```sh
docker compose -f docker-compose.prod.yml up -d
```

First start takes ~30 seconds to pull the image, ~10 seconds for Postgres
to initialize, and another ~5 seconds for the backend to migrate the
database schema. Verify:

```sh
docker compose -f docker-compose.prod.yml ps
# Both 3dx-gateway-app and 3dx-gateway-db should be "running" / "healthy"

curl http://localhost:5000/api/license/status
# Expected: {"valid":true,"customer":"<your name>","modules":[...],"expiresAt":"..."}
```

#### 1.B.6 (Recommended) TLS via reverse proxy

For LAN access from workstations you'll want HTTPS. Two common patterns:

- **You already run a reverse proxy** (Nginx, Traefik, your own Caddy):
  point it at `http://localhost:5000` and terminate TLS there.
- **You don't**: drop a Caddy container in front. The one-line installer
  in §1.A does this for you with `--tls auto`. Manually: see
  `docker-compose.tls.yml` shape that the installer generates, or contact
  Solfins support for a ready-to-use overlay.

Whichever route you pick, the gateway URL workstations will use is
something like `https://gateway.yourcompany.local`.

---

## Step 2 — First-time configuration (web UI)

Open `https://<your-gateway-url>/` in a browser. You'll land on the login page.

### 2.1 Log in with 3DX credentials

The gateway authenticates against your 3DEXPERIENCE platform — there is no
separate user database. Enter your 3DEXPERIENCE username, password, region
code, and tenant ID. The "Speed login" toggle saves the IAM URL for next
time.

### 2.2 Configure Pantheon (if you have it)

`Settings → Pantheon`:
- **BaseUrl**: your Pantheon REST endpoint, e.g. `http://pantheon.yourcompany.local:9001`
- **Username + Password**: API user credentials (passwords are encrypted at rest with a per-deployment seed)
- **Database name**: your Pantheon database (e.g. `OurCompany_PROD`)
- **Field mappings + ERP sync options**: defaults work for most installs.
  Solfins delivers a Pantheon integration handbook covering the field-by-
  field mapping; ask support@solfins.com if you need a copy.

Click **Test connection** to verify the credentials before saving.

### 2.3 Other integrations

`Settings → DelmiaWorks` / `Settings → Webhooks` follow the same pattern.
Each integration has its own card with a Test button.

---

## Step 3 — Install CadBridge on each workstation

### 3.1 Stop the existing agent (skip if first install)

If a CadBridge tray icon is already running:

1. Right-click the tray icon → **Exit**.
2. Wait ~2 seconds for the process to terminate (otherwise the locked
   `CadBridge.Agent.exe` blocks the next extract).

### 3.2 Download the installer

In a browser on the workstation:

```
https://<your-gateway-url>/api/downloads/CadBridge-Setup.zip
```

Save to `Downloads`.

### 3.3 Extract and run

1. Right-click `CadBridge-Setup.zip` → **Extract All** → pick a folder.
2. In the extracted folder, right-click `Setup.bat` → **Run as administrator**.

The installer:

- **Strips the Internet-zone markers** from every extracted file. (Without
  this, Windows would prompt "Do you want to run scripts from the
  Internet?" for `Setup.ps1` and "Unknown publisher" for
  `CadBridge.Agent.exe`. The signing is on the Phase 2 roadmap; until then
  this `Unblock-File` step is the workaround.)
- **Fetches the gateway's CA certificate** (`/caddy-ca.crt`) and installs
  it into `Local Machine\Trusted Root Certification Authorities`. This is
  what lets the workstation talk to `https://<your-gateway-url>/` without
  warnings.
- **Registers the agent** to autostart at login and **launches** it now.

A green CAD Bridge icon should appear in the tray after about 5 seconds.
Hover it for the build version, connection status, and active CAD mode.

### 3.4 Verify the workstation can reach the gateway

In a fresh browser tab on the workstation, open
`https://<your-gateway-url>/`. You should see the login screen with no
certificate warnings.

Repeat steps 3.1 - 3.4 on every workstation.

---

## Step 4 — Day-to-day updates

The gateway polls a public manifest every hour. When a new version is
available:

- **In the web app**, an "Update available" pill appears in the top-right
  near the License badge. Click it → Settings → Updates card shows
  what's new for both the backend and CadBridge.
- **On a workstation**, the CadBridge tray menu surfaces a `↑ Update
  available — v1.x.y` item with a one-shot balloon notification on first
  detection.

### 4.1 Apply a backend update

Two paths:

**Manual (default).** On the gateway host, ~30 seconds of downtime:

```sh
cd ~/3dx-gateway
docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d
```

The container restarts on the new image; PostgreSQL stays up; sessions
need to log in again once.

**One-click from the web UI (optional).** If you ran the host-side
updater helper once at install time (next subsection), the same
**Settings → Updates → ✨ Apply Update** button you may already use
for CadBridge will appear for the backend too. The web UI confirms,
pulls the new image in the background, restarts the container, and
auto-reloads once the new backend answers.

### 4.1.1 Enable one-click backend updates (optional)

The one-click flow needs a small helper running on the host *outside*
the gateway container — because a container cannot restart itself
cleanly. The helper is a single shell script + systemd-socket-activated
unit; it sits idle until the gateway POSTs to it, runs
`docker compose pull && up -d`, and exits.

To install:

The four helper files (script + systemd .socket + .service template +
the docker-compose overlay) ship in the public manifest repo at
`Solfins-dev/3dx-gateway-updates/scripts/host/`. The simplest install:

```sh
cd ~/3dx-gateway
# Grab the helper bundle (or copy them from the install email Solfins sent).
for f in install-helper.sh uninstall-helper.sh 3dx-gateway-helper.sh \
         3dx-gateway-helper.socket 3dx-gateway-helper@.service; do
  curl -sSLO https://raw.githubusercontent.com/Solfins-dev/3dx-gateway-updates/main/scripts/host/$f
done
# Run the installer (creates systemd units, writes /usr/local/bin/3dx-gateway-helper.sh).
# COMPOSE_DIR + COMPOSE_FILES override the helper defaults — if you layer
# multiple compose files at runtime (e.g. prod + a TLS overlay), pass them
# here too so the helper uses the same overlay set when applying updates:
#   sudo COMPOSE_DIR="$PWD" \
#        COMPOSE_FILES="docker-compose.prod.yml docker-compose.helper.yml" \
#        bash install-helper.sh
# Vanilla customers can omit COMPOSE_FILES (defaults to docker-compose.prod.yml).
sudo COMPOSE_DIR="$PWD" bash install-helper.sh
# Layer the overlay so the gateway container can reach the socket
curl -sSLO https://raw.githubusercontent.com/Solfins-dev/3dx-gateway-updates/main/docker-compose.helper.yml
docker compose -f docker-compose.prod.yml -f docker-compose.helper.yml up -d
```

To remove it later: `sudo bash uninstall-helper.sh` and drop the
`-f docker-compose.helper.yml` from your up command.

**Security note (Linux).** The helper listens on a Unix socket at
`/run/3dx-gateway-helper.sock`. Default mode is `0666` — any process on
the host (or any container with the same bind-mount) can trigger an
update. The helper can only run `docker compose pull && up -d` against
your canonical compose file; it cannot execute arbitrary commands. If
your threat model needs tighter restriction, edit the SocketMode in
`/etc/systemd/system/3dx-gateway-helper.socket` after install.

#### Windows: helper as a Scheduled Task

`install.ps1` offers the helper as an optional step (or skip with
`-Helper off`). When accepted it:

- Fetches `scripts/host/{3dx-gateway-helper,install-helper,uninstall-helper}.ps1`
  from the public repo.
- Generates a 32-byte random token, stores it in
  `%PROGRAMDATA%\3dx-gateway\helper-token.txt` (ACL Admins+SYSTEM only).
- Copies the helper script to `%PROGRAMDATA%\3dx-gateway\helper.ps1`.
- Registers a Scheduled Task `3dx-gateway-helper` (AtStartup, runs as
  SYSTEM, RunLevel=Highest, auto-restart x3 with 1 min interval).
- Starts the task immediately + smoke-tests PING via 127.0.0.1:5171.
- Writes `HELPER_TOKEN=<value>` to the install dir's `.env`.
- Layers `docker-compose.helper.windows.yml` onto the compose flags,
  which gives the container `host.docker.internal:host-gateway` plus
  the `Updates__HelperEndpoint=tcp://host.docker.internal:5171` +
  `Updates__HelperToken=${HELPER_TOKEN}` env vars.

To remove it later: `pwsh scripts\host\uninstall-helper.ps1` (admin).
Add `-PurgeState` to also wipe `%PROGRAMDATA%\3dx-gateway\` (token +
status file + last-apply log).

**Security note (Windows).** Helper listens on `0.0.0.0:5171` (host
bridge binding is required so the container can reach it via
`host.docker.internal`). Auth is the bearer token shared via `.env`;
without it the helper returns `{"error":"unauthorized"}` on every
command. The token file ACL excludes the `Users` group so non-admin
processes on the same host can't read it. If your host is on a network
where you don't trust other devices, add a Windows Firewall rule that
restricts inbound TCP 5171 to the Docker subnet (typically `172.17.0.0/16`
on Docker Desktop).

### 4.2 Apply a CadBridge update (each workstation)

From CadBridge 1.8.22+ the tray drives the whole flow in one click:

1. Right-click the tray → click **⬆ Apply update — vX.Y.Z** (amber).
2. Accept the Windows admin prompt.
3. The install console opens briefly, replaces the agent in-place, and
   the new tray icon appears within ~30 seconds. The previous version
   is automatically snapshotted under
   `%LOCALAPPDATA%\CadBridge\rollback\` so a **↓ Rollback to v{prev}**
   row appears on the next right-click if anything goes wrong.

**Before clicking Apply update — close SolidWorks and CATIA** if a
heavy CAD session is open. The Setup script warns and pauses 5 seconds
when it detects either app running, but a saved-and-closed CAD app
removes the only realistic failure mode (file locks on the bundled
SolidWorks / CATIA interop DLLs during the file replacement step).
Light/idle sessions usually install fine — the warning is a
"if it fails, this is why" hint.

For workstations still on 1.8.21 or earlier, do one final manual
install:

1. Right-click tray → **Exit**.
2. Browse to `https://<your-gateway-url>/api/downloads/CadBridge-Setup.zip`
   → save → extract → right-click `Setup.bat` → **Run as administrator**.

From 1.8.22 onwards, the one-click flow handles every subsequent update.

Each workstation user does this on their own schedule.

---

## Privacy & telemetry

The gateway sends an **anonymous hourly ping** to Solfins so we know which
customers are on which version when you call us for support. The payload is:

- Backend version (e.g. `1.0.2`) and last-known CadBridge version
- An opaque SHA256 of your license ID (we can correlate pings to the
  customer name in our license registry but the wire payload reveals nothing
  on its own)
- A random per-install GUID generated the first time the gateway starts
- A timestamp

There is **no BOM data, no Pantheon credentials, no 3DX session content, no
user activity** — only the four fields above. The endpoint is a Cloudflare
Worker hosted on `*.solfins.com`.

Telemetry is **on by default**. To turn it off:

1. Open `https://<your-gateway-url>/` and log in.
2. Click **Settings**.
3. Find the **Telemetry** card under "Licensing & features".
4. Toggle off. The change persists across restarts.

Turning telemetry off doesn't disable any product feature. The only thing
you lose is our ability to proactively reach out when we ship a security
fix for the version you're on.

---

## Troubleshooting

### Gateway doesn't start

```sh
docker compose -f docker-compose.prod.yml logs --tail 50 app
```

The most common first-start error is a missing `license.lic` — the
container exits with `License file not found at /app/license.lic`. Make
sure the path on the host is right next to `docker-compose.prod.yml`.

### Backend says "license expired"

`curl http://localhost:5000/api/license/status` returns the dates Solfins
licensed. If you've renewed but the file is the old one, replace
`license.lic` and restart: `docker compose restart app`.

### Workstation can't reach the gateway

- DNS / hostname: from a workstation `ping gateway.yourcompany.local`.
  If it fails, fix DNS or use an IP.
- Firewall: gateway host needs inbound TCP 5000 (or 443 if you're
  reverse-proxying) from each workstation subnet.
- Cert trust: open `https://<gateway>/` in the workstation's browser. If
  you see "Your connection is not private", `Setup.bat` didn't install
  the CA cert successfully. Re-run `Setup.bat` as admin and watch the
  output.

### Setup.bat "Unknown publisher" or "Run scripts from Internet?" prompt

If you see either prompt **after** the "Removing internet-zone markers"
line, `Unblock-File` failed (rare — usually means an antivirus held the
file open). Manual fallback:

```powershell
# Run in elevated PowerShell, from the extracted folder
Get-ChildItem -Recurse | Unblock-File
.\Setup.bat
```

### Generating CAD outputs fails with "CadBridge agent not reachable"

The tray agent listens on `localhost:5170`. If the green icon isn't
showing, the agent crashed — check `%APPDATA%\CadBridge\logs\` for the
last 50 lines of `tray.log` and contact support.

---

## Getting help

- **Logs to gather first** when filing a support ticket:
  - Backend: `docker logs --tail 200 3dx-gateway-app`
  - Workstation: `%APPDATA%\CadBridge\logs\tray.log` + `agent.log`
- **Versions**: web app footer + `https://<gateway>/api/version`
- **Contact**: support@solfins.com

For more detailed configuration guides for specific integrations
(Pantheon ERP, DelmiaWorks ERP, CATIA V5 / V6, SolidWorks Connector vs.
Connected), contact Solfins support — we deliver a per-integration
handbook on request.
