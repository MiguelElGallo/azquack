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

restart_active_revision() {
  app_name="$1"
  resource_group="$2"
  revision="$(az containerapp revision list \
    --name "$app_name" \
    --resource-group "$resource_group" \
    --query "[?properties.active].name | [0]" \
    -o tsv)"
  az containerapp revision restart \
    --name "$app_name" \
    --resource-group "$resource_group" \
    --revision "$revision" >/dev/null
}

collect_logs() {
  app_name="$1"
  resource_group="$2"
  output_file="$3"
  python3 - "$app_name" "$resource_group" "$output_file" <<'PY'
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
}

local_version="$(duckdb -csv -c 'SELECT version();' | tail -n 1)"
if [ "$local_version" != "v1.5.3" ]; then
  printf 'Local duckdb CLI must be v1.5.3 for Quack catalog validation. Found %s.\n' "$local_version" >&2
  exit 1
fi

umask 077
QUACK_URI="$(azd env get-value QUACK_URI)"
QUACK_HTTP_URL="$(azd env get-value QUACK_HTTP_URL)"
KEY_VAULT_NAME="$(azd env get-value KEY_VAULT_NAME)"
QUERY_CONTAINER_APP_NAME="$(azd env get-value QUERY_CONTAINER_APP_NAME)"
CATALOG_CONTAINER_APP_NAME="$(azd env get-value CATALOG_CONTAINER_APP_NAME)"
CATALOG_CONTAINER_APP_FQDN="$(azd env get-value CATALOG_CONTAINER_APP_FQDN)"
RESOURCE_GROUP="$(azd env get-value AZURE_RESOURCE_GROUP)"
STORAGE_ACCOUNT_NAME="$(azd env get-value STORAGE_ACCOUNT_NAME)"
CATALOG_STORAGE_ACCOUNT_NAME="$(azd env get-value CATALOG_STORAGE_ACCOUNT_NAME)"
CATALOG_FILE_SHARE_NAME="$(azd env get-value CATALOG_FILE_SHARE_NAME)"
AZURE_CONTAINER_REGISTRY_ENDPOINT="$(azd env get-value AZURE_CONTAINER_REGISTRY_ENDPOINT)"
QUACK_TOKEN="$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name quack-token --query value -o tsv)"
CATALOG_QUACK_TOKEN="$(azd env get-value CATALOG_QUACK_TOKEN 2>/dev/null || az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name catalog-quack-token --query value -o tsv 2>/dev/null || true)"

printf 'Checking PostgreSQL is absent from this resource group...\n'
postgres_count="$(az resource list \
  --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.DBforPostgreSQL/flexibleServers" \
  --query 'length(@)' \
  -o tsv)"
if [ "$postgres_count" != "0" ]; then
  printf 'Expected no PostgreSQL Flexible Server resources, found %s.\n' "$postgres_count" >&2
  exit 1
fi

printf 'Checking catalog app is internal-only...\n'
catalog_external="$(az containerapp show \
  --name "$CATALOG_CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query 'properties.configuration.ingress.external' \
  -o tsv)"
if [ "$catalog_external" != "false" ]; then
  printf 'Catalog app ingress is not internal-only.\n' >&2
  exit 1
fi
if curl --fail --silent --show-error --max-time 10 "https://${CATALOG_CONTAINER_APP_FQDN}/healthz" >/tmp/azquack-catalog-public.log 2>&1; then
  printf 'Internal catalog app unexpectedly responded from the public internet.\n' >&2
  exit 1
fi

printf 'Checking both Container Apps run images from the deployed ACR...\n'
query_image="$(az containerapp show \
  --name "$QUERY_CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query 'properties.template.containers[0].image' \
  -o tsv)"
catalog_image="$(az containerapp show \
  --name "$CATALOG_CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query 'properties.template.containers[0].image' \
  -o tsv)"
for image in "$query_image" "$catalog_image"; do
  case "$image" in
    "$AZURE_CONTAINER_REGISTRY_ENDPOINT"/*) ;;
    *)
      printf 'Container App image is not from the deployed ACR: %s\n' "$image" >&2
      exit 1
      ;;
  esac
  case "$image" in
    *containerapps-helloworld*)
      printf 'Container App is still running the placeholder image: %s\n' "$image" >&2
      exit 1
      ;;
  esac
done

printf 'Checking public query health endpoint...\n'
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
concurrent_sql_a="$(mktemp "${TMPDIR:-/tmp}/azquack-concurrent-a.XXXXXX.sql")"
concurrent_sql_b="$(mktemp "${TMPDIR:-/tmp}/azquack-concurrent-b.XXXXXX.sql")"
concurrent_verify_sql="$(mktemp "${TMPDIR:-/tmp}/azquack-concurrent-verify.XXXXXX.sql")"
post_restart_sql="$(mktemp "${TMPDIR:-/tmp}/azquack-post-restart.XXXXXX.sql")"
file_list="$(mktemp "${TMPDIR:-/tmp}/azquack-files.XXXXXX.csv")"
query_logs_file="$(mktemp "${TMPDIR:-/tmp}/azquack-query-logs.XXXXXX.txt")"
catalog_logs_file="$(mktemp "${TMPDIR:-/tmp}/azquack-catalog-logs.XXXXXX.txt")"
trap 'rm -f "$good_sql" "$bad_sql" "$concurrent_sql_a" "$concurrent_sql_b" "$concurrent_verify_sql" "$post_restart_sql" "$file_list" "$query_logs_file" "$catalog_logs_file" /tmp/azquack-wrong-token.log /tmp/azquack-catalog-public.log' EXIT
marker_id="$(date +%s)"
marker_name="validate-${marker_id}"
validation_table="validation_${marker_id}"
tx_rollback_table="tx_rollback_${marker_id}"
tx_commit_table="tx_commit_${marker_id}"
concurrent_table_a="concurrent_a_${marker_id}"
concurrent_table_b="concurrent_b_${marker_id}"

cat > "$good_sql" <<SQL
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
SELECT CASE WHEN version() = 'v1.5.3' THEN 1 ELSE error('local DuckDB version mismatch') END AS local_version_ok;
SELECT * FROM remote.query('SELECT CASE WHEN version() = ''v1.5.3'' THEN 1 ELSE error(''remote DuckDB version mismatch'') END AS remote_version_ok');
FROM remote.query('CREATE SCHEMA IF NOT EXISTS azquack.validation');
FROM remote.query('DROP TABLE IF EXISTS azquack.validation.${validation_table}');
FROM remote.query('CREATE TABLE azquack.validation.${validation_table} AS
SELECT
    $marker_id::BIGINT * 1000000 + i::BIGINT AS event_id,
    ''quack-validation-'' || i::VARCHAR AS event_name,
    now() AS created_at
FROM range(1, 1001) AS t(i)');
FROM remote.query('INSERT INTO azquack.demo.events SELECT $marker_id, ''$marker_name'', now()');
FROM remote.query('BEGIN; CREATE TABLE azquack.validation.${tx_rollback_table} AS SELECT 1 AS id; ROLLBACK;');
SELECT * FROM remote.query('SELECT CASE WHEN count(*) = 0 THEN 1 ELSE error(''rollback table survived'') END AS rollback_ok FROM information_schema.tables WHERE table_catalog = ''azquack'' AND table_schema = ''validation'' AND table_name = ''${tx_rollback_table}''');
FROM remote.query('BEGIN; CREATE TABLE azquack.validation.${tx_commit_table} AS SELECT 1 AS id; COMMIT;');
SELECT * FROM remote.query('SELECT CASE WHEN (SELECT count(*) FROM azquack.validation.${tx_commit_table}) = 1 THEN 1 ELSE error(''commit table missing'') END AS commit_ok');
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
INSTALL quack;
LOAD quack;
ATTACH '$QUACK_URI' AS remote (TYPE quack, TOKEN 'wrong-token');
FROM remote.query('SELECT 1');
SQL

cat > "$concurrent_sql_a" <<SQL
.bail on
LOAD quack;
CREATE OR REPLACE SECRET azquack_remote (
    TYPE quack,
    SCOPE '$QUACK_URI',
    TOKEN '$QUACK_TOKEN'
);
ATTACH '$QUACK_URI' AS remote (TYPE quack);
FROM remote.query('CREATE TABLE azquack.validation.${concurrent_table_a} AS SELECT i::BIGINT AS id FROM range(1, 501) AS t(i)');
SQL

cat > "$concurrent_sql_b" <<SQL
.bail on
LOAD quack;
CREATE OR REPLACE SECRET azquack_remote (
    TYPE quack,
    SCOPE '$QUACK_URI',
    TOKEN '$QUACK_TOKEN'
);
ATTACH '$QUACK_URI' AS remote (TYPE quack);
FROM remote.query('CREATE TABLE azquack.validation.${concurrent_table_b} AS SELECT i::BIGINT AS id FROM range(1, 501) AS t(i)');
SQL

cat > "$concurrent_verify_sql" <<SQL
.bail on
LOAD quack;
CREATE OR REPLACE SECRET azquack_remote (
    TYPE quack,
    SCOPE '$QUACK_URI',
    TOKEN '$QUACK_TOKEN'
);
ATTACH '$QUACK_URI' AS remote (TYPE quack);
SELECT *
FROM remote.query('
    SELECT
        (SELECT count(*) FROM azquack.validation.${concurrent_table_a}) AS concurrent_a_count,
        (SELECT count(*) FROM azquack.validation.${concurrent_table_b}) AS concurrent_b_count
');
SQL

printf 'Checking authenticated Quack attach and DuckLake write...\n'
duckdb < "$good_sql"

printf 'Checking wrong-token rejection...\n'
if duckdb < "$bad_sql" >/tmp/azquack-wrong-token.log 2>&1; then
  printf 'Wrong-token attach unexpectedly succeeded.\n' >&2
  cat /tmp/azquack-wrong-token.log >&2
  exit 1
fi

printf 'Checking two concurrent local writers through the public query app...\n'
duckdb < "$concurrent_sql_a" &
pid_a=$!
duckdb < "$concurrent_sql_b" &
pid_b=$!
if ! wait "$pid_a"; then
  printf 'Concurrent writer A failed.\n' >&2
  exit 1
fi
if ! wait "$pid_b"; then
  printf 'Concurrent writer B failed.\n' >&2
  exit 1
fi
concurrent_counts="$(duckdb -csv < "$concurrent_verify_sql" | tail -n 1)"
IFS=, read -r concurrent_a_count concurrent_b_count <<EOF
$concurrent_counts
EOF
if [ "$concurrent_a_count" != "500" ] || [ "$concurrent_b_count" != "500" ]; then
  printf 'Concurrent writer check failed: %s\n' "$concurrent_counts" >&2
  exit 1
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

printf 'Checking catalog DuckDB file exists in Azure Files...\n'
catalog_storage_key="$(az storage account keys list \
  --account-name "$CATALOG_STORAGE_ACCOUNT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query '[0].value' \
  -o tsv)"
catalog_file_exists="$(az storage file exists \
  --account-name "$CATALOG_STORAGE_ACCOUNT_NAME" \
  --account-key "$catalog_storage_key" \
  --share-name "$CATALOG_FILE_SHARE_NAME" \
  --path catalog.duckdb \
  --query exists \
  -o tsv)"
if [ "$catalog_file_exists" != "true" ]; then
  printf 'Expected catalog.duckdb in Azure Files share %s.\n' "$CATALOG_FILE_SHARE_NAME" >&2
  exit 1
fi
unset catalog_storage_key

cat > "$post_restart_sql" <<SQL
.bail on
INSTALL quack;
LOAD quack;
CREATE OR REPLACE SECRET azquack_remote (
    TYPE quack,
    SCOPE '$QUACK_URI',
    TOKEN '$QUACK_TOKEN'
);
ATTACH '$QUACK_URI' AS remote (TYPE quack);
SELECT *
FROM remote.query('
    SELECT
        (SELECT count(*) FROM azquack.demo.events WHERE event_id = $marker_id AND event_name = ''$marker_name'') AS marker_count,
        (SELECT count(*) FROM azquack.validation.${validation_table}) AS validation_row_count,
        (SELECT count(*) FROM ducklake_list_files(''azquack'', ''${validation_table}'', schema => ''validation'')) AS validation_file_count
');
SQL

printf 'Restarting query app and verifying rows persist...\n'
restart_active_revision "$QUERY_CONTAINER_APP_NAME" "$RESOURCE_GROUP"
wait_for_ready "$QUACK_HTTP_URL" 300
post_restart_counts="$(duckdb -csv < "$post_restart_sql" | tail -n 1)"
IFS=, read -r post_marker_count post_validation_rows post_validation_files <<EOF
$post_restart_counts
EOF
if [ "$post_marker_count" != "1" ] || [ "$post_validation_rows" != "1000" ] || [ "${post_validation_files:-0}" = "0" ]; then
  printf 'Query restart persistence check failed: %s\n' "$post_restart_counts" >&2
  exit 1
fi

printf 'Restarting catalog app, then query app, and verifying metadata persists...\n'
restart_active_revision "$CATALOG_CONTAINER_APP_NAME" "$RESOURCE_GROUP"
sleep 30
restart_active_revision "$QUERY_CONTAINER_APP_NAME" "$RESOURCE_GROUP"
wait_for_ready "$QUACK_HTTP_URL" 300
post_catalog_restart_counts="$(duckdb -csv < "$post_restart_sql" | tail -n 1)"
IFS=, read -r post_catalog_marker_count post_catalog_validation_rows post_catalog_validation_files <<EOF
$post_catalog_restart_counts
EOF
if [ "$post_catalog_marker_count" != "1" ] || [ "$post_catalog_validation_rows" != "1000" ] || [ "${post_catalog_validation_files:-0}" = "0" ]; then
  printf 'Catalog restart persistence check failed: %s\n' "$post_catalog_restart_counts" >&2
  exit 1
fi

printf 'Scanning recent Container App logs for literal public token value...\n'
collect_logs "$QUERY_CONTAINER_APP_NAME" "$RESOURCE_GROUP" "$query_logs_file"
collect_logs "$CATALOG_CONTAINER_APP_NAME" "$RESOURCE_GROUP" "$catalog_logs_file"
if cat "$query_logs_file" "$catalog_logs_file" | grep -F "$QUACK_TOKEN" >/dev/null; then
  printf 'Public Quack token appeared in logs.\n' >&2
  exit 1
fi
if [ -n "$CATALOG_QUACK_TOKEN" ]; then
  if cat "$query_logs_file" "$catalog_logs_file" | grep -F "$CATALOG_QUACK_TOKEN" >/dev/null; then
    printf 'Internal catalog Quack token appeared in logs.\n' >&2
    exit 1
  fi
else
  printf 'Internal catalog token value is unavailable locally; skipped literal scan for that value.\n' >&2
fi

printf 'Deployment validation passed.\n'
