# CMDB topology alert correlation (Kibana Workflows)

Demo that turns a flood of per-CI Kibana alerts into **one case per incident**, using the ServiceNow CMDB topology
ingested into Elasticsearch:

```
Microsoft IIS Server@pmtwinxl01  ->  pmtwinxl01  ->  hvhost01
 (app, parent)                       (VM)             (hypervisor, child)
```

An alert on `hvhost01` and an alert on the IIS server end up in the same case, even if they fire minutes apart,
because they sit on the same dependency chain (max 5 hops upstream + 5 hops downstream).

This folder is the version for Elastic Cloud Serverless 9.6. The port for Elasticsearch / Kibana 9.4.0 is in
`../elasticsearch-9.4.0/`.

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
   (`workflows/build-or-refresh-servicenow-cmdb-ci-rel-lookup.yaml`) runs every day and on demand. It reads
   **`servicenow-cmdb-cis`**: builds an enrich policy `sys_id -> name`, runs it, and rebuilds the lookup index
   **`servicenow-cmdb-ci-rel-lookup`** by reindexing the relationship records through an ingest pipeline that replaces
   sys_ids with CI names.
3. **Alert correlation every 5 minutes.** The workflow **`cmdb-alert-correlation`** (`workflows/cmdb-alert-correlation.yaml`,
   described in "How the workflow works") looks for un-acknowledged alerts, looks the alerting CIs up in
   `servicenow-cmdb-ci-rel-lookup`, walks the topology, groups related alerts into one case, has the LLM write the case text
   (alert titles/descriptions when no connector is configured) and acknowledges the alerts it processed.

| Piece | File |
|---|---|
| ServiceNow connector (step 1) | configured in Kibana > Search > Connectors, not part of this repo |
| Daily lookup refresh workflow (step 2) | `workflows/build-or-refresh-servicenow-cmdb-ci-rel-lookup.yaml` (create/update it in Kibana > Workflows; workflow name = file name) |
| Demo telemetry index + data view | `scripts/01_setup_telemetry.sh` |
| 7 Kibana alert rules (one alert per CI) | `scripts/02_create_rules.sh` |
| Fault injection (scenarios / stages) | `scripts/03_generate_alerts.sh` |
| **Correlation workflow** (every 5 min) | `workflows/cmdb-alert-correlation.yaml`, deployed by `scripts/04_deploy_workflow.sh` |
| Reset / replay the demo | `scripts/05_reset_demo.sh` |
| Show cases + alert→case mapping | `scripts/show_cases.sh` |
| Remove everything | `scripts/99_cleanup.sh` |

Everything was built and verified against Elastic Cloud Serverless 9.6 (Workflows, `cases.*` and `ai.prompt` steps).

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
  holds names); it is the source the daily lookup workflow builds from.

## Quick start

Prerequisite: the ServiceNow connector is running and `servicenow-cmdb-cis` is populated, and the
`build-or-refresh-servicenow-cmdb-ci-rel-lookup` workflow has run at least once (Kibana > Workflows > Run) so that
`servicenow-cmdb-ci-rel-lookup` exists.

```bash
cp .env.example .env        # fill ES_URL, KB_URL, ES_API_KEY (an .env for this project already exists locally)
bash scripts/01_setup_telemetry.sh
bash scripts/02_create_rules.sh
bash scripts/04_deploy_workflow.sh          # optional: AI_CONNECTOR_ID=<connector id> to pin the LLM
```

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

Trigger: `scheduled every 5m` (+ manual). Concurrency is `queue, max 1`, so a manual run never overlaps the scheduled one.

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
   the `ci:` tag and the topology comment. The LLM answers in a plain `TITLE: / SEVERITY: / DESCRIPTION:` format that is parsed
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
  outputs.

## Cleanup

`bash scripts/99_cleanup.sh` removes rules, workflow, data view, telemetry index, cases and demo alerts.
