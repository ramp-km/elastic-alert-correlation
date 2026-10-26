#!/usr/bin/env bash
# Prints the correlation cases (title, severity, tags, attached alerts) - handy while demoing.
source "$(dirname "$0")/lib.sh"
kb "$KB_URL/api/cases/_find?tags=cmdb-correlation&perPage=50&sortField=createdAt&sortOrder=asc" | jq -r '.cases[] | "\n== \(.id)  [\(.status)/\(.severity)]  alerts=\(.totalAlerts) comments=\(.totalComment)\n   \(.title)\n   tags: \(.tags|join(", "))"'
echo
es "$ES_URL/.alerts-*/_search" -d "$(jq -nc --arg t "$RULE_TAG" '{size:100,sort:[{"kibana.alert.start":"asc"}],query:{term:{"kibana.alert.rule.tags":$t}},_source:["kibana.alert.instance.id","kibana.alert.rule.name","kibana.alert.status","kibana.alert.workflow_status","kibana.alert.case_ids"]}')" \
 | jq -r '.hits.hits[]._source | "  \(.["kibana.alert.instance.id"] | .[0:34] | . + " " * (34 - length))  \(.["kibana.alert.rule.name"] | . + " " * (42 - length))  \(.["kibana.alert.status"] | . + " " * (9 - length)) \(.["kibana.alert.workflow_status"] | . + " " * (13 - length)) case=\((.["kibana.alert.case_ids"] // []) | map(.[0:8]) | join(","))"'
