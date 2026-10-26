#!/usr/bin/env bash
# Loads the ServiceNow CMDB relationship data the correlation workflow walks (fresh clusters only).
#
# On the original (serverless) project this lookup index is maintained by the ntt-servicenow-ci-lookup-sync workflow.
# A fresh cluster has no ServiceNow data, so this script creates the lookup index (same mapping, index.mode=lookup)
# and bulk-loads data/cmdb-ci-rel-lookup.ndjson: the full 5-hop up/down neighbourhood of the six demo CIs
# (31 of the 49k original edges), including sibling VMs on hvhost01, unresolved sys_id edges and a self-edge.
source "$(dirname "$0")/lib.sh"

LOOKUP_INDEX="servicenow-cmdb-ci-rel-lookup"
DATA="$ROOT_DIR/data/cmdb-ci-rel-lookup.ndjson"

log "Creating lookup index $LOOKUP_INDEX (idempotent)"
code=$(es -o /dev/null -w '%{http_code}' -X HEAD "$ES_URL/$LOOKUP_INDEX")
if [[ "$code" == "200" ]]; then
  echo "    index already exists"
else
  es -X PUT "$ES_URL/$LOOKUP_INDEX" -d '{
    "settings": {"index": {"mode": "lookup"}},
    "mappings": {
      "dynamic": false,
      "properties": {
        "sys_id":       {"type": "keyword"},
        "parent":       {"properties": {"value": {"type": "keyword"}}},
        "child":        {"properties": {"value": {"type": "keyword"}}},
        "relationship": {"properties": {"type": {"type": "keyword"}}}
      }
    }
  }' | jq -c .
fi

log "Bulk loading $(wc -l < "$DATA" | tr -d ' ') relationship docs (_id = sys_id, so re-runs are idempotent)"
resp=$(jq -c '{index:{_index:"'"$LOOKUP_INDEX"'",_id:.sys_id}}, .' "$DATA" | es -X POST "$ES_URL/_bulk?refresh=wait_for" --data-binary @-)
[[ "$(jq -r .errors <<<"$resp")" == "false" ]] || { echo "$resp" | head -c 800; die "bulk load failed"; }
echo "    loaded; docs in index: $(es "$ES_URL/$LOOKUP_INDEX/_count" | jq -r .count)"
