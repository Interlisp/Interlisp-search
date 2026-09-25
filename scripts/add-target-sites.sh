#!/bin/bash
# File: add-target-sites.sh

PROJECT_ID="interlispsearch"
DATA_STORE_ID="interlisp-search-unified"
LOCATION="global"

TOKEN=$(gcloud auth application-default print-access-token)

# Target Site 1: interlisp.org
echo "Adding target site: interlisp.org/*"
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "x-goog-user-project: $PROJECT_ID" \
  "https://discoveryengine.googleapis.com/v1/projects/$PROJECT_ID/locations/$LOCATION/collections/default_collection/dataStores/$DATA_STORE_ID/siteSearchEngine/targetSites" \
  -d '{
    "providedUriPattern": "interlisp.org/*",
    "type": "INCLUDE",
    "exactMatch": false
  }'

echo ""
sleep 2

# Target Site 2: files.interlisp.org
echo "Adding target site: files.interlisp.org/*"
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "x-goog-user-project: $PROJECT_ID" \
  "https://discoveryengine.googleapis.com/v1/projects/$PROJECT_ID/locations/$LOCATION/collections/default_collection/dataStores/$DATA_STORE_ID/siteSearchEngine/targetSites" \
  -d '{
    "providedUriPattern": "files.interlisp.org/*",
    "type": "INCLUDE",
    "exactMatch": false
  }'

echo ""
echo "Target sites added. Verifying..."
sleep 3

curl -s -H "Authorization: Bearer $TOKEN" \
  -H "x-goog-user-project: $PROJECT_ID" \
  "https://discoveryengine.googleapis.com/v1/projects/$PROJECT_ID/locations/$LOCATION/collections/default_collection/dataStores/$DATA_STORE_ID/siteSearchEngine/targetSites" \
  | python3 -m json.tool
