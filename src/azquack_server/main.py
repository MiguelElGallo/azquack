from __future__ import annotations

import json
import logging
import os
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import NoReturn

import duckdb


LOG_LEVEL = os.getenv("AZQUACK_LOG_LEVEL", "INFO").upper()
logging.basicConfig(level=LOG_LEVEL, format="%(asctime)s %(levelname)s %(message)s")
LOGGER = logging.getLogger("azquack")

READY = threading.Event()
STOP = threading.Event()
STARTUP_ERROR: str | None = None


def require_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path not in {"/", "/healthz", "/readyz"}:
            self.send_response(404)
            self.end_headers()
            return

        status = 503 if self.path == "/readyz" and not READY.is_set() else 200
        body = json.dumps(
            {
                "ready": READY.is_set(),
            }
        ).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: object) -> None:
        LOGGER.debug("healthcheck " + fmt, *args)


def start_health_server() -> ThreadingHTTPServer:
    port = int(os.getenv("AZQUACK_HEALTH_PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), HealthHandler)
    thread = threading.Thread(target=server.serve_forever, name="health", daemon=True)
    thread.start()
    LOGGER.info("health server listening on port %s", port)
    return server


def install_and_load_extensions(con: duckdb.DuckDBPyConnection) -> None:
    extensions = ["azure", "ducklake", "quack"]
    for extension in extensions:
        con.execute(f"FORCE INSTALL {extension}")
        con.execute(f"LOAD {extension}")


def configure_storage_secret(con: duckdb.DuckDBPyConnection) -> None:
    storage_account = require_env("AZQUACK_STORAGE_ACCOUNT")
    client_id = os.getenv("AZURE_CLIENT_ID")
    ca_cert_file = os.getenv("CURL_CA_INFO", "/etc/ssl/certs/ca-certificates.crt")
    con.execute(f"SET ca_cert_file = {sql_string(ca_cert_file)}")
    con.execute("SET azure_transport_option_type = 'curl'")
    if client_id:
        con.execute(
            f"""
            CREATE SECRET azquack_storage (
                TYPE azure,
                PROVIDER managed_identity,
                ACCOUNT_NAME {sql_string(storage_account)},
                CLIENT_ID {sql_string(client_id)}
            )
            """
        )
        return

    chain = os.getenv("AZQUACK_AZURE_CREDENTIAL_CHAIN", "managed_identity;env;cli")
    con.execute(
        f"""
        CREATE SECRET azquack_storage (
            TYPE azure,
            PROVIDER credential_chain,
            CHAIN {sql_string(chain)},
            ACCOUNT_NAME {sql_string(storage_account)}
        )
        """
    )


def attach_ducklake_via_quack(con: duckdb.DuckDBPyConnection) -> None:
    catalog_uri = require_env("AZQUACK_CATALOG_QUACK_URI")
    catalog_token = require_env("AZQUACK_CATALOG_QUACK_TOKEN")
    data_path = require_env("AZQUACK_DUCKLAKE_DATA_PATH")
    con.execute(
        f"""
        CREATE OR REPLACE SECRET azquack_catalog_quack (
            TYPE quack,
            SCOPE {sql_string(catalog_uri)},
            TOKEN {sql_string(catalog_token)}
        )
        """
    )
    con.execute(
        f"""
        ATTACH {sql_string("ducklake:" + catalog_uri)} AS azquack
        (
            DATA_PATH {sql_string(data_path)},
            AUTOMATIC_MIGRATION true
        )
        """
    )
    con.execute("USE azquack")


def attach_ducklake_with_retry(con: duckdb.DuckDBPyConnection) -> None:
    attempts = int(os.getenv("AZQUACK_CATALOG_ATTACH_ATTEMPTS", "12"))
    for attempt in range(1, attempts + 1):
        try:
            attach_ducklake_via_quack(con)
            return
        except Exception as exc:
            if attempt == attempts:
                raise
            delay = min(30, attempt * 5)
            LOGGER.warning(
                "DuckLake catalog attach failed (%s); retrying in %s seconds",
                exc,
                delay,
                exc_info=True,
            )
            time.sleep(delay)


def initialize_demo_data(con: duckdb.DuckDBPyConnection) -> None:
    attempts = int(os.getenv("AZQUACK_INIT_ATTEMPTS", "8"))
    for attempt in range(1, attempts + 1):
        try:
            con.execute("CREATE SCHEMA IF NOT EXISTS demo")
            con.execute(
                """
                CREATE TABLE IF NOT EXISTS demo.events (
                    event_id INTEGER,
                    event_name VARCHAR,
                    created_at TIMESTAMPTZ
                )
                """
            )
            con.execute(
                """
                INSERT INTO demo.events
                SELECT 1, 'quack-over-azure', now()
                WHERE NOT EXISTS (
                    SELECT 1 FROM demo.events WHERE event_id = 1
                )
                """
            )
            return
        except Exception as exc:
            if attempt == attempts:
                raise
            delay = min(30, attempt * 5)
            LOGGER.warning(
                "demo data initialization failed (%s); retrying in %s seconds",
                exc,
                delay,
                exc_info=True,
            )
            time.sleep(delay)


def identify_node(con: duckdb.DuckDBPyConnection) -> None:
    meta = {
        "role": os.getenv("AZQUACK_ROLE", "query"),
        "storage_account": os.getenv("AZQUACK_STORAGE_ACCOUNT"),
        "ducklake_data_path": os.getenv("AZQUACK_DUCKLAKE_DATA_PATH"),
    }
    con.execute(
        f"""
        CALL quack_identify(
            name => {sql_string(os.getenv("AZQUACK_NODE_NAME", "azquack"))},
            provider => 'azure-container-apps',
            region => {sql_string(os.getenv("AZURE_LOCATION", "unknown"))},
            meta => {sql_string(json.dumps(meta, sort_keys=True))}
        )
        """
    )


def serve_quack(con: duckdb.DuckDBPyConnection) -> None:
    token = require_env("AZQUACK_QUACK_TOKEN")
    uri = os.getenv("AZQUACK_LISTEN_URI", "quack:127.0.0.1:9494")
    allow_other_hostname = "true" if "0.0.0.0" in uri else "false"
    con.execute(
        f"""
        CALL quack_serve(
            {sql_string(uri)},
            token => {sql_string(token)},
            allow_other_hostname => {allow_other_hostname}
        )
        """
    ).fetchall()
    LOGGER.info("quack server started on %s", uri)


def run_catalog() -> None:
    global STARTUP_ERROR

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    health_server = start_health_server()
    db_path = require_env("AZQUACK_CATALOG_DB_PATH")
    con = duckdb.connect(db_path)
    try:
        LOGGER.info("starting catalog role with DuckDB file %s", db_path)
        con.execute("FORCE INSTALL quack")
        con.execute("LOAD quack")
        identify_node(con)
        serve_quack(con)
        READY.set()
        LOGGER.info("AzQuack catalog is ready")

        while not STOP.is_set():
            time.sleep(1)
    except Exception as exc:
        STARTUP_ERROR = f"{type(exc).__name__}: {exc}"
        LOGGER.exception("catalog startup failed")
        raise
    finally:
        READY.clear()
        listen_uri = os.getenv("AZQUACK_LISTEN_URI", "quack:127.0.0.1:9494")
        try:
            con.execute(f"CALL quack_stop({sql_string(listen_uri)})")
        except Exception as exc:  # noqa: BLE001 - shutdown should continue.
            LOGGER.info("quack stop skipped: %s", exc)
        con.close()
        health_server.shutdown()


def handle_signal(signum: int, _frame: object) -> None:
    LOGGER.info("received signal %s, shutting down", signum)
    STOP.set()


def run_query() -> None:
    global STARTUP_ERROR

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    health_server = start_health_server()
    con = duckdb.connect(os.getenv("AZQUACK_BOOTSTRAP_DB", ":memory:"))
    try:
        LOGGER.info("installing DuckDB extensions")
        install_and_load_extensions(con)
        LOGGER.info("configuring Azure storage secret")
        configure_storage_secret(con)
        LOGGER.info("attaching DuckLake through internal Quack catalog")
        attach_ducklake_with_retry(con)
        LOGGER.info("initializing demo data")
        initialize_demo_data(con)
        LOGGER.info("identifying Quack node")
        identify_node(con)
        LOGGER.info("starting Quack")
        serve_quack(con)
        READY.set()
        LOGGER.info("AzQuack is ready")

        while not STOP.is_set():
            time.sleep(1)
    except Exception as exc:
        STARTUP_ERROR = f"{type(exc).__name__}: {exc}"
        LOGGER.exception("startup failed")
        raise
    finally:
        READY.clear()
        listen_uri = os.getenv("AZQUACK_LISTEN_URI", "quack:127.0.0.1:9494")
        try:
            con.execute(f"CALL quack_stop({sql_string(listen_uri)})")
        except Exception as exc:  # noqa: BLE001 - shutdown should continue.
            LOGGER.info("quack stop skipped: %s", exc)
        con.close()
        health_server.shutdown()


def main() -> NoReturn:
    try:
        role = os.getenv("AZQUACK_ROLE", "query")
        if role == "catalog":
            run_catalog()
        elif role == "query":
            run_query()
        else:
            raise RuntimeError(f"Unsupported AZQUACK_ROLE: {role}")
    except Exception:
        LOGGER.exception("azquack server failed")
        raise SystemExit(1)
    raise SystemExit(0)
