#!/usr/bin/env bash
# Resets the demo so it can be replayed: clears the telemetry, closes the demo alerts (so the workflow ignores
# them) and deletes the cases the workflow created (tag cmdb-correlation).
# Rules and the workflow are left in place.
source "$(dirname "$0")/lib.sh"

close_open_alerts() {
  # update_by_query skips documents that are being rewritten by the rule executor at that moment
  # (conflicts=proceed), so repeat until no open demo alert is left.
  for _ in 1 2 3 4 5 6; do
    es -X POST "$ES_URL/.alerts-*/_update_by_query?conflicts=proceed&refresh=true" -d "$(jq -nc --arg t "$RULE_TAG" '{
      query:{bool:{filter:[{term:{"kibana.alert.rule.tags":$t}}],must_not:[{terms:{"kibana.alert.workflow_status":["closed"]}}]}},
      script:{lang:"painless", source:"ctx._source[\"kibana.alert.workflow_status\"] = \"closed\""}}')" >/dev/null
    left=$(es "$ES_URL/.alerts-*/_count" -d "$(jq -nc --arg t "$RULE_TAG" '{query:{bool:{filter:[{term:{"kibana.alert.rule.tags":$t}}],must_not:[{term:{"kibana.alert.workflow_status":"closed"}}]}}}')" | jq -r '.count')
    [[ "$left" == "0" ]] && return 0
    sleep 3
  done
  echo "    warning: $left demo alert(s) could not be closed"
}

log "Closing demo alerts (tag $RULE_TAG)"
close_open_alerts

log "Clearing telemetry in $DEMO_INDEX"
es -X POST "$ES_URL/$DEMO_INDEX/_delete_by_query?conflicts=proceed&refresh=true" -d '{"query":{"match_all":{}}}' | jq -c '{deleted,failures}'

# Alerts that are still ACTIVE re-use the same alert document (and keep its workflow status), so wait until the rules
# have recovered them; otherwise the next fault would continue a closed alert instead of raising a new one.
log "Waiting for active demo alerts to recover (rules run every minute, 2m window) ..."
for _ in $(seq 1 30); do
  active=$(es "$ES_URL/.alerts-*/_count" -d "$(jq -nc --arg t "$RULE_TAG" '{query:{bool:{filter:[{term:{"kibana.alert.rule.tags":$t}},{term:{"kibana.alert.status":"active"}}]}}}')" | jq -r '.count')
  echo "    active alerts: $active"
  [[ "$active" == "0" ]] && break
  sleep 15
done
close_open_alerts

log "Deleting cases tagged cmdb-correlation"
ids=$(kb "$KB_URL/api/cases/_find?tags=cmdb-correlation&perPage=100" | jq -r '[.cases[]?.id] | join(",")')
if [[ -n "$ids" ]]; then
  kb -o /dev/null -w '    HTTP %{http_code}\n' -X DELETE "$KB_URL/api/cases?ids=$(jq -rn --arg i "$ids" '$i | split(",") | map("\"" + . + "\"") | "[" + join(",") + "]" | @uri')"
else
  echo "    none"
fi
