#!/usr/bin/env python3
from __future__ import annotations

import csv
import http.cookiejar
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any


SESSION_COUNT = int(os.getenv("AZQUACK_STICKY_SESSION_COUNT", "12"))
ATTEMPTS_PER_SESSION = int(os.getenv("AZQUACK_STICKY_ATTEMPTS", "8"))
LARGE_RESULT_ROWS = int(os.getenv("AZQUACK_STICKY_LARGE_ROWS", "200000"))
REPLICA_RE = re.compile(r"[\w-]+--[\w-]+-[a-z0-9]+-[a-z0-9]+")


def run(
    cmd: list[str],
    *,
    input_text: str | None = None,
    token: str | None = None,
    fatal: bool = True,
) -> str:
    completed = subprocess.run(
        cmd,
        input=input_text,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    output = completed.stdout
    if token:
        output = output.replace(token, "<redacted-token>")
    if completed.returncode != 0:
        if fatal:
            print(output, file=sys.stderr)
            raise SystemExit(completed.returncode)
        raise RuntimeError(output.strip())
    return output


def azd_value(name: str) -> str:
    return run(["azd", "env", "get-value", name]).strip()


def require_tool(name: str) -> None:
    try:
        run(["sh", "-c", f"command -v {name} >/dev/null"])
    except SystemExit:
        print(f"{name} is required.", file=sys.stderr)
        raise


def sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def redact_resource(value: str) -> str:
    return re.sub(r"[a-z0-9]{10,}", "<redacted>", value)


def wait_for_ready(url: str, timeout_seconds: int = 300) -> None:
    deadline = time.time() + timeout_seconds
    last_body = ""
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"{url}/readyz", timeout=10) as response:
                last_body = response.read().decode("utf-8", "replace")
            if '"ready": true' in last_body:
                return
        except Exception as exc:  # noqa: BLE001 - readiness polling reports the last failure.
            last_body = str(exc)
        time.sleep(5)
    raise SystemExit(f"Timed out waiting for /readyz. Last response: {last_body}")


def container_app_json(name: str, resource_group: str) -> dict[str, Any]:
    return json.loads(
        run(
            [
                "az",
                "containerapp",
                "show",
                "--name",
                name,
                "--resource-group",
                resource_group,
                "-o",
                "json",
            ]
        )
    )


def replica_names(name: str, resource_group: str) -> list[str]:
    output = run(
        [
            "az",
            "containerapp",
            "replica",
            "list",
            "--name",
            name,
            "--resource-group",
            resource_group,
            "--query",
            "[].name",
            "-o",
            "tsv",
        ]
    )
    return sorted(line.strip() for line in output.splitlines() if line.strip())


def wait_for_replicas(name: str, resource_group: str, expected: int) -> list[str]:
    deadline = time.time() + 360
    last: list[str] = []
    while time.time() < deadline:
        last = replica_names(name, resource_group)
        if len(last) >= expected:
            return last
        time.sleep(10)
    raise SystemExit(f"Timed out waiting for {expected} query replicas. Last replicas: {last}")


def health_cookie_probe(base_url: str) -> tuple[list[str], list[str]]:
    cookie_jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookie_jar))
    sticky: list[str] = []
    stateless: list[str] = []

    for _ in range(6):
        with opener.open(f"{base_url}/readyz", timeout=15) as response:
            body = json.loads(response.read().decode("utf-8"))
        sticky.append(body.get("container_app_replica_name") or "<missing>")

    for _ in range(12):
        with urllib.request.urlopen(f"{base_url}/readyz", timeout=15) as response:
            body = json.loads(response.read().decode("utf-8"))
        stateless.append(body.get("container_app_replica_name") or "<missing>")

    return sticky, stateless


def require_probe_evidence(sticky_health: list[str], stateless_health: list[str]) -> None:
    if "<missing>" in sticky_health or "<missing>" in stateless_health:
        raise SystemExit(
            "/readyz did not expose container_app_replica_name. Set "
            "QUERY_EXPOSE_PLATFORM_METADATA=true and redeploy before running "
            "the sticky-session experiment."
        )
    if len(set(sticky_health)) != 1:
        raise SystemExit("Cookie-aware /readyz requests did not stay on one replica.")
    if len(set(stateless_health)) < 2:
        raise SystemExit(
            "Stateless /readyz requests did not reach at least two replicas; "
            "multi-replica ingress distribution was not proven."
        )


def extract_replica(row: dict[str, str]) -> str | None:
    for key in ("replica_hostname", "created_on"):
        value = row.get(key)
        if value:
            return value

    for key in ("meta", "metadata"):
        value = row.get(key)
        if not value:
            continue
        try:
            meta = json.loads(value)
        except json.JSONDecodeError:
            meta = None
        if isinstance(meta, dict):
            replica = meta.get("container_app_replica_name")
            if replica:
                return str(replica)

    for key in ("name", "node_name"):
        value = row.get(key)
        if not value:
            continue
        match = REPLICA_RE.search(value)
        if match:
            return match.group(0)

    for value in row.values():
        match = REPLICA_RE.search(value or "")
        if match:
            return match.group(0)
    return None


def write_session_sql(
    path: Path,
    output_dir: Path,
    session_id: int,
    quack_uri: str,
    token: str,
) -> None:
    statements = [
        ".bail on",
        "INSTALL quack;",
        "LOAD quack;",
        "CREATE OR REPLACE SECRET azquack_remote (",
        "    TYPE quack,",
        f"    SCOPE {sql_string(quack_uri)},",
        f"    TOKEN {sql_string(token)}",
        ");",
        f"ATTACH {sql_string(quack_uri)} AS remote (TYPE quack);",
    ]

    state_table = f"sticky_session_{session_id}"
    create_state_sql = (
        "DROP TABLE IF EXISTS __azquack_host; "
        "CREATE TEMP TABLE __azquack_host(line VARCHAR); "
        "COPY __azquack_host FROM '/etc/hostname'; "
        f"CREATE TEMP TABLE {state_table} AS "
        "SELECT trim(line) AS replica_hostname FROM __azquack_host; "
        f"SELECT replica_hostname AS created_on FROM {state_table}"
    )
    state_out = output_dir / f"session_{session_id:02d}_state.csv"
    statements.append(
        "COPY ("
        "SELECT * FROM remote.query("
        + sql_string(create_state_sql)
        + ")"
        f") TO {sql_string(str(state_out))} (HEADER true);"
    )

    for attempt in range(1, ATTEMPTS_PER_SESSION + 1):
        out = output_dir / f"session_{session_id:02d}_probe_{attempt:02d}.csv"
        probe_sql = (
            "DROP TABLE IF EXISTS __azquack_host; "
            "CREATE TEMP TABLE __azquack_host(line VARCHAR); "
            "COPY __azquack_host FROM '/etc/hostname'; "
            "SELECT "
            "trim((SELECT line FROM __azquack_host LIMIT 1)) AS replica_hostname, "
            f"(SELECT count(*) FROM duckdb_tables() WHERE table_name = '{state_table}' AND temporary) AS temp_seen"
        )
        statements.append(
            "COPY ("
            f"SELECT {session_id} AS session_id, {attempt} AS attempt, * "
            "FROM remote.query("
            + sql_string(probe_sql)
            + ")"
            f") TO {sql_string(str(out))} (HEADER true);"
        )

    tx_table = f"sticky_tx_{int(time.time())}_{session_id}"
    statements.extend(
        [
            "FROM remote.query("
            + sql_string(
                f"BEGIN; CREATE TEMP TABLE {tx_table} AS SELECT 1 AS id; SELECT 1 AS began"
            )
            + ");",
        ]
    )

    count_out = output_dir / f"session_{session_id:02d}_tx_count.csv"
    statements.append(
        "COPY ("
        "SELECT * FROM remote.query("
        + sql_string(
            f"INSERT INTO {tx_table} VALUES (2); "
            f"SELECT count(*) AS row_count FROM {tx_table}"
        )
        + ")"
        f") TO {sql_string(str(count_out))} (HEADER true);"
    )
    statements.append("FROM remote.query('ROLLBACK; SELECT 1 AS rolled_back');")

    large_out = output_dir / f"session_{session_id:02d}_large.csv"
    statements.append(
        "COPY ("
        "SELECT count(*) AS row_count, count(DISTINCT replica_hostname) AS replica_count, "
        "sum(i) AS checksum FROM remote.query("
        + sql_string(
            "DROP TABLE IF EXISTS __azquack_host; "
            "CREATE TEMP TABLE __azquack_host(line VARCHAR); "
            "COPY __azquack_host FROM '/etc/hostname'; "
            f"SELECT trim((SELECT line FROM __azquack_host LIMIT 1)) AS replica_hostname, "
            f"i::BIGINT AS i FROM range(0, {LARGE_RESULT_ROWS}) AS t(i)"
        )
        + ")"
        f") TO {sql_string(str(large_out))} (HEADER true);"
    )

    write_table = f"sticky_write_{int(time.time())}_{session_id}"
    statements.extend(
        [
            "FROM remote.query('CREATE SCHEMA IF NOT EXISTS azquack.sticky');",
            f"FROM remote.query('DROP TABLE IF EXISTS azquack.sticky.{write_table}');",
            "FROM remote.query("
            + sql_string(
                "DROP TABLE IF EXISTS __azquack_host; "
                "CREATE TEMP TABLE __azquack_host(line VARCHAR); "
                "COPY __azquack_host FROM '/etc/hostname'; "
                f"CREATE TABLE azquack.sticky.{write_table} AS "
                f"SELECT {session_id}::INTEGER AS session_id, i::BIGINT AS id, "
                "trim((SELECT line FROM __azquack_host LIMIT 1)) AS replica_hostname "
                "FROM range(0, 25) AS t(i)"
            )
            + ");",
        ]
    )
    write_out = output_dir / f"session_{session_id:02d}_write_count.csv"
    statements.append(
        "COPY ("
        "SELECT * FROM remote.query("
        + sql_string(
            f"SELECT count(*) AS row_count, count(DISTINCT replica_hostname) AS replica_count "
            f"FROM azquack.sticky.{write_table}"
        )
        + ")"
        f") TO {sql_string(str(write_out))} (HEADER true);"
    )
    statements.append(f"FROM remote.query('DROP TABLE IF EXISTS azquack.sticky.{write_table}');")

    path.write_text("\n".join(statements) + "\n", encoding="utf-8")
    path.chmod(0o600)


def read_csv_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def run_duckdb_session(session_id: int, quack_uri: str, token: str, tmp: Path) -> dict[str, Any]:
    sql_path = tmp / f"session_{session_id:02d}.sql"
    output_dir = tmp / f"session_{session_id:02d}"
    output_dir.mkdir()
    write_session_sql(sql_path, output_dir, session_id, quack_uri, token)
    output = run(
        ["duckdb"],
        input_text=sql_path.read_text(encoding="utf-8"),
        token=token,
        fatal=False,
    )

    replicas: list[str] = []
    state_rows = read_csv_rows(output_dir / f"session_{session_id:02d}_state.csv")
    if not state_rows:
        raise RuntimeError(f"session {session_id} did not create remote sticky state")
    sample_row: dict[str, str] | None = state_rows[0]
    for attempt in range(1, ATTEMPTS_PER_SESSION + 1):
        rows = read_csv_rows(output_dir / f"session_{session_id:02d}_probe_{attempt:02d}.csv")
        if not rows:
            raise RuntimeError(f"session {session_id} attempt {attempt} returned no probe rows")
        sample_row = sample_row or rows[0]
        if rows[0].get("temp_seen") != "1":
            raise RuntimeError(
                f"session {session_id} attempt {attempt} lost remote temp state: {rows[0]}"
            )
        replica = extract_replica(rows[0])
        if not replica:
            raise RuntimeError(
                f"session {session_id} could not extract replica from probe columns {list(rows[0])}"
            )
        replicas.append(replica)

    tx_rows = read_csv_rows(output_dir / f"session_{session_id:02d}_tx_count.csv")
    large_rows = read_csv_rows(output_dir / f"session_{session_id:02d}_large.csv")
    write_rows = read_csv_rows(output_dir / f"session_{session_id:02d}_write_count.csv")
    if tx_rows[0].get("row_count") != "2":
        raise RuntimeError(f"session {session_id} split transaction row count failed: {tx_rows}")
    expected_checksum = LARGE_RESULT_ROWS * (LARGE_RESULT_ROWS - 1) // 2
    if large_rows[0].get("row_count") != str(LARGE_RESULT_ROWS):
        raise RuntimeError(f"session {session_id} large result row count failed: {large_rows}")
    if large_rows[0].get("replica_count") != "1":
        raise RuntimeError(f"session {session_id} large result moved replicas: {large_rows}")
    if large_rows[0].get("checksum") != str(expected_checksum):
        raise RuntimeError(f"session {session_id} large result checksum failed: {large_rows}")
    if write_rows[0].get("row_count") != "25":
        raise RuntimeError(f"session {session_id} DuckLake write count failed: {write_rows}")

    return {
        "session_id": session_id,
        "replicas": replicas,
        "distinct_replicas": sorted(set(replicas)),
        "sample_columns": list(sample_row or {}),
        "duckdb_output": output,
    }


def main() -> int:
    for tool in ("az", "azd", "duckdb"):
        require_tool(tool)

    local_version = run(["duckdb", "-csv", "-c", "SELECT version();"]).splitlines()[-1]
    if local_version != "v1.5.3":
        raise SystemExit(f"Local duckdb CLI must be v1.5.3. Found {local_version}.")

    resource_group = azd_value("AZURE_RESOURCE_GROUP")
    query_app = azd_value("QUERY_CONTAINER_APP_NAME")
    catalog_app = azd_value("CATALOG_CONTAINER_APP_NAME")
    quack_uri = azd_value("QUACK_URI")
    quack_http_url = azd_value("QUACK_HTTP_URL")
    key_vault = azd_value("KEY_VAULT_NAME")
    token = run(
        [
            "az",
            "keyvault",
            "secret",
            "show",
            "--vault-name",
            key_vault,
            "--name",
            "quack-token",
            "--query",
            "value",
            "-o",
            "tsv",
        ]
    ).strip()

    query = container_app_json(query_app, resource_group)
    catalog = container_app_json(catalog_app, resource_group)
    query_scale = query["properties"]["template"]["scale"]
    catalog_scale = catalog["properties"]["template"]["scale"]
    sticky = query["properties"]["configuration"]["ingress"].get("stickySessions", {})

    if query["properties"]["configuration"]["activeRevisionsMode"] != "Single":
        raise SystemExit("Query app must use activeRevisionsMode=Single for ACA sticky sessions.")
    if sticky.get("affinity") != "sticky":
        raise SystemExit(f"Query app sticky session affinity is not enabled: {sticky!r}")
    if int(query_scale.get("minReplicas", 0)) < 2 or int(query_scale.get("maxReplicas", 0)) < 2:
        raise SystemExit(f"Query app must have at least 2 min/max replicas for this test: {query_scale}")
    if int(catalog_scale.get("minReplicas", 0)) != 1 or int(catalog_scale.get("maxReplicas", 0)) != 1:
        raise SystemExit(f"Catalog app must stay single-replica: {catalog_scale}")

    wait_for_ready(quack_http_url)
    replicas = wait_for_replicas(query_app, resource_group, 2)
    sticky_health, stateless_health = health_cookie_probe(quack_http_url)
    require_probe_evidence(sticky_health, stateless_health)

    with tempfile.TemporaryDirectory(prefix="azquack-sticky-") as tmp_name:
        tmp = Path(tmp_name)
        results: list[dict[str, Any]] = []
        errors: list[str] = []
        with ThreadPoolExecutor(max_workers=min(SESSION_COUNT, 8)) as executor:
            futures = [
                executor.submit(run_duckdb_session, session_id, quack_uri, token, tmp)
                for session_id in range(1, SESSION_COUNT + 1)
            ]
            for future in as_completed(futures):
                try:
                    results.append(future.result())
                except BaseException as exc:  # noqa: BLE001 - report every failed session.
                    errors.append(str(exc) or type(exc).__name__)

    results.sort(key=lambda item: item["session_id"])
    bounced = [item for item in results if len(item["distinct_replicas"]) != 1]
    observed = sorted({replica for item in results for replica in item["distinct_replicas"]})

    print("Sticky-session validation summary")
    print(f"Query app: {query_app}")
    print(f"Catalog app: {catalog_app}")
    print(f"Configured query scale: min={query_scale['minReplicas']} max={query_scale['maxReplicas']}")
    print(f"Configured query sticky affinity: {sticky.get('affinity')}")
    print(f"Running query replicas: {[redact_resource(item) for item in replicas]}")
    print(f"Cookie-aware /readyz replicas: {[redact_resource(item) for item in sticky_health]}")
    print(f"Stateless /readyz replicas: {[redact_resource(item) for item in stateless_health]}")

    if errors:
        print("Quack session validation failed.")
        print("ACA sticky sessions work for cookie-aware /readyz requests, but one or more")
        print("DuckDB Quack clients failed after ATTACH. This usually means the Quack client")
        print("did not replay the ACA affinity cookie and a follow-up request reached a")
        print("different query replica.")
        for error in errors[:8]:
            print(f"  error: {error}")
        return 1

    print(f"Quack sessions observed replicas: {[redact_resource(item) for item in observed]}")
    for item in results:
        redacted = [redact_resource(replica) for replica in item["distinct_replicas"]]
        print(f"  session {item['session_id']:02d}: {redacted}")

    if bounced:
        print("One or more Quack sessions moved between replicas:", file=sys.stderr)
        for item in bounced:
            print(
                f"  session {item['session_id']}: "
                f"{[redact_resource(replica) for replica in item['replicas']]}",
                file=sys.stderr,
            )
        return 1

    if len(observed) < 2:
        print(
            "Only one query replica was observed by Quack sessions; affinity was stable but "
            "multi-replica routing was not proven.",
            file=sys.stderr,
        )
        return 1

    if len(set(sticky_health)) != 1:
        print("Cookie-aware /readyz requests did not stay on one replica.", file=sys.stderr)
        return 1

    print("Sticky-session validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
