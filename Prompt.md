ES_URL = https://rkm-1-b51f14.es.asia-south1.gcp.elastic.cloud
ES_API_KEY = YW81U3Jwd0J2SGxjWVZTYnRxdXc6QVlLLWlXaDQ5MFRHOWdIbGFOS1R0Zw==

Help me with the below demo scenario:

1. servicenow-cmdb-cis index has servicenow cmdb data. servicenow-cmdb-ci-rel-lookup index has parent ci name - relationship - child CI name details
2. These indices have this sample topology : Microsoft IIS Server@pmtwinxl01 → pmtwinxl01 → hvhost01
3. Help me with the scripts to generate some meaningful Kibana alerts for these CIs
4. Help me with an elasticsearch workflow that runs every 5 mins, loops through all un-acknowledged alerts, correlates alerts based on topology information in servicenow-cmdb-ci-rel-lookup index, create a case, attach the correlated alerts to the case, generate case title and case description using AI and acknowledges the correlated alerts.
5. If a new alert comes during next workflow run which can be correlated to the alerts that are attached to an existing open case, attach the new alert to the existing case, instead of creating a new case, generate an updated case title and description using AI, and acknowledge that new alert.
6. While going through the topology for correlation, consider a max of 5 hops upstream and 5 hops downstream.