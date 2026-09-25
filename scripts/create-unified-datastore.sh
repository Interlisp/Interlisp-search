#!/bin/bash
# File: create-unified-datastore.sh

PROJECT_ID="interlispsearch"
DATA_STORE_ID="interlisp-search-unified"
DISPLAY_NAME="Interlisp Unified Search"
LOCATION="global"

TOKEN=$(gcloud auth application-default print-access-token)

# Create data store
echo "Creating unified data store: $DATA_STORE_ID"

curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "x-goog-user-project: $PROJECT_ID" \
  "https://discoveryengine.googleapis.com/v1/projects/$PROJECT_ID/locations/$LOCATION/collections/default_collection/dataStores?dataStoreId=$DATA_STORE_ID" \
  -d '{
    "displayName": "'"$DISPLAY_NAME"'",
    "industryVertical": "GENERIC",
    "solutionTypes": ["SOLUTION_TYPE_SEARCH"],
    "contentConfig": "PUBLIC_WEBSITE"
  }'

echo ""
echo "Data store creation initiated. Checking status..."
sleep 5

# Verify creation
curl -s -H "Authorization: Bearer $TOKEN" \
  -H "x-goog-user-project: $PROJECT_ID" \
  "https://discoveryengine.googleapis.com/v1/projects/$PROJECT_ID/locations/$LOCATION/collections/default_collection/dataStores/$DATA_STORE_ID" \
  | python3 -m json.tool
