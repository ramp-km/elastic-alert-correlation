#!/usr/bin/env bash
# Creates or updates the correlation workflow in Kibana (id: $WORKFLOW_ID).
# Optional: AI_CONNECTOR_ID=<connector id> pins the LLM connector used by the ai.prompt steps.
source "$(dirname "$0")/lib.sh"

SRC="$ROOT_DIR/workflows/cmdb-alert-correlation.yaml"
yaml=$(cat "$SRC")
if [[ -n "${AI_CONNECTOR_ID:-}" ]]; then
  log "Pinning ai.prompt steps to connector $AI_CONNECTOR_ID"
  yaml=$(awk -v c="$AI_CONNECTOR_ID" '{print} /^ *type: ai\.prompt$/ {match($0,/^ */); printf "%*sconnector-id: \"%s\"\n", RLENGTH, "", c}' <<<"$yaml")
fi

payload=$(jq -nc --arg y "$yaml" --arg id "$WORKFLOW_ID" '{id:$id, yaml:$y}')
if [[ "$(kb -o /dev/null -w '%{http_code}' "$KB_URL/api/workflows/workflow/$WORKFLOW_ID")" == "200" ]]; then
  log "Updating workflow $WORKFLOW_ID"
  kb -X PUT "$KB_URL/api/workflows/workflow/$WORKFLOW_ID" -d "$(jq -nc --arg y "$yaml" '{yaml:$y}')" | jq -c '{id,valid,enabled,error,message,warnings}'
else
  log "Creating workflow $WORKFLOW_ID"
  kb -X POST "$KB_URL/api/workflows/workflow" -d "$payload" | jq -c '{id,name,enabled,valid,error,message}'
fi
