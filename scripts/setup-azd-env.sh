#!/bin/sh
set -eu

random_alnum() {
  bytes="${1:-32}"
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$bytes"
}

get_env_value() {
  name="$1"
  value="$(azd env get-value "$name" 2>/dev/null || true)"
  case "$value" in
    *"key not found in environment values"*) value="" ;;
  esac
  printf '%s' "$value"
}

set_if_empty() {
  name="$1"
  value="$2"
  current="$(get_env_value "$name")"
  if [ -z "$current" ]; then
    azd env set "$name" "$value" >/dev/null
    printf 'Set %s\n' "$name"
  fi
}

set_if_empty QUACK_TOKEN "$(random_alnum 48)"
set_if_empty CATALOG_QUACK_TOKEN "$(random_alnum 48)"
set_if_empty DUCKLAKE_DATA_PATH "az://lakehouse/data/"
set_if_empty OPERATOR_PRINCIPAL_TYPE "User"

if [ -z "$(get_env_value OPERATOR_PRINCIPAL_ID)" ] && command -v az >/dev/null 2>&1; then
  principal_id="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
  if [ -n "$principal_id" ]; then
    azd env set OPERATOR_PRINCIPAL_ID "$principal_id" >/dev/null
    printf 'Set OPERATOR_PRINCIPAL_ID\n'
  else
    printf 'OPERATOR_PRINCIPAL_ID not set. Set it manually if local smoke tests need Key Vault token access.\n' >&2
  fi
fi
