#!/bin/sh
set -eu

printf '\nAzQuack provisioned.\n'
printf 'Quack URI: %s\n' "$(azd env get-value QUACK_URI 2>/dev/null || printf '<run azd up first>')"
printf 'Health URL: %s/healthz\n' "$(azd env get-value QUACK_HTTP_URL 2>/dev/null || printf '<run azd up first>')"
printf '\nRun ./scripts/connect-local.sh to query the remote DuckLake through local DuckDB.\n'
