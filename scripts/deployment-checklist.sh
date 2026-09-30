#!/bin/bash
# File: scripts/deployment-checklist.sh

echo "==============================================="
echo "INTERLISP SEARCH - UNIFIED DATA STORE CHECKLIST"
echo "==============================================="
echo ""

PROJECT_ID="interlispsearch"
DATA_STORE_ID="interlisp-search-unified"
LOCATION="global"
REGION="us-central1"

# Check 1: Unified data store exists (REST API — no gcloud CLI)
echo "[1/8] Checking unified data store..."
TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $PROJECT_ID" "https://discoveryengine.googleapis.com/v1/projects/$PROJECT_ID/locations/$LOCATION/collections/default_collection/dataStores/$DATA_STORE_ID")
if [ "$HTTP_CODE" = "200" ]; then
    echo "  ✓ Data store exists"
else
    echo "  ✗ Data store not found (HTTP $HTTP_CODE)"
fi
echo ""

# Check 2: Target sites configured
echo "[2/8] Checking target sites..."
TOKEN=$(gcloud auth application-default print-access-token)
RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" \
  -H "x-goog-user-project: $PROJECT_ID" \
  "https://discoveryengine.googleapis.com/v1/projects/$PROJECT_ID/locations/$LOCATION/collections/default_collection/dataStores/$DATA_STORE_ID/siteSearchEngine/targetSites")
SITE_COUNT=$(echo "$RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(len(data.get('targetSites', [])))")
echo "  Found $SITE_COUNT target sites"
echo ""

# Check 3: Cloud Function deployed (dual-engine blended)
echo "[3/8] Checking search Cloud Function..."
if gcloud functions describe search --gen2 --region=$REGION --project=$PROJECT_ID &>/dev/null; then
    WEBSITE_ENGINE_ID=$(gcloud functions describe search --gen2 --region=$REGION --project=$PROJECT_ID --format='value(environmentVariables.WEBSITE_ENGINE_ID)')
    GITHUB_ENGINE_ID=$(gcloud functions describe search --gen2 --region=$REGION --project=$PROJECT_ID --format='value(environmentVariables.GITHUB_ENGINE_ID)')
    ENGINE_ID=$(gcloud functions describe search --gen2 --region=$REGION --project=$PROJECT_ID --format='value(environmentVariables.ENGINE_ID)')
    echo "  ✓ Function deployed"
    echo "  WEBSITE_ENGINE_ID: $WEBSITE_ENGINE_ID"
    echo "  GITHUB_ENGINE_ID: $GITHUB_ENGINE_ID"
    echo "  ENGINE_ID: $ENGINE_ID"
else
    echo "  ✗ Function not deployed"
fi
echo ""

# Check 4: Recrawl function deployed
echo "[4/8] Checking website recrawl function..."
if gcloud functions describe trigger-website-recrawl --gen2 --region=$REGION --project=$PROJECT_ID &>/dev/null; then
    echo "  ✓ Function deployed"
else
    echo "  ✗ Function not deployed"
fi
echo ""

# Check 5: GitHub reimport function deployed
echo "[5/8] Checking GitHub reimport function..."
if gcloud functions describe github-reimport --gen2 --region=$REGION --project=$PROJECT_ID &>/dev/null; then
    echo "  ✓ Function deployed"
else
    echo "  ✗ Function not deployed"
fi
echo ""

# Check 6: Scheduler jobs configured
echo "[6/8] Checking Cloud Scheduler jobs..."
RECRAWL_EXISTS=$(gcloud scheduler jobs list --location=us-central1 --filter="name:recrawl-website-daily" --project=$PROJECT_ID --format='value(name)' 2>/dev/null)
REIMPORT_EXISTS=$(gcloud scheduler jobs list --location=us-central1 --filter="name:reimport-github-weekly" --project=$PROJECT_ID --format='value(name)' 2>/dev/null)

[ -n "$RECRAWL_EXISTS" ] && echo "  ✓ Recrawl job exists" || echo "  ✗ Recrawl job missing"
[ -n "$REIMPORT_EXISTS" ] && echo "  ✓ Reimport job exists" || echo "  ✗ Reimport job missing"
echo ""

# Check 7: Service account permissions
echo "[7/8] Checking service account permissions..."
SA_EMAIL="vertex-search-sa@interlispsearch.iam.gserviceaccount.com"
ROLES=$(gcloud projects get-iam-policy $PROJECT_ID \
  --flatten="bindings[].members" \
  --format='value(bindings.role)' \
  --filter="bindings.members:$SA_EMAIL" 2>/dev/null | wc -l)
echo "  Service account has $ROLES roles assigned"
echo ""

# Check 8: Test search function
echo "[8/8] Testing search function..."
FUNCTION_URL="https://$REGION-$PROJECT_ID.cloudfunctions.net/search"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$FUNCTION_URL?q=test&pageSize=5")
if [ "$HTTP_STATUS" = "200" ]; then
    echo "  ✓ Function responsive (HTTP $HTTP_STATUS)"
else
    echo "  ✗ Function returned HTTP $HTTP_STATUS"
fi
echo ""

echo "==============================================="
echo "CHECKLIST COMPLETE"
echo "==============================================="