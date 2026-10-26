# CMDB topology alert correlation (Kibana Workflows)

Demo that turns a flood of per-CI Kibana alerts into **one case per incident**, using the ServiceNow CMDB topology
ingested into Elasticsearch:

```
Microsoft IIS Server@pmtwinxl01  ->  pmtwinxl01  ->  hvhost01
 (app, parent)                       (VM)             (hypervisor, child)
```

An alert on `hvhost01` and an alert on the IIS server end up in the same case, even if they fire minutes apart,
because they sit on the same dependency chain (max 5 hops upstream + 5 hops downstream).

## How the pieces are used together

```
ServiceNow ──(1) ServiceNow connector──▶ servicenow-cmdb-cis ──(2) daily workflow──▶ servicenow-cmdb-ci-rel-lookup
                                                                                              │ topology (names)
Kibana alert rules ──▶ alerts (.alerts-*) ──(3) cmdb-alert-correlation, every 5 min───────────┴──▶ Cases
```

1. **ServiceNow connector (must be running).** The [ServiceNow connector](https://www.elastic.co/docs/reference/search-connectors/es-connectors-servicenow)
   continuously syncs ServiceNow data into the index **`servicenow-cmdb-cis`**. The next step needs that index to hold both the
   CI records (`sys_id`, `name`) and the CI relationship records (`sys_id`, `parent.value`, `child.value`, `type.value`).
2. **Daily lookup refresh.** The workflow **`build-or-refresh-servicenow-cmdb-ci-rel-lookup`**
   (`workflows/build-or-refresh-servicenow-cmdb-ci-rel-lookup.yaml`) runs every day at 02:00 UTC (and on demand). It reads
   **`servicenow-cmdb-cis`**: builds an enrich policy `sys_id -> name`, runs it, and rebuilds the lookup index
   **`servicenow-cmdb-ci-rel-lookup`** by reindexing the relationship records through an ingest pipeline that replaces
   sys_ids with CI names.
3. **Alert correlation every 5 minutes.** The workflow **`cmdb-alert-correlation`** (`workflows/cmdb-alert-correlation.yaml`,
   described in "How the workflow works") looks for un-acknowledged alerts, looks the alerting CIs up in
   `servicenow-cmdb-ci-rel-lookup`, walks the topology, groups related alerts into one case, has the LLM write the case text
   (alert titles/descriptions when no connector is configured) and acknowledges the alerts it processed.

For a demo without a live ServiceNow, `scripts/00_load_cmdb_data.sh` loads a small relationship subset straight into
`servicenow-cmdb-ci-rel-lookup` (step 1 and 2 are skipped; note that running the daily refresh workflow replaces that index).

| Piece | File |
|---|---|
| ServiceNow connector (step 1) | configured in Kibana > Search > Connectors, not part of this repo |
| **Daily lookup refresh workflow** (step 2) | `workflows/build-or-refresh-servicenow-cmdb-ci-rel-lookup.yaml` (deploy it in Kibana > Workflows, or `PUT /api/workflows/workflow/<id>`) |
| CMDB relationship lookup index, demo stand-in (optional - only in case of absence of Servicenow) | `scripts/00_load_cmdb_data.sh`, `data/cmdb-ci-rel-lookup.ndjson` |
| Demo telemetry index + data view | `scripts/01_setup_telemetry.sh` |
| 7 Kibana alert rules (one alert per CI) | `scripts/02_create_rules.sh` |
| Fault injection (scenarios / stages) | `scripts/03_generate_alerts.sh` |
| **Correlation workflow** (every 5 min) | `workflows/cmdb-alert-correlation.yaml`, deployed by `scripts/04_deploy_workflow.sh` |
| Reset / replay the demo | `scripts/05_reset_demo.sh` |
| Show cases + alert→case mapping | `scripts/show_cases.sh` |
| Remove everything | `scripts/99_cleanup.sh` |

**This folder is the port for Elasticsearch / Kibana 9.4.0 (Elastic Cloud Hosted, fresh cluster).** The original version for
Elastic Cloud Serverless 9.6 lives in `../elasticsearch-serverless-9.6/`. Verified end to end on 9.4.0: all four demo steps
produce the expected cases (see "Differences from the Serverless 9.6 version").

## Differences from the Serverless 9.6 version

| Area | Serverless 9.6 | 9.4.0 (this folder) |
|---|---|---|
| CMDB data | the connector and the daily lookup workflow are already running in the project | fresh cluster: run the connector + daily workflow (above), or use **`scripts/00_load_cmdb_data.sh`**, which creates `servicenow-cmdb-ci-rel-lookup` (lookup-mode index) and loads `data/cmdb-ci-rel-lookup.ndjson`, the 5-hop neighbourhood of the six demo CIs (31 of the 49k original edges) |
| Lookup refresh workflow | `build-or-refresh-servicenow-cmdb-ci-rel-lookup` | same workflow (same name and file name in both folders); the copy here replaces the `elasticsearch.indices.exists` + `output.result` condition (9.4.0 returns a bare boolean) by an unconditional `DELETE` with `on-failure: continue` |
| Workflow `settings.concurrency` | `strategy: queue`, `queue-size`, `queue-ttl` | 9.4.0 rejects `queue`; uses `strategy: drop`, `max: 1` (an overlapping run is dropped, the next 5m tick picks up the work) |
| Hop bookkeeping in the `while` loops | one `data.set` with `concat: (x \| map: 'key')` | 9.4.0 fails validation on parenthesised filter arguments; the frontier is stored first (`advance_*_frontier`) and then appended as a plain variable |
| Deleting the workflow | `DELETE /api/workflows/workflow/<id>` | that call returns 200 without deleting; `99_cleanup.sh` uses the bulk `DELETE /api/workflows` with `{"ids":[...]}` |
| Credentials | `.env` | `.env`, or point `ENV_FILE=/path/to/file` at any file with `ES_URL`, `KB_URL`, `ES_API_KEY` |
| LLM | project default connector | works with the default connector on a fresh 9.4.0 Cloud deployment (preconfigured Elastic Inference Service connectors); pin one with `AI_CONNECTOR_ID` |

## Data model the workflow relies on

* `servicenow-cmdb-ci-rel-lookup` (lookup index): one doc per relationship, `parent.value` -> `child.value`,
  `relationship.type`. It is rebuilt daily by the `build-or-refresh-servicenow-cmdb-ci-rel-lookup` workflow from the
  connector-fed `servicenow-cmdb-cis` index, which resolves sys_ids to CI **names** through an enrich policy. Edges whose CI
  could not be resolved keep the raw 32-char sys_id; the traversal walks through them (they still count as a hop) but they
  are hidden from the AI prompt.
* Direction: parent **runs on / depends on** child. *Upstream* of a CI = its parents (impacted services), *downstream* =
  its children (infrastructure, usual root cause). The walk is directional and visited-set protected (the data contains
  cycles/self-edges), so two sibling VMs on the same hypervisor are **not** related to each other directly, only via the
  hypervisor. If the hypervisor alerts too, all of them join its case.
* `Decommissioned` is a child of hundreds of unrelated CIs; it is listed in `consts.ignore_cis` and never traversed.
* `servicenow-cmdb-cis` (filled by the ServiceNow connector) is not read by `cmdb-alert-correlation` (the lookup already
  holds names); it is the source the daily lookup workflow builds from (`consts.source_index` at the top of
  `build-or-refresh-servicenow-cmdb-ci-rel-lookup.yaml`). The enrich policy is created once and then reused, so if you change
  `source_index` on a cluster where the policy `servicenow-ci-name-policy` already exists, delete that policy first.
  The source must contain relationship records as well as CI records, otherwise the refresh rebuilds an empty lookup.

## Quick start

Prerequisite: the ServiceNow connector is running and `servicenow-cmdb-cis` is populated, and the
`build-or-refresh-servicenow-cmdb-ci-rel-lookup` workflow has run at least once (Kibana > Workflows > Run) so that
`servicenow-cmdb-ci-rel-lookup` exists. Without ServiceNow, use `00_load_cmdb_data.sh` below instead.

```bash
cp .env.example .env        # fill ES_URL, KB_URL, ES_API_KEY for the 9.4.0 deployment
bash scripts/00_load_cmdb_data.sh           # demo without ServiceNow only: load the CMDB relationship subset into the lookup index
bash scripts/01_setup_telemetry.sh
bash scripts/02_create_rules.sh
bash scripts/04_deploy_workflow.sh          # optional: AI_CONNECTOR_ID=<connector id> to pin the LLM
```

For `https://` endpoints with a self-signed or private-CA certificate, prefix any script with `INSECURE=1` (curl `-k`, TLS
verification off; trusted networks only). `http://` URLs work as they are, but the API key then travels unencrypted.

Needs `bash`, `curl`, `jq`. The API key must be allowed to manage rules, cases, data views and workflows in Kibana and to
read/write the indices used here.

### Demo script

Run each step, then either wait for the next 5-minute workflow run or start it by hand
(Kibana > Workflows > *cmdb-alert-correlation* > Run). Alerts need ~1-2 minutes after the data appears
(rules run every minute over a 2-minute window). Keep `03_generate_alerts.sh` running while you watch; it emits a point
every 15 s for `--duration` (default 4m).

| # | Command | Expected result of the next workflow run |
|---|---|---|
| 1 | `scripts/03_generate_alerts.sh cascade --stage 1` | hvhost01 datastore latency / CPU ready + pmtwinxl01 disk I/O / CPU alerts -> **new case** (AI title + description), 4 alerts attached and acknowledged |
| 2 | `scripts/03_generate_alerts.sh cascade --stage 2` | IIS response time / 5xx alerts arrive later -> **attached to the same open case**, title + description regenerated, comment explaining the topology relation |
| 3 | `scripts/03_generate_alerts.sh cascade --stage 3` | sibling VM `tnatwinxl01` and its IIS alert (also hanging off hvhost01) join the same case |
| 4 | `scripts/03_generate_alerts.sh unrelated` | `multimaster06` (no topology link) gets its **own** case |

`bash scripts/show_cases.sh` prints the cases and which case each alert belongs to. Replay with `scripts/05_reset_demo.sh`
(it waits ~4 minutes for active alerts to recover, see "Behaviours worth knowing").

## How the workflow works

Trigger: `scheduled every 5m` (+ manual). Concurrency is `drop, max 1` on 9.4.0 (`queue, max 1` on Serverless 9.6), so a manual run never overlaps the scheduled one.

1. **Find un-acknowledged alerts**: `.alerts-*` where `kibana.alert.workflow_status = open`, rule tag
   `cmdb-ci-correlation`, last 24 h. Grouped by `kibana.alert.instance.id` (= CI name, because the rules group by
   `cmdb.ci.name`), oldest first.
2. **For each CI, sequentially** (so the case created for the first CI is visible to the next one in the same run, which makes
   "same run" and "later run" behave identically):
   1. BFS **upstream** (`child.value -> parent.value`) up to 5 hops, then BFS **downstream** (`parent.value -> child.value`)
      up to 5 hops, using `while` loops with one terms-aggregation query per hop. Cycles are cut by a visited list.
   2. Look for alerts of the same rule set on any CI in that neighbourhood (incl. the CI itself) that are attached to a case
      (`kibana.alert.case_ids`). Candidate cases are fetched with `cases.getCases` and filtered to `open` / `in-progress`
      (closed cases are never reused). If several match, the oldest wins and the comment cross-references the others.
   3. **Open case found** -> attach only the not-yet-attached alerts (`cases.addAlerts`), ask the LLM (`ai.prompt`) for an
      updated title / description / severity using the case text, all alerts in the case, the new alerts and the topology
      evidence, update the case, add a `ci:<name>` tag and a comment such as
      `hvhost01: 2 hop(s) downstream of Microsoft IIS Server@pmtwinxl01`.
   4. **No open case** -> ask the LLM for title / description / severity, `cases.createCase`, attach the alerts.
   5. **Acknowledge** exactly the processed alert ids (`_update_by_query` by `_id`, `workflow_status = acknowledged`).
3. If the LLM call fails (after 1 retry), e.g. because no LLM connector is configured, the run still completes without AI:
   a new case takes its **title from the rule name of the CI's oldest alert** and its **description from the alerts' rule
   names + reasons** (severity `medium`); an existing case keeps its current title/description, still gets the new alerts,
   the `ci:` tag and the topology comment. Tested by pinning `AI_CONNECTOR_ID=does-not-exist`. The LLM answers in a plain `TITLE: / SEVERITY: / DESCRIPTION:` format that is parsed
   with Liquid, because strict JSON-schema output failed intermittently with the project's default model.

Tunables (top of the YAML): `case_owner`, `rule_tag`, `alert_lookback`, `lookup_index`, `ignore_cis`. The hop limits are
`5` in the two `while` conditions (KQL cannot read `consts`; keep `max_hops_*` in sync if you change them).
Case `syncAlerts` is `false` on purpose, otherwise attaching an alert would reset its acknowledged status to the case status.

### Using your real alerts instead of the demo rules

The workflow only needs two things from an alert: the rule has the tag `cmdb-ci-correlation` and
`kibana.alert.instance.id` is the CI name as it appears in the CMDB lookup (group the rule by one field holding the CI name).
For multi-field groupings, change the `kibana.alert.instance.id` references (3 places) to the field you use.

## Behaviours worth knowing

* **Active alerts keep their workflow status.** An alert that is still active is re-used by the rule on every run, so once
  acknowledged it stays acknowledged; a new alert for the same rule + CI only appears after it recovered. Recovered alerts
  that are still `open` are correlated too.
* **Case merging is not implemented.** If a CI is related to two different open cases (e.g. a hypervisor alert arrives after
  two VM cases were opened) the alert joins the oldest case and a comment points at the other.
* Alerts are matched to cases through `kibana.alert.case_ids`; if you delete a case manually the stale ids on the alerts are
  ignored (closed / missing cases are filtered out).
* Per-hop expansion is capped at 1000 CIs. Hub CIs (thousands of dependants) would need a higher cap or tighter `ignore_cis`.
* The case owner is `observability`, matching the custom-threshold rules (`consumer: alerts`).

## Troubleshooting

* Workflow shows `valid: false` after deploy: `POST /api/workflows/test` returns the validation errors
  (`{"workflowYaml": "...", "inputs": {}}`) — note that it also *runs* the workflow when the YAML is valid.
* Steps / outputs of a run: `GET /api/workflows/executions/<id>/steps` and `/api/workflows/executions/<id>/step/<stepExecutionId>`.
* Nothing correlates: check the alert really has the tag and that `kibana.alert.instance.id` equals a `parent.value` /
  `child.value` in `servicenow-cmdb-ci-rel-lookup`.
* Lookup index missing or empty: check the connector sync status and that `servicenow-cmdb-cis` has relationship records
  (`parent.value`, `child.value`), then run `build-or-refresh-servicenow-cmdb-ci-rel-lookup` manually and read its step
  outputs. The workflow deletes the lookup index before reindexing, so a source without relationship records leaves it empty.

## Cleanup

`bash scripts/99_cleanup.sh` removes rules, workflow, data view, telemetry index, cases and demo alerts.
