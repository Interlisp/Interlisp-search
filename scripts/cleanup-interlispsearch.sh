#!/bin/bash
# File: scripts/cleanup-interlispsearch.sh — DESTRUCTIVE. Run only after inventory review.
set -e
PROJECT_ID="interlispsearch"
LOCATION="global"
REGION="us-central1"
TOKEN=$(gcloud auth application-default print-access-token)

# KEEP — edit if your unified engine ID differs
KEEP_DATASTORE="interlisp-search-unified"

# --- 1. Engines first (depend on data stores) ---
echo "=== 1. Deleting stale engines (keeping only *$KEEP_DATASTORE*) ==="
ENGINES_JSON=$(curl -s -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $PROJECT_ID" \
  "https://discoveryengine.googleapis.com/v1/projects/$PROJECT_ID/locations/$LOCATION/collections/default_collection/engines?pageSize=100")
echo "Review engines, then uncomment the DELETE lines per engine."
# Preferred: iterate with jq/python in a loop:
# For each engine where dataStoreIds != ["interlisp-search-unified"]:
curl -s -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $PROJECT_ID" \
  "https://discoveryengine.googleapis.com/v1/projects/$PROJECT_ID/locations/$LOCATION/collections/default_collection/engines" \
  | python3 -c "
import json, subprocess, shlex, sys
data=json.load(sys.stdin)
for e in data.get('engines',[]):
    name=e['name']
    ds_ids=e.get('dataStoreIds',[])
    eng_id=name.split('/')[-1]
    if ds_ids != ['interlisp-search-unified']:
        print(f'DELETE engine {eng_id} (dataStoreIds={ds_ids})')
        # Uncomment to actually delete:
        # subprocess.run(['curl','-X','DELETE','-H',f'Authorization: Bearer {TOKEN}','-H',f'x-goog-user-project: {PROJECT_ID}',f'https://discoveryengine.googleapis.com/v1/{name}'], check=False)
    else:
        print(f'KEEP   engine {eng_id}')
"

# --- 2. Data stores second (cascades to documents/targetSites) ---
echo ""
echo "=== 2. Deleting stale data stores (keeping $KEEP_DATASTORE) ==="
curl -s -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $PROJECT_ID" \
  "https://discoveryengine.googleapis.com/v1/projects/$PROJECT_ID/locations/$LOCATION/collections/default_collection/dataStores" \
  | python3 -c "
import json, sys
data=json.load(sys.stdin)
for ds in data.get('dataStores',[]):
    ds_id=ds['name'].split('/')[-1]
    if ds_id != 'interlisp-search-unified':
        print(f'DELETE dataStore {ds_id} ({ds.get(\"displayName\",\"\")})')
        # Uncomment to actually delete:
        # import subprocess, os
        # subprocess.run(['curl','-X','DELETE','-H',f'Authorization: Bearer {os.environ[\"TOKEN\"]}','-H','x-goog-user-project: interlispsearch',f'https://discoveryengine.googleapis.com/v1/projects/interlispsearch/locations/global/collections/default_collection/dataStores/{ds_id}'])
    else:
        print(f'KEEP   dataStore {ds_id}')
"
# Actual delete command for one data store (run after review):
# curl -X DELETE -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $PROJECT_ID" \
#   "https://discoveryengine.googleapis.com/v1/projects/$PROJECT_ID/locations/$LOCATION/collections/default_collection/dataStores/interlisp-search-v3"
# curl -X DELETE -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $PROJECT_ID" \
#   "https://discoveryengine.googleapis.com/v1/projects/$PROJECT_ID/locations/$LOCATION/collections/default_collection/dataStores/interlisp-org-search_1768860477660"

# --- 3. Cloud Functions third (not in keep list) ---
echo ""
echo "=== 3. Stale Cloud Functions (review then delete) ==="
gcloud functions list --gen2 --region=$REGION --project=$PROJECT_ID --format="value(name)" 2>/dev/null | while read f; do
  base=$(basename "$f")
  case "$base" in search|trigger-website-recrawl|github-reimport) echo "KEEP   function $base" ;; *) echo "DELETE function $base — run: gcloud functions delete $base --gen2 --region=$REGION --project=$PROJECT_ID" ;; esac
done

# --- 4. Scheduler fourth ---
echo ""
echo "=== 4. Stale Scheduler jobs ==="
gcloud scheduler jobs list --location=$REGION --project=$PROJECT_ID --format="value(name)" 2>/dev/null | while read j; do
  base=$(basename "$j")
  case "$base" in recrawl-website-daily|reimport-github-weekly) echo "KEEP   scheduler $base" ;; *) echo "DELETE scheduler $base — run: gcloud scheduler jobs delete $base --location=$REGION --project=$PROJECT_ID" ;; esac
done

# --- 5. Storage fifth (prune old JSONL only) ---
echo ""
echo "=== 5. Storage — prune old import artifacts (keep bucket) ==="
echo "List: gcloud storage ls gs://interlispsearch-search-imports/ 2>/dev/null || gsutil ls gs://interlispsearch-search-imports/"
echo "Prune older than last successful import:"
echo "  gcloud storage rm gs://interlispsearch-search-imports/github-import-*.jsonl --project=$PROJECT_ID  # add --dry-run first if supported"
echo "  (Do NOT delete the bucket itself)"

# --- 6. Firestore sixth ---
echo ""
echo "=== 6. Firestore — TTL handles rate_limits; delete only ad-hoc test collections via console ==="

# --- 7. IAM last (do not delete SA) ---
echo ""
echo "=== 7. IAM — do NOT delete vertex-search-sa; only delete unused keys: gcloud iam service-accounts keys list --iam-account=vertex-search-sa@interlispsearch.iam.gserviceaccount.com --project=$PROJECT_ID ==="