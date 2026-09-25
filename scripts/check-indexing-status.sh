#!/bin/bash
# File: check-indexing-status.sh

PROJECT_ID="interlispsearch"
DATA_STORE_ID="interlisp-search-unified"
LOCATION="global"

TOKEN=$(gcloud auth application-default print-access-token)

echo "Checking indexing status for $DATA_STORE_ID..."
echo ""

curl -s -H "Authorization: Bearer $TOKEN" \
  -H "x-goog-user-project: $PROJECT_ID" \
  "https://discoveryengine.googleapis.com/v1/projects/$PROJECT_ID/locations/$LOCATION/collections/default_collection/dataStores/$DATA_STORE_ID/siteSearchEngine/targetSites" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'targetSites' in data:
    for site in data['targetSites']:
        print(f\"URI Pattern: {site.get('providedUriPattern')}\")
        print(f\"Status: {site.get('indexingStatus', 'UNKNOWN')}\")
        print(f\"Type: {site.get('type')}\")
        print()
else:
    print('No target sites found')
    print(json.dumps(data, indent=2))
"
