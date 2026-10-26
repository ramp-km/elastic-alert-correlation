#!/usr/bin/env bash
# Removes everything the demo created: rules, workflow, data view, telemetry index, cases and demo alerts.
source "$(dirname "$0")/lib.sh"
"$(dirname "$0")/05_reset_demo.sh"

log "Deleting rules tagged $RULE_TAG"
kb "$KB_URL/api/alerting/rules/_find?per_page=100&search_fields=tags&search=$RULE_TAG" | jq -r '.data[].id' | while read -r id; do
  kb -o /dev/null -w "    $id HTTP %{http_code}\n" -X DELETE "$KB_URL/api/alerting/rule/$id"
done
log "Deleting workflow $WORKFLOW_ID"
# 9.4.0: DELETE /api/workflows/workflow/<id> answers 200 without deleting; the bulk endpoint does.
kb -X DELETE "$KB_URL/api/workflows" -d "$(jq -nc --arg id "$WORKFLOW_ID" '{ids:[$id]}')" | jq -c .
log "Deleting data view and index"
kb -o /dev/null -w '    HTTP %{http_code}\n' -X DELETE "$KB_URL/api/data_views/data_view/$DEMO_DATAVIEW_ID"
es -X DELETE "$ES_URL/$DEMO_INDEX" | jq -c .
