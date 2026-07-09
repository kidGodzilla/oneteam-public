# OneTeam

Self-hosted, modern-protocol workplace identity for small teams — the foundation of the OneTeam
stack. One command on a fresh Ubuntu box brings up a hardened identity core: **Zitadel**
(OIDC/SAML, passkeys, MFA) behind **Caddy** (automatic HTTPS), on **Postgres**.

> **Early preview.** This repo is the identity core — the SSO hub the rest of OneTeam builds on.
> Mail, files, and the admin portal are separate components on the roadmap.

## DNS (do this first)

The identity core needs exactly **one DNS record** — a subdomain pointing at your box:

| Type | Name | Value | Proxy |
|---|---|---|---|
| `A` | `id` (→ `id.yourcompany.com`) | your box's public IPv4 | **DNS only (grey cloud)** |

On **Cloudflare**: DNS → Records → Add record → type `A`, name `id`, IPv4 = the box IP, and set the
proxy toggle to **DNS only (grey cloud), _not_ Proxied** — proxying breaks the TLS/gRPC path (and
can't carry mail later).

It **must resolve before you run `install.sh`** — Caddy validates the domain live to obtain a
Let's Encrypt certificate. Confirm it:

```sh
dig +short id.yourcompany.com     # should print your box's public IP
```

**Resolves to a parking page instead of your box?** (a `CNAME` to something like `*.porkbun.com`,
`sedoparking.com`, `parkingcrew.net`…) — when you moved the domain to a new DNS host it imported the
**registrar's parking / URL-forwarding records**. In your DNS dashboard, delete any `CNAME` pointing
at the registrar's forwarding service — **including a wildcard `*`** — then (re-)add the `id` `A`
record above. Those records usually have a short TTL (~60s), so it clears within minutes.

Also make sure **ports 80 and 443 are open** to the internet (Caddy needs 80 for the certificate
challenge and 443 to serve). `bootstrap.sh` doesn't need DNS — only `install.sh` does.

> Email DNS (MX, SPF, DKIM, DMARC, and reverse DNS — the last set at your VPS provider, not your DNS
> host) is a separate, larger setup that comes with the mail component. None of it is needed for the
> identity core.

## Quickstart

On a **fresh Ubuntu 24.04** server, with a domain pointed at it and your SSH key already installed
(the bootstrap disables SSH password login):

```sh
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/kidGodzilla/oneteam-public.git oneteam && cd oneteam

# set your domain — edit .env (gitignored), NOT the tracked .env.example
# (editing the tracked file makes later `git pull`s conflict):
cp .env.example .env && nano .env        # set ZITADEL_DOMAIN

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

## Configuration — setting up `.env`

`install.sh` copies `.env.example` → `.env` on first run and fills every blank secret with a random
value. You only need to set **one thing by hand before running it: `ZITADEL_DOMAIN`**. Here's what
each group means and the constraints that bite if you get them wrong.

### 1. You set this (before `install.sh`)

- **`ZITADEL_DOMAIN`** — the public hostname your identity provider answers on.
  - Use a **subdomain** (e.g. `id.yourcompany.com`), **not the bare apex** — keep the apex free for
    a landing page and (later) your email domain.
  - It **must resolve to this box** (an A record → the server IP) **before** you run `install.sh` —
    Caddy validates the domain live to issue the TLS certificate. On Cloudflare, set the record to
    **DNS-only (grey cloud), not proxied** (proxying breaks the cert/gRPC path and can't carry SMTP).
  - ⚠️ **Frozen at first init.** Zitadel bakes this into issuer URLs, cookies, and tokens — changing
    it later means wiping and reinitializing Zitadel. Pick the one you'll keep and double-check it
    before the first `install.sh`.
  - Set it in **`.env`** (gitignored), *not* the tracked `.env.example` — editing the tracked file
    makes later `git pull`s conflict. Use `cp .env.example .env` then edit `.env`.

### 2. Auto-generated — leave blank, never hand-edit or commit

- **`ZITADEL_MASTERKEY`, `POSTGRES_PASSWORD`, `ZITADEL_PG_PASSWORD`, `PORTAL_PG_PASSWORD`** —
  `install.sh` fills these once with random values and leaves any existing value untouched. Don't
  set them by hand. `.env` is gitignored — keep it that way.
  - ⚠️ **`ZITADEL_MASTERKEY` is also frozen** — it's exactly 32 chars and encrypts data at rest.
    Change or lose it and the encrypted data is unrecoverable. Let `install.sh` generate it, then
    **back up your `.env`** somewhere safe.

### 3. Rarely changed

- **`ZITADEL_VERSION`, `POSTGRES_IMAGE`** — pinned image versions. Bump deliberately and read the
  release notes first (Zitadel runs DB migrations on upgrade).
- **`ZITADEL_EXTERNALPORT` / `ZITADEL_EXTERNALSECURE`** — `443` / `true` for the standard
  Caddy-terminates-TLS setup. Leave as-is unless you specifically need otherwise.

### Local testing (no public domain)

Uncomment `tls internal` in the `Caddyfile` (self-signed cert), add an `/etc/hosts` entry like
`127.0.0.1  id.oneteam.test`, and set `ZITADEL_DOMAIN=id.oneteam.test`.

## Security

- Secrets are generated **on the box**, on first run, and are gitignored — nothing sensitive ships
  in this repo.
- `bootstrap.sh` hardens SSH (key-only), enables a firewall (SSH/HTTP/HTTPS only), fail2ban, and
  unattended security upgrades.
- Only ports 80/443 are exposed; everything else stays on an internal Docker network.
- Backups are your responsibility — RAID/single-box redundancy is **not** backup. Point Postgres at
  offsite PITR (e.g. pgBackRest → S3) and rehearse a restore before trusting it with real data.

## Troubleshooting

**Reset / re-initialize (start over on a test box).** `ZITADEL_DOMAIN` and the masterkey are frozen
at first init, so to change them — or to recover from a half-finished init — wipe Zitadel's data and
re-run. This is a full identity reset (fresh initial admin); it keeps your TLS cert and `.env`:

```sh
docker compose down
docker volume rm oneteam_postgres-data oneteam_zitadel-bootstrap   # drops the DB + PAT
docker compose up -d                                              # keeps caddy-data (cert) + .env
```

**Initial admin login.** After a fresh init, sign in at `https://<domain>/ui/console` as
`zitadel-admin@zitadel.<domain>` with password `Password1!` — then **change it immediately** (known
default). If that doesn't work: `docker compose logs zitadel | grep -i -A2 admin`.

**`zitadel-login` unhealthy / 502 on `/ui/v2/login`.** The Login V2 container waits for the
`login-client.pat` that Zitadel writes to the shared `zitadel-bootstrap` volume on first init. Two
things make that work and are already baked into `docker-compose.yml`: the `bootstrap-perms` init
(makes the fresh, root-owned volume writable) and the `ZITADEL_FIRSTINSTANCE_ORG_LOGINCLIENT_*`
settings (create the machine user + PAT). If you hit this after editing the compose, check
`docker compose logs zitadel` for `permission denied` on the volume or a `03_default_instance`
failure, then reset (above).

**Domain resolves to a parking page.** See the note under [DNS](#dns-do-this-first) — delete the
registrar's imported parking `CNAME`.

## Roadmap

This is the identity foundation. Coming as separate components:

- **Mail + calendar + contacts** (JMAP/CalDAV, modern single-binary server)
- **Files** (S3-backed, first-party UI)
- **Admin portal** — opinionated user/group management + app lifecycle on top of Zitadel

## Status &amp; license

Early preview — expect breaking changes; pin versions and read release notes before upgrading.
License: TBD (currently all rights reserved) — will be set before a tagged release.
