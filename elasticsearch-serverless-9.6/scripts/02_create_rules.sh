#!/usr/bin/env bash
# Creates the Kibana custom-threshold rules that raise alerts per CMDB CI.
#
# Every rule groups by cmdb.ci.name, so each alert's kibana.alert.instance.id is the CI name
# (e.g. "hvhost01"). The correlation workflow keys on that plus the rule tag $RULE_TAG.
source "$(dirname "$0")/lib.sh"

# NB: fields ending in .pct hold fractions (0.9 == 90%) because Kibana renders *.pct fields as percentages.
RULES=$(cat <<'JSON'
[
  {"name":"CMDB | IIS response time high",           "class":"iis",        "field":"iis.response_time_ms",              "agg":"avg", "threshold":2000},
  {"name":"CMDB | IIS HTTP 5xx errors",              "class":"iis",        "field":"iis.http_5xx",                      "agg":"sum", "threshold":50},
  {"name":"CMDB | Server CPU saturation",            "class":"server",     "field":"host.cpu.pct",                      "agg":"avg", "threshold":0.9},
  {"name":"CMDB | Server memory pressure",           "class":"server",     "field":"host.memory.pct",                   "agg":"avg", "threshold":0.92},
  {"name":"CMDB | Server disk I/O latency high",     "class":"server",     "field":"host.disk.io_latency_ms",           "agg":"avg", "threshold":50},
  {"name":"CMDB | Hypervisor datastore latency high","class":"hypervisor", "field":"hypervisor.datastore_latency_ms",   "agg":"avg", "threshold":40},
  {"name":"CMDB | Hypervisor CPU ready high",        "class":"hypervisor", "field":"hypervisor.cpu_ready.pct",          "agg":"avg", "threshold":0.1}
]
JSON
)

existing=$(kb "$KB_URL/api/alerting/rules/_find?per_page=100&search_fields=tags&search=$RULE_TAG" | jq -r '.data[] | [.name,.id] | @tsv')

echo "$RULES" | jq -c '.[]' | while read -r r; do
  name=$(jq -r .name <<<"$r")
  body=$(jq -nc --argjson r "$r" --arg dv "$DEMO_DATAVIEW_ID" --arg tag "$RULE_TAG" '{
    name: $r.name,
    rule_type_id: "observability.rules.custom_threshold",
    consumer: "alerts",
    enabled: true,
    schedule: {interval: "1m"},
    alert_delay: {active: 1},
    tags: [$tag, "cmdb-demo", $r.class],
    params: {
      criteria: [{
        comparator: ">",
        metrics: [{name: "A", field: $r.field, aggType: $r.agg}],
        threshold: [$r.threshold],
        timeSize: 2,
        timeUnit: "m"
      }],
      alertOnNoData: false,
      alertOnGroupDisappear: false,
      searchConfiguration: {
        query: {query: ("cmdb.ci.class: " + $r.class), language: "kuery"},
        index: $dv
      },
      groupBy: ["cmdb.ci.name"]
    },
    actions: []
  }')
  id=$(awk -F'\t' -v n="$name" '$1==n{print $2}' <<<"$existing" | head -1)
  if [[ -n "$id" ]]; then
    log "Updating  $name ($id)"
    kb -X PUT "$KB_URL/api/alerting/rule/$id" -d "$(jq -c 'del(.rule_type_id,.consumer,.enabled)' <<<"$body")" | jq -c '{id,name,enabled}'
  else
    log "Creating  $name"
    kb -X POST "$KB_URL/api/alerting/rule" -d "$body" | jq -c '{id,name,enabled,error,message}'
  fi
done
