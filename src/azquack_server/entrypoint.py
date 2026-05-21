from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from pathlib import Path


SENSITIVE_ENV_NAMES = {
    "AZQUACK_CATALOG_QUACK_TOKEN",
    "AZQUACK_QUACK_TOKEN",
}


def scrubbed_env() -> dict[str, str]:
    return {key: value for key, value in os.environ.items() if key not in SENSITIVE_ENV_NAMES}


def terminate(processes: list[subprocess.Popen[object]]) -> None:
    for process in processes:
        if process.poll() is None:
            process.terminate()
    for process in processes:
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()


def main() -> int:
    caddyfile = Path(os.getenv("AZQUACK_CADDYFILE", "/app/deploy/Caddyfile"))
    enable_caddy = os.getenv("AZQUACK_ENABLE_CADDY", "true").lower() == "true"
    processes: list[subprocess.Popen[object]] = []

    def handle_signal(signum: int, _frame: object) -> None:
        terminate(processes)
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    if enable_caddy:
        processes.append(
            subprocess.Popen(
                [
                    "caddy",
                    "run",
                    "--config",
                    str(caddyfile),
                    "--adapter",
                    "caddyfile",
                ],
                env=scrubbed_env(),
            )
        )
    else:
        print("Caddy disabled for this AzQuack role.", flush=True)

    processes.append(subprocess.Popen(["azquack-server"]))

    while True:
        for process in processes:
            return_code = process.poll()
            if return_code is not None:
                terminate(processes)
                return return_code
        time.sleep(1)


if __name__ == "__main__":
    sys.exit(main())
