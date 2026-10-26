#!/usr/bin/env bash
# Generates demo telemetry for the CMDB CIs. Healthy CIs get normal values; CIs that are part of the
# chosen scenario get fault values that breach the rule thresholds created by 02_create_rules.sh,
# so Kibana raises real alerts (rule runs every 1m, window 2m -> alerts show up in ~1-2 minutes).
#
# Topology under test:  Microsoft IIS Server@pmtwinxl01 -> pmtwinxl01 -> hvhost01
#                       (+ a sibling VM chain on hvhost01 and one unrelated CI as a negative control)
#
# Scenarios
#   baseline             all CIs healthy (no alerts)
#   cascade --stage 1    hvhost01 datastore latency + pmtwinxl01 disk/CPU          -> 2 correlated alerts (new case)
#   cascade --stage 2    stage 1 + IIS@pmtwinxl01 slow / 5xx                       -> new alert joins the OPEN case
#   cascade --stage 3    stage 2 + tnatwinxl01 + IIS@tnatwinxl01 (sibling chain)   -> also joins (both chains hang off hvhost01)
#   unrelated            multimaster06 CPU/memory (no topology link)               -> its own separate case
#   healthy              alias of baseline (use it to let alerts recover)
#
# Usage: 03_generate_alerts.sh <scenario> [--stage N] [--duration 4m] [--no-live]
#   --duration  keep emitting live points every 15s for this long (default 4m) so the alerts stay active
#   --no-live   only backfill the last 2 minutes and exit
source "$(dirname "$0")/lib.sh"

SCENARIO="${1:-}"; shift || true
STAGE=1; DURATION=240; LIVE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage) STAGE="$2"; shift 2;;
    --duration) d="$2"; case "$d" in *m) DURATION=$(( ${d%m} * 60 ));; *s) DURATION=${d%s};; *) DURATION=$d;; esac; shift 2;;
    --no-live) LIVE=0; shift;;
    *) die "unknown arg $1";;
  esac
done
[[ -n "$SCENARIO" ]] || { sed -n '2,22p' "$0"; exit 1; }

# CI inventory: name | class
CIS='[
 {"name":"hvhost01","class":"hypervisor"},
 {"name":"pmtwinxl01","class":"server"},
 {"name":"Microsoft IIS Server@pmtwinxl01","class":"iis"},
 {"name":"tnatwinxl01","class":"server"},
 {"name":"Microsoft IIS Server@tnatwinxl01","class":"iis"},
 {"name":"multimaster06","class":"server"}
]'

# Fault overrides per scenario/stage: ci name -> metric overrides
case "$SCENARIO" in
  baseline|healthy) FAULTS='{}';;
  cascade)
    FAULTS='{"hvhost01":{"hypervisor.datastore_latency_ms":85,"hypervisor.cpu_ready.pct":0.14},
             "pmtwinxl01":{"host.disk.io_latency_ms":140,"host.cpu.pct":0.95}}'
    (( STAGE >= 2 )) && FAULTS=$(jq -c '. + {"Microsoft IIS Server@pmtwinxl01":{"iis.response_time_ms":4800,"iis.http_5xx":120}}' <<<"$FAULTS")
    (( STAGE >= 3 )) && FAULTS=$(jq -c '. + {"tnatwinxl01":{"host.disk.io_latency_ms":120},"Microsoft IIS Server@tnatwinxl01":{"iis.response_time_ms":3900}}' <<<"$FAULTS")
    ;;
  unrelated) FAULTS='{"multimaster06":{"host.cpu.pct":0.97,"host.memory.pct":0.96}}';;
  *) die "unknown scenario '$SCENARIO'";;
esac
log "Scenario=$SCENARIO stage=$STAGE faulty CIs: $(jq -r 'keys|join(", ")' <<<"${FAULTS:-{\}}")"

# Builds a _bulk body for the timestamps given as epoch seconds on stdin (one per line).
make_bulk() {
  jq -rcn --argjson cis "$CIS" --argjson faults "$FAULTS" --arg index "$DEMO_INDEX" '
    def jit($i; $k; $spread): ((($i * 12.9898 + $k * 78.233) | sin) * 43758.5453 | . - floor) * $spread * 2 - $spread;
    def healthy($class):
      if   $class == "iis"        then {"iis.response_time_ms":350, "iis.http_5xx":1}
      elif $class == "server"     then {"host.cpu.pct":0.35, "host.memory.pct":0.55, "host.disk.io_latency_ms":8}
      else                             {"hypervisor.datastore_latency_ms":6, "hypervisor.cpu_ready.pct":0.02} end;
    def unflat: reduce to_entries[] as $e ({}; setpath($e.key | split("."); $e.value));
    inputs | tonumber as $t
    | range(0; $cis | length) as $k | $cis[$k] as $ci
    | (healthy($ci.class) + ($faults[$ci.name] // {})) as $m
    | ($m | with_entries(.value |= (. * (1 + jit($t; $k; 0.05)))) | with_entries(.value |= (. * 10000 | round / 10000))) as $v
    | ($v | if has("iis.http_5xx") then .["iis.http_5xx"] |= round else . end | unflat) as $metrics
    | {index:{_index:$index}},
      ({"@timestamp": ($t | todate), cmdb:{ci:{name:$ci.name, class:$ci.class}}} + $metrics)
  ' -R
}

send() {
  resp=$(make_bulk | es -X POST "$ES_URL/_bulk?refresh=false" --data-binary @-)
  [[ "$(jq -r .errors <<<"$resp")" == "false" ]] || { echo "$resp" | head -c 800; die "bulk request failed"; }
}

now=$(date +%s)
log "Backfilling last 2 minutes (every 15s)"
for off in $(seq 120 -15 0); do echo $((now - off)); done | send

if (( LIVE )); then
  log "Emitting live points every 15s for ${DURATION}s (Ctrl-C to stop; alerts stay active while this runs)"
  end=$(( $(date +%s) + DURATION ))
  while (( $(date +%s) < end )); do
    sleep 15
    date +%s | send
    printf '.'
  done
  echo
fi
log "Done. Alerts appear in ~1-2 minutes: Observability > Alerts (filter tag: $RULE_TAG)."
