#!/usr/bin/env bash
# Shared helpers: loads .env, wraps curl for Elasticsearch and Kibana.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"   # override with ENV_FILE=/path/to/creds to keep secrets outside the repo
if [[ -f "$ENV_FILE" ]]; then set -a; source "$ENV_FILE"; set +a; fi

: "${ES_URL:?Set ES_URL in .env}"
: "${KB_URL:?Set KB_URL in .env}"
: "${ES_API_KEY:?Set ES_API_KEY in .env}"
command -v jq >/dev/null   || { echo "jq is required"; exit 1; }
command -v curl >/dev/null || { echo "curl is required"; exit 1; }

# Names used by every script
DEMO_INDEX="cmdb-demo-telemetry"
DEMO_DATAVIEW_ID="cmdb-demo-telemetry"
RULE_TAG="cmdb-ci-correlation"
WORKFLOW_ID="cmdb-alert-correlation"

# INSECURE=1 skips TLS certificate verification (self-signed / private-CA clusters). Use on trusted networks only.
CURL_INSECURE=""
if [[ "${INSECURE:-0}" == "1" ]]; then CURL_INSECURE="-k"; printf '\033[1;33mwarning:\033[0m TLS verification disabled (INSECURE=1)\n' >&2; fi

es() { curl -sS $CURL_INSECURE -m 120 -H "Authorization: ApiKey $ES_API_KEY" -H 'Content-Type: application/json' "$@"; }
kb() { curl -sS $CURL_INSECURE -m 120 -H "Authorization: ApiKey $ES_API_KEY" -H 'Content-Type: application/json' -H 'kbn-xsrf: true' "$@"; }

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
