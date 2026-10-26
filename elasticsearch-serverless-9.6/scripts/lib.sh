#!/usr/bin/env bash
# Shared helpers: loads .env, wraps curl for Elasticsearch and Kibana.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$ROOT_DIR/.env" ]]; then set -a; source "$ROOT_DIR/.env"; set +a; fi

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

es() { curl -sS -m 120 -H "Authorization: ApiKey $ES_API_KEY" -H 'Content-Type: application/json' "$@"; }
kb() { curl -sS -m 120 -H "Authorization: ApiKey $ES_API_KEY" -H 'Content-Type: application/json' -H 'kbn-xsrf: true' "$@"; }

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
