#!/bin/sh
set -eu

command -v az >/dev/null 2>&1 || { printf 'az CLI is required.\n' >&2; exit 1; }
command -v azd >/dev/null 2>&1 || { printf 'azd is required.\n' >&2; exit 1; }
command -v duckdb >/dev/null 2>&1 || { printf 'duckdb CLI is required.\n' >&2; exit 1; }

umask 077
QUACK_URI="$(azd env get-value QUACK_URI)"
KEY_VAULT_NAME="$(azd env get-value KEY_VAULT_NAME)"
QUACK_TOKEN="$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name quack-token --query value -o tsv)"
local_version="$(duckdb -csv -c 'SELECT version();' | tail -n 1)"
if [ "$local_version" != "v1.5.3" ]; then
  printf 'Local duckdb CLI must be v1.5.3 for Quack catalog validation. Found %s.\n' "$local_version" >&2
  exit 1
fi

tmp_sql="$(mktemp "${TMPDIR:-/tmp}/azquack-client.XXXXXX.sql")"
trap 'rm -f "$tmp_sql"' EXIT

cat > "$tmp_sql" <<SQL
.bail on
INSTALL quack;
LOAD quack;

CREATE OR REPLACE SECRET azquack_remote (
    TYPE quack,
    SCOPE '$QUACK_URI',
    TOKEN '$QUACK_TOKEN'
);

ATTACH '$QUACK_URI' AS remote (TYPE quack);

FROM remote.query('FROM whoami()');
FROM remote.query('INSERT INTO azquack.demo.events SELECT 2, ''local-client-smoke'', now() WHERE NOT EXISTS (SELECT 1 FROM azquack.demo.events WHERE event_id = 2)');
FROM remote.query('SELECT * FROM azquack.demo.events ORDER BY event_id');
SQL

duckdb < "$tmp_sql"
