#!/bin/sh
set -eu

python3 -m compileall -q src

command -v az >/dev/null 2>&1 || { printf 'az CLI is required for Bicep validation.\n' >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { printf 'Docker is required for the container build validation.\n' >&2; exit 1; }

az bicep build --file infra/main.bicep >/dev/null
docker build .

printf 'Checks passed.\n'
