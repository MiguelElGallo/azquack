#!/bin/sh
set -eu

command -v az >/dev/null 2>&1 || { printf 'az CLI is required.\n' >&2; exit 1; }
command -v azd >/dev/null 2>&1 || { printf 'azd is required.\n' >&2; exit 1; }
command -v duckdb >/dev/null 2>&1 || { printf 'duckdb CLI is required.\n' >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { printf 'curl is required.\n' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf 'python3 is required for bounded log collection.\n' >&2; exit 1; }

wait_for_ready() {
  url="$1"
  timeout_seconds="$2"
  start_time="$(date +%s)"
  last_body=""
  while :; do
    body="$(curl --silent --show-error "$url/readyz" 2>&1 || true)"
    if printf '%s' "$body" | grep '"ready": true' >/dev/null; then
      return 0
    fi
    now="$(date +%s)"
    if [ "$((now - start_time))" -ge "$timeout_seconds" ]; then
      printf 'Timed out waiting for /readyz. Last response:\n%s\n' "$body" >&2
      return 1
    fi
    sleep 5
  done
}

local_version="$(duckdb -csv -c 'SELECT version();' | tail -n 1)"
if [ "$local_version" != "v1.5.2" ]; then
  printf 'Local duckdb CLI must be v1.5.2 for Quack beta validation. Found %s.\n' "$local_version" >&2
  exit 1
fi

umask 077
QUACK_URI="$(azd env get-value QUACK_URI)"
QUACK_HTTP_URL="$(azd env get-value QUACK_HTTP_URL)"
KEY_VAULT_NAME="$(azd env get-value KEY_VAULT_NAME)"
CONTAINER_APP_NAME="$(azd env get-value CONTAINER_APP_NAME)"
RESOURCE_GROUP="$(azd env get-value AZURE_RESOURCE_GROUP)"
STORAGE_ACCOUNT_NAME="$(azd env get-value STORAGE_ACCOUNT_NAME)"
QUACK_TOKEN="$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name quack-token --query value -o tsv)"
DUCKLAKE_CATALOG_PASSWORD="$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name ducklake-catalog-password --query value -o tsv 2>/dev/null || true)"
POSTGRES_ADMIN_PASSWORD="$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name postgres-admin-password --query value -o tsv 2>/dev/null || true)"

printf 'Checking health endpoint...\n'
curl --fail --silent --show-error "$QUACK_HTTP_URL/healthz" >/dev/null
wait_for_ready "$QUACK_HTTP_URL" 300

printf 'Counting existing DuckLake data blobs...\n'
before_blob_count="$(az storage blob list \
  --auth-mode login \
  --account-name "$STORAGE_ACCOUNT_NAME" \
  --container-name lakehouse \
  --prefix data/ \
  --query 'length(@)' \
  -o tsv)"

good_sql="$(mktemp "${TMPDIR:-/tmp}/azquack-good.XXXXXX.sql")"
bad_sql="$(mktemp "${TMPDIR:-/tmp}/azquack-bad.XXXXXX.sql")"
post_restart_sql="$(mktemp "${TMPDIR:-/tmp}/azquack-post-restart.XXXXXX.sql")"
file_list="$(mktemp "${TMPDIR:-/tmp}/azquack-files.XXXXXX.csv")"
logs_file="$(mktemp "${TMPDIR:-/tmp}/azquack-logs.XXXXXX.txt")"
trap 'rm -f "$good_sql" "$bad_sql" "$post_restart_sql" "$file_list" "$logs_file"' EXIT
marker_id="$(date +%s)"
marker_name="validate-${marker_id}"
validation_table="validation_${marker_id}"

cat > "$good_sql" <<SQL
.bail on
FORCE INSTALL quack FROM core_nightly;
LOAD quack;
ATTACH '$QUACK_URI' AS remote (TYPE quack, TOKEN '$QUACK_TOKEN');
FROM remote.query('FROM whoami()');
SELECT version() AS local_duckdb_version;
SELECT * FROM remote.query('SELECT version() AS remote_duckdb_version');
FROM remote.query('CREATE SCHEMA IF NOT EXISTS azquack.validation');
FROM remote.query('DROP TABLE IF EXISTS azquack.validation.${validation_table}');
FROM remote.query('CREATE TABLE azquack.validation.${validation_table} AS
SELECT
    $marker_id::BIGINT * 1000000 + i::BIGINT AS event_id,
    ''quack-validation-'' || i::VARCHAR AS event_name,
    now() AS created_at
FROM range(1, 1001) AS t(i)');
FROM remote.query('INSERT INTO azquack.demo.events SELECT $marker_id, ''$marker_name'', now()');
SELECT * FROM remote.query('SELECT count(*) AS event_count FROM azquack.demo.events');
SELECT * FROM remote.query('SELECT count(*) AS marker_count FROM azquack.demo.events WHERE event_id = $marker_id AND event_name = ''$marker_name''');
SELECT * FROM remote.query('SELECT count(*) AS validation_row_count FROM azquack.validation.${validation_table}');
SELECT count(*) AS validation_file_count
FROM remote.query('FROM ducklake_list_files(''azquack'', ''${validation_table}'', schema => ''validation'')');
COPY (
  SELECT data_file
  FROM remote.query('FROM ducklake_list_files(''azquack'', ''${validation_table}'', schema => ''validation'')')
) TO '$file_list' (HEADER false);
SQL

cat > "$bad_sql" <<SQL
.bail on
FORCE INSTALL quack FROM core_nightly;
LOAD quack;
ATTACH '$QUACK_URI' AS remote (TYPE quack, TOKEN 'wrong-token');
FROM remote.query('SELECT 1');
SQL

printf 'Checking authenticated Quack attach and DuckLake query...\n'
duckdb < "$good_sql"

printf 'Checking wrong-token rejection...\n'
if duckdb < "$bad_sql" >/tmp/azquack-wrong-token.log 2>&1; then
  printf 'Wrong-token attach unexpectedly succeeded.\n' >&2
  cat /tmp/azquack-wrong-token.log >&2
  exit 1
fi

printf 'Scanning recent Container App logs for literal secret values...\n'
python3 - "$CONTAINER_APP_NAME" "$RESOURCE_GROUP" "$logs_file" <<'PY'
import subprocess
import sys

container_app, resource_group, logs_file = sys.argv[1:]
cmd = [
    "az",
    "containerapp",
    "logs",
    "show",
    "--name",
    container_app,
    "--resource-group",
    resource_group,
    "--type",
    "console",
    "--tail",
    "200",
    "--follow",
    "false",
]
try:
    completed = subprocess.run(
        cmd,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=60,
    )
except subprocess.TimeoutExpired as exc:
    output = exc.stdout or ""
    with open(logs_file, "w", encoding="utf-8") as handle:
        handle.write(output if isinstance(output, str) else output.decode())
    print("Timed out retrieving Container App logs.", file=sys.stderr)
    raise SystemExit(1)

with open(logs_file, "w", encoding="utf-8") as handle:
    handle.write(completed.stdout)
if completed.returncode != 0:
    print(completed.stdout, file=sys.stderr)
    raise SystemExit(completed.returncode)
PY
logs="$(cat "$logs_file")"

if printf '%s' "$logs" | grep -F "$QUACK_TOKEN" >/dev/null; then
  printf 'Quack token appeared in logs.\n' >&2
  exit 1
fi
if [ -n "$DUCKLAKE_CATALOG_PASSWORD" ] && printf '%s' "$logs" | grep -F "$DUCKLAKE_CATALOG_PASSWORD" >/dev/null; then
  printf 'DuckLake catalog password appeared in logs.\n' >&2
  exit 1
fi
if [ -z "$DUCKLAKE_CATALOG_PASSWORD" ]; then
  printf 'DuckLake catalog password was not readable by this operator; skipped literal scan for that value.\n' >&2
fi
if [ -n "$POSTGRES_ADMIN_PASSWORD" ] && printf '%s' "$logs" | grep -F "$POSTGRES_ADMIN_PASSWORD" >/dev/null; then
  printf 'PostgreSQL admin password appeared in logs.\n' >&2
  exit 1
fi
if [ -z "$POSTGRES_ADMIN_PASSWORD" ]; then
  printf 'PostgreSQL admin password was not readable by this operator; skipped literal scan for that value.\n' >&2
fi

printf 'Checking Blob Storage contains DuckLake data files...\n'
blob_count="$(az storage blob list \
  --auth-mode login \
  --account-name "$STORAGE_ACCOUNT_NAME" \
  --container-name lakehouse \
  --prefix data/ \
  --query 'length(@)' \
  -o tsv)"
if [ "${blob_count:-0}" -lt 1 ]; then
  printf 'No DuckLake data files found under az://lakehouse/data/.\n' >&2
  exit 1
fi
if [ "$blob_count" -lt "$before_blob_count" ]; then
  printf 'DuckLake blob count decreased unexpectedly. Before %s, after %s.\n' "$before_blob_count" "$blob_count" >&2
  exit 1
fi
printf 'DuckLake blob count before write: %s, after write: %s\n' "$before_blob_count" "$blob_count"

printf 'Checking fresh DuckLake file metadata maps to Azure Blob objects...\n'
validation_file_count=0
while IFS= read -r data_file; do
  data_file="$(printf '%s' "$data_file" | sed 's/^"//;s/"$//')"
  [ -n "$data_file" ] || continue
  case "$data_file" in
    az://lakehouse/*)
      blob_name="${data_file#az://lakehouse/}"
      ;;
    azure://lakehouse/*)
      blob_name="${data_file#azure://lakehouse/}"
      ;;
    https://*.blob.core.windows.net/lakehouse/*)
      blob_name="${data_file#*blob.core.windows.net/lakehouse/}"
      ;;
    data/*)
      blob_name="$data_file"
      ;;
    *)
      blob_name="data/$data_file"
      ;;
  esac
  exists="$(az storage blob exists \
    --auth-mode login \
    --account-name "$STORAGE_ACCOUNT_NAME" \
    --container-name lakehouse \
    --name "$blob_name" \
    --query exists \
    -o tsv)"
  if [ "$exists" != "true" ]; then
    printf 'DuckLake metadata references missing blob %s from %s.\n' "$blob_name" "$data_file" >&2
    exit 1
  fi
  validation_file_count=$((validation_file_count + 1))
done < "$file_list"
if [ "$validation_file_count" -lt 1 ]; then
  printf 'DuckLake did not report any files for %s.\n' "$validation_table" >&2
  exit 1
fi

printf 'Restarting active Container App revision and verifying rows persist...\n'
revision="$(az containerapp revision list \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "[?properties.active].name | [0]" \
  -o tsv)"
az containerapp revision restart \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --revision "$revision" >/dev/null
wait_for_ready "$QUACK_HTTP_URL" 300

cat > "$post_restart_sql" <<SQL
.bail on
FORCE INSTALL quack FROM core_nightly;
LOAD quack;
ATTACH '$QUACK_URI' AS remote (TYPE quack, TOKEN '$QUACK_TOKEN');
SELECT *
FROM remote.query('
    SELECT
        (SELECT count(*) FROM azquack.demo.events WHERE event_id = $marker_id AND event_name = ''$marker_name'') AS marker_count,
        (SELECT count(*) FROM azquack.validation.${validation_table}) AS validation_row_count,
        (SELECT count(*) FROM ducklake_list_files(''azquack'', ''${validation_table}'', schema => ''validation'')) AS validation_file_count
');
SQL

post_restart_counts="$(duckdb -csv < "$post_restart_sql" | tail -n 1)"
IFS=, read -r post_marker_count post_validation_rows post_validation_files <<EOF
$post_restart_counts
EOF
if [ "$post_marker_count" != "1" ]; then
  printf 'Validation marker did not persist across restart. Expected 1, got %s.\n' "$post_marker_count" >&2
  exit 1
fi
if [ "$post_validation_rows" != "1000" ]; then
  printf 'Validation table did not persist across restart. Expected 1000 rows, got %s.\n' "$post_validation_rows" >&2
  exit 1
fi
if [ "${post_validation_files:-0}" = "0" ]; then
  printf 'Validation DuckLake file metadata did not persist across restart.\n' >&2
  exit 1
fi

printf 'Deployment validation passed.\n'
