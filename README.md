# OneTeam

Self-hosted, modern-protocol workplace identity for small teams — the foundation of the OneTeam
stack. One command on a fresh Ubuntu box brings up a hardened identity core: **Zitadel**
(OIDC/SAML, passkeys, MFA) behind **Caddy** (automatic HTTPS), on **Postgres**.

> **Early preview.** This repo is the identity core — the SSO hub the rest of OneTeam builds on.
> Mail, files, and the admin portal are separate components on the roadmap.

## Quickstart

On a **fresh Ubuntu 24.04** server, with a domain pointed at it and your SSH key already installed
(the bootstrap disables SSH password login):

```sh
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/kidGodzilla/oneteam-public.git oneteam && cd oneteam

# set your domain (edit ZITADEL_DOMAIN):
nano .env.example

sudo ./bootstrap.sh      # hardens the host + installs Docker  (reboot recommended after)
./install.sh             # generates secrets + brings the stack up
```

Then watch it come up and grab the initial admin login:

```sh
docker compose ps
docker compose logs zitadel | grep -i -A2 admin
```

Open `https://<your-domain>` and sign in.

## What you get

| Component | Role |
|---|---|
| **Zitadel** + Login V2 | Identity provider — OIDC + SAML, passkeys/WebAuthn, MFA, an SSO hub for your apps |
| **Postgres** | The one database on the box |
| **Caddy** | Reverse proxy with automatic HTTPS (Let's Encrypt) |
| **Hardened host** | UFW firewall, fail2ban, unattended security updates, Docker log rotation, persistent journald, swap, time sync |

Two scripts, two jobs:

- **`bootstrap.sh`** — takes a raw Ubuntu box to a hardened, Docker-ready host. Run once, as root.
  Idempotent. **It disables SSH password authentication** — make sure your key is on the box first
  (it refuses to run otherwise).
- **`install.sh`** — generates secrets into `.env` (never committed), then brings the stack up.
  Re-running converges rather than breaking.

## Requirements

- Ubuntu 24.04 (a fresh VPS or dedicated box), root/sudo.
- A domain (or subdomain) with an A record pointing at the box — needed for the TLS certificate.
- Ports **80** and **443** reachable from the internet.
- ~2 GB RAM to start; more headroom is nice but not required at small scale.

## Configuration

All configuration lives in `.env` (created from `.env.example` on first run). The essentials:

- `ZITADEL_DOMAIN` — the public hostname (must resolve to the box).
- `ZITADEL_VERSION`, `POSTGRES_IMAGE` — pinned versions.
- Secrets (`ZITADEL_MASTERKEY`, DB passwords) — auto-generated once; the masterkey **cannot change
  after first init**.

For local testing without a public domain, uncomment `tls internal` in the `Caddyfile` and use a
hostname that resolves to the box (e.g. an `/etc/hosts` entry).

## Security

- Secrets are generated **on the box**, on first run, and are gitignored — nothing sensitive ships
  in this repo.
- `bootstrap.sh` hardens SSH (key-only), enables a firewall (SSH/HTTP/HTTPS only), fail2ban, and
  unattended security upgrades.
- Only ports 80/443 are exposed; everything else stays on an internal Docker network.
- Backups are your responsibility — RAID/single-box redundancy is **not** backup. Point Postgres at
  offsite PITR (e.g. pgBackRest → S3) and rehearse a restore before trusting it with real data.

## Roadmap

This is the identity foundation. Coming as separate components:

- **Mail + calendar + contacts** (JMAP/CalDAV, modern single-binary server)
- **Files** (S3-backed, first-party UI)
- **Admin portal** — opinionated user/group management + app lifecycle on top of Zitadel

## Status &amp; license

Early preview — expect breaking changes; pin versions and read release notes before upgrading.
License: TBD (currently all rights reserved) — will be set before a tagged release.
