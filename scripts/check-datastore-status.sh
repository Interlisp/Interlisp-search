#!/bin/bash
# File: scripts/check-datastore-status.sh

PROJECT_ID="interlispsearch"
# Proven primary website store; override with DATA_STORE_ID env var or $1.
DATA_STORE_ID="${DATA_STORE_ID:-${1:-interlisp-web-sites_1741606671710}}"
LOCATION="global"

TOKEN=$(gcloud auth application-default print-access-token)

curl -s -H "Authorization: Bearer $TOKEN" \
  -H "x-goog-user-project: $PROJECT_ID" \
  "https://discoveryengine.googleapis.com/v1/projects/$PROJECT_ID/locations/$LOCATION/collections/default_collection/dataStores/$DATA_STORE_ID/siteSearchEngine/targetSites" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
print('Data Store: ' + '$DATA_STORE_ID')
print('='*50)
if 'targetSites' in data:
    for site in data['targetSites']:
        # API returns generatedUriPattern (providedUriPattern is legacy/absent)
        print(f\"URI Pattern: {site.get('generatedUriPattern') or site.get('providedUriPattern')}\")
        print(f\"Status: {site.get('indexingStatus', 'UNKNOWN')}\")
        print(f\"Type: {site.get('type')}\")
        if site.get('failureReasons'):
            print(f\"Failures: {site['failureReasons']}\")
        print()
else:
    print('No target sites found')
    print(json.dumps(data, indent=2))
"