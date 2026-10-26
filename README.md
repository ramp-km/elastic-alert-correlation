# elastic-alert-correlation

CMDB topology alert correlation with Kibana Workflows, in two versions:

| Folder | Target | Notes |
|---|---|---|
| [`elasticsearch-serverless-9.6/`](elasticsearch-serverless-9.6/README.md) | Elastic Cloud Serverless 9.6 | original; reads the CMDB lookup maintained by `ntt-servicenow-ci-lookup-sync` |
| [`elasticsearch-9.4.0/`](elasticsearch-9.4.0/README.md) | Elasticsearch / Kibana 9.4.0 (Cloud Hosted) | port for a fresh cluster: adds CMDB data loader, workflow adjusted to the 9.4.0 workflow engine |

Each folder is self-contained (own `scripts/`, `workflows/`, `.env`). Start with the README inside the folder.
