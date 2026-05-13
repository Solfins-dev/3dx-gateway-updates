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

### 1.1 Create a working directory

```sh
mkdir -p ~/3dx-gateway
cd ~/3dx-gateway
```

### 1.2 Drop in `docker-compose.prod.yml`

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

> A canonical copy is in the source repo at
> [`docker-compose.prod.yml`](https://github.com/Solfins-dev/3dx-gateway-updates/blob/main/docker-compose.prod.yml).

### 1.3 Create `.env`

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

### 1.4 Drop in your license file

```sh
# Copy the license.lic file you received from Solfins into ~/3dx-gateway/
cp /path/to/license.lic ./license.lic
chmod 644 license.lic
```

The container mounts this file read-only at `/app/license.lic`.

### 1.5 Pull and start

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

### 1.6 (Recommended) TLS via reverse proxy

For LAN access from workstations you'll want HTTPS. Two common patterns:

- **You already run a reverse proxy** (Nginx, Traefik, your own Caddy):
  point it at `http://localhost:5000` and terminate TLS there.
- **You don't**: drop a Caddy container in front. Caddy can issue a local CA
  certificate automatically with `tls internal`. Each workstation's
  `Setup.bat` then fetches and trusts that CA. Contact Solfins support for
  a ready-to-use Caddy compose overlay sized for your network.

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

On the gateway host, ~30 seconds of downtime:

```sh
cd ~/3dx-gateway
docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d
```

The container restarts on the new image; PostgreSQL stays up; sessions
need to log in again once.

### 4.2 Apply a CadBridge update (each workstation)

Same flow as the first install (step 3):

1. Right-click tray → **Exit**.
2. Click "Download" from the Settings → Updates card (or the tray pill)
   → re-download `CadBridge-Setup.zip`.
3. Extract → run `Setup.bat`.

Each workstation user does this on their own schedule.

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
