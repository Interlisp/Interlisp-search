#!/bin/bash
# File: scripts/inventory-interlispsearch.sh — run BEFORE any deletes
set -e
PROJECT_ID="interlispsearch"
LOCATION="global"
REGION="us-central1"
OUTDIR="/tmp/interlispsearch-inventory-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTDIR"
TOKEN=$(gcloud auth application-default print-access-token)

echo "Inventory -> $OUTDIR"

# 1. Data stores (REST — no gcloud CLI)
curl -s -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $PROJECT_ID" \
  "https://discoveryengine.googleapis.com/v1/projects/$PROJECT_ID/locations/$LOCATION/collections/default_collection/dataStores?pageSize=100" \
  | python3 -m json.tool > "$OUTDIR/datastores.json"
echo "dataStores -> $OUTDIR/datastores.json"
cat "$OUTDIR/datastores.json" | python3 -c "import json; d=json.load(open('$OUTDIR/datastores.json')); print(f\"  {len(d.get('dataStores',[]))} data stores\")"

# 2. Engines / search apps
curl -s -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $PROJECT_ID" \
  "https://discoveryengine.googleapis.com/v1/projects/$PROJECT_ID/locations/$LOCATION/collections/default_collection/engines?pageSize=100" \
  | python3 -m json.tool > "$OUTDIR/engines.json"
cat "$OUTDIR/engines.json" | python3 -c "import json; d=json.load(open('$OUTDIR/engines.json')); print(f\"  {len(d.get('engines',[]))} engines\")"

# 3. Target sites for each data store (helps decide what to keep)
python3 -c "
import json
d=json.load(open('$OUTDIR/datastores.json'))
for ds in d.get('dataStores',[]):
    print(ds['name'].split('/')[-1], '—', ds.get('displayName',''))
" > "$OUTDIR/datastore-names.txt"
cat "$OUTDIR/datastore-names.txt"

# 4. Cloud Functions
gcloud functions list --gen2 --region=$REGION --project=$PROJECT_ID --format=json > "$OUTDIR/functions.json" 2>&1 || true
python3 -c "import json; d=json.load(open('$OUTDIR/functions.json')); print(f\"  {len(d)} functions\")" 2>/dev/null || echo "  (functions list requires permissions)"

# 5. Scheduler jobs
gcloud scheduler jobs list --location=$REGION --project=$PROJECT_ID --format=json > "$OUTDIR/scheduler.json" 2>&1 || true

# 6. Storage buckets
gcloud storage ls --project=$PROJECT_ID > "$OUTDIR/storage-ls.txt" 2>&1 || gsutil ls -p $PROJECT_ID > "$OUTDIR/storage-ls.txt" 2>&1 || true
cat "$OUTDIR/storage-ls.txt"

# 7. Firestore collections (console is authoritative)
echo "Firestore: check console -> Firestore -> Data, or: gcloud firestore databases describe --project=$PROJECT_ID"

echo ""
echo "REVIEW $OUTDIR/datastores.json and $OUTDIR/engines.json"
echo "Mark KEEP vs DELETE before running Step 7.2. Commit $OUTDIR to git or share for review."