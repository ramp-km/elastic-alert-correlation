#!/usr/bin/env bash
# Creates the demo telemetry index + Kibana data view the alert rules run against.
source "$(dirname "$0")/lib.sh"

log "Creating index $DEMO_INDEX (idempotent)"
code=$(es -o /dev/null -w '%{http_code}' -I "$ES_URL/$DEMO_INDEX")
if [[ "$code" == "200" ]]; then
  echo "    index already exists"
else
  es -X PUT "$ES_URL/$DEMO_INDEX" -d '{
    "mappings": {
      "properties": {
        "@timestamp": {"type": "date"},
        "cmdb": {"properties": {"ci": {"properties": {
          "name":   {"type": "keyword"},
          "class":  {"type": "keyword"},
          "sys_id": {"type": "keyword"}
        }}}},
        "iis":        {"properties": {"response_time_ms": {"type": "float"}, "http_5xx": {"type": "long"}}},
        "host":       {"properties": {"cpu": {"properties": {"pct": {"type": "float"}}},
                                      "memory": {"properties": {"pct": {"type": "float"}}},
                                      "disk": {"properties": {"io_latency_ms": {"type": "float"}}}}},
        "hypervisor": {"properties": {"datastore_latency_ms": {"type": "float"}, "cpu_ready": {"properties": {"pct": {"type": "float"}}}}}
      }
    }
  }' | jq -c .
fi

log "Creating data view $DEMO_DATAVIEW_ID"
kb -X POST "$KB_URL/api/data_views/data_view" -d "$(jq -nc --arg id "$DEMO_DATAVIEW_ID" --arg t "$DEMO_INDEX" \
  '{override:true, data_view:{id:$id, title:$t, name:$t, timeFieldName:"@timestamp"}}')" | jq -c '{id:.data_view.id, title:.data_view.title}'
