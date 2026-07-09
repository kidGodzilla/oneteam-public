#!/bin/bash
# Runs once on first Postgres init. Creates a dedicated role + database per core
# service — the "core = one instance, separate databases" model. Module Postgres
# instances are provisioned separately by the portal (Dokku-style), not here.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-SQL
	CREATE ROLE zitadel WITH LOGIN CREATEDB PASSWORD '${ZITADEL_PG_PASSWORD}';
	CREATE DATABASE zitadel OWNER zitadel;

	CREATE ROLE portal WITH LOGIN PASSWORD '${PORTAL_PG_PASSWORD}';
	CREATE DATABASE portal OWNER portal;
SQL
