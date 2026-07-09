#!/usr/bin/env bash
# OneTeam installer.
#
# Wrapped in main() so a partially-downloaded copy can't execute a truncated
# command (the classic curl|bash hazard). Idempotent: re-running never clobbers
# existing secrets, and `docker compose up` converges rather than rebuilds.
set -euo pipefail

main() {
	cd "$(dirname "$(readlink -f "$0")")"

	command -v docker >/dev/null 2>&1 || { echo "docker is required"; exit 1; }
	docker compose version >/dev/null 2>&1 || { echo "docker compose v2 is required"; exit 1; }

	[ -f .env ] || cp .env.example .env

	# Fill any blank secret exactly once. Existing values are left untouched.
	fill_secret ZITADEL_MASTERKEY   "$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
	fill_secret POSTGRES_PASSWORD   "$(openssl rand -hex 24)"
	fill_secret ZITADEL_PG_PASSWORD "$(openssl rand -hex 24)"
	fill_secret PORTAL_PG_PASSWORD  "$(openssl rand -hex 24)"

	if grep -q '^ZITADEL_DOMAIN=id.example.com$' .env; then
		echo "!! ZITADEL_DOMAIN is still id.example.com — edit .env and set a domain"
		echo "!! that resolves to this box, then re-run. (Or set 'tls internal' in"
		echo "!! the Caddyfile for local testing.)"
	fi

	echo "Starting core stack..."
	docker compose up -d

	echo
	echo "OneTeam is starting. Watch health with:  docker compose ps"
	echo "Once healthy, open:  https://$(grep '^ZITADEL_DOMAIN=' .env | cut -d= -f2)"
	echo "First-run admin credentials are printed in Zitadel's init logs:"
	echo "  docker compose logs zitadel | grep -i -A2 'admin'"
}

# fill_secret KEY VALUE — set KEY=VALUE in .env only if KEY is currently blank.
fill_secret() {
	local key="$1" value="$2"
	if grep -q "^${key}=$" .env; then
		# portable in-place edit (BSD + GNU sed)
		local tmp; tmp="$(mktemp)"
		sed "s|^${key}=$|${key}=${value}|" .env >"$tmp" && mv "$tmp" .env
		echo "generated ${key}"
	fi
}

main "$@"
