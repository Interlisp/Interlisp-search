# Vertex AI Search Integration with Hugo (Docsy)
## Implementation Guide for Interlisp.org

This document captures the complete steps taken to replace Google Custom Search (GCS) with a Vertex AI Search (Agent Search) powered search engine on a Hugo/Docsy site hosted on GitHub Pages.

The backend code and deployment scripts described here now live in the repository **`Interlisp/Interlisp-search`** (repo root = Cloud Function source; `scripts/` = GCP shell tooling). The frontend integration stays in `Interlisp/Interlisp.github.io`. This doc is the build log / extension reference; the on-disk files in those repos are authoritative.

Note:
- The production deployment (2026-09-02, function `search-00037-xas`) uses a blended setup: engine `interlisp-website-only` (data store `interlisp-web-sites_1741606671710`) as primary, `interlisp-github-only` (data store `interlisp-github-v2`) for GitHub content, and `interlisp-search-unified` as fallback. Older engines/data stores such as `interlisp-org-search_1768860477660` are delete candidates.

---

## Architecture Overview

```
Browser → Hugo Search Page → Cloud Function (proxy) → Vertex AI Search (Agent Search)
                                      ↑        ↑
                              Service Account  Firestore (rate limiting)
                                      ↑
                              Data Store (interlisp.org crawl)
```

### Components

| Component | Name/ID | Purpose |
|---|---|---|
| GCP Project | `interlispsearch` (191169864763) | Container for all resources |
| Service Account | `vertex-search-sa@interlispsearch.iam.gserviceaccount.com` | Auth identity for Cloud Function |
| Data Store | `interlisp-web-sites_1741606671710` | Crawled and indexed web site content (`*.interlisp.org/*`, Advanced site search) |
| Data Store | `interlisp-github-v2` | Uploaded content from www.github.com/Interlisp — markdown files, Issues, Discussions, PRs (`NO_CONTENT`, `branches/0`) |
| Data Store | `interlisp-search-unified` | Fresh website store retained as the fallback datastore |
| Search Engine | `interlisp-website-only` | Primary — sites data store |
| Search Engine | `interlisp-github-only` | Secondary — GitHub data store |
| Search Engine | `interlisp-search-unified` | Fallback — blended website + GitHub |
| Cloud Function | `search` (us-central1, `search-00037-xas`) | Proxy between Hugo frontend and Vertex AI |
| Firestore | `rate_limits` collection | Per-IP and global request rate limiting (TTL on `updatedAt`) |

---

## Part 1 — GCP Project Setup

### 1.1 Enable Required APIs

```bash
gcloud services enable discoveryengine.googleapis.com
gcloud services enable cloudbuild.googleapis.com
gcloud services enable storage.googleapis.com
gcloud services enable orgpolicy.googleapis.com
gcloud services enable firestore.googleapis.com
```

### 1.2 Create Service Account

```bash
gcloud iam service-accounts create vertex-search-sa \
  --display-name="Vertex Search Service Account" \
  --project=interlispsearch
```

### 1.3 Grant Service Account Roles

```bash
# Core role for Vertex AI Search access
gcloud projects add-iam-policy-binding interlispsearch \
  --member="serviceAccount:vertex-search-sa@interlispsearch.iam.gserviceaccount.com" \
  --role="roles/discoveryengine.editor"

# Allow reading from Cloud Storage (for future JSONL imports)
gcloud projects add-iam-policy-binding interlispsearch \
  --member="serviceAccount:vertex-search-sa@interlispsearch.iam.gserviceaccount.com" \
  --role="roles/storage.objectViewer"

# Allow Firestore read/write for rate limiting
gcloud projects add-iam-policy-binding interlispsearch \
  --member="serviceAccount:vertex-search-sa@interlispsearch.iam.gserviceaccount.com" \
  --role="roles/datastore.user"
```

### 1.4 Override Org Policies (Project Level)

The interlisp.org GCP organization had two restrictive org policies that blocked key creation and public function invocation. These were overridden at the project level without affecting the org-wide policy.

```bash
# Allow allUsers IAM bindings in this project (needed for public Cloud Function)
cat > allow-all-users.yaml << 'EOF'
name: projects/interlispsearch/policies/iam.allowedPolicyMemberDomains
spec:
  inheritFromParent: false
  rules:
  - allowAll: true
EOF

gcloud org-policies set-policy allow-all-users.yaml --project=interlispsearch

# Allow service account key creation in this project
cat > allow-sa-keys.yaml << 'EOF'
name: projects/interlispsearch/policies/iam.disableServiceAccountKeyCreation
spec:
  inheritFromParent: false
  rules:
  - enforce: false
EOF

gcloud org-policies set-policy allow-sa-keys.yaml --project=interlispsearch
```

### 1.5 Set Up Local Authentication

```bash
# Authenticate with Application Default Credentials
gcloud auth application-default login

# Set quota project (required for Discovery Engine API calls)
gcloud auth application-default set-quota-project interlispsearch

# Set default project
gcloud config set project interlispsearch
```

**Important:** All `curl` calls to the Discovery Engine API require the `x-goog-user-project` header:

```bash
-H "x-goog-user-project: interlispsearch"
```

---

## Part 2 — Vertex AI Data Store

### 2.1 Create the Data Store

```bash
TOKEN=$(gcloud auth application-default print-access-token)

curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "x-goog-user-project: interlispsearch" \
  "https://discoveryengine.googleapis.com/v1/projects/interlispsearch/locations/global/collections/default_collection/dataStores?dataStoreId=interlisp-site-search" \
  -d '{
    "displayName": "Interlisp Site Search",
    "industryVertical": "GENERIC",
    "solutionTypes": ["SOLUTION_TYPE_SEARCH"],
    "contentConfig": "PUBLIC_WEBSITE"
  }'
```

**Key parameters:**
- `contentConfig: PUBLIC_WEBSITE` — enables website crawling
- `industryVertical: GENERIC` — required for non-Workspace data stores
- Location must be `global` for AI summarization features

### 2.2 Add Target Site

The URL pattern does **not** include the `https://` protocol prefix:

```bash
TOKEN=$(gcloud auth application-default print-access-token)

curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "x-goog-user-project: interlispsearch" \
  "https://discoveryengine.googleapis.com/v1/projects/interlispsearch/locations/global/collections/default_collection/dataStores/interlisp-site-search/siteSearchEngine/targetSites" \
  -d '{
    "providedUriPattern": "interlisp.org/*",
    "type": "INCLUDE",
    "exactMatch": false
  }'
```

Note:  A search engine created with multiple data stores can have 2 or more but may never drop to a single data store.  Likewise, a search engine
created with a single data store can never extend to 2 or more.

### 2.3 Upgrade to Advanced Website Indexing

Advanced indexing is required for AI summarization features. This is done in the GCP console:

1. Go to **AI Applications → Data Stores → interlisp-site-search**
2. Click the **Data** tab
3. Click **Upgrade to Advanced** next to the URL pattern

Upgrading takes 4-8 hours for a site the size of interlisp.org. Check status:

```bash
TOKEN=$(gcloud auth application-default print-access-token)

curl -H "Authorization: Bearer $TOKEN" \
  -H "x-goog-user-project: interlispsearch" \
  "https://discoveryengine.googleapis.com/v1/projects/interlispsearch/locations/global/collections/default_collection/dataStores/interlisp-site-search/siteSearchEngine/targetSites" \
  | python3 -m json.tool
```

Look for `indexingStatus: SUCCEEDED` to confirm completion.

---

## Part 3 — Vertex AI Search Engine (App)

### 3.1 Important: App Type Selection

The search engine must be created as **"Site search with AI mode"** in the console — NOT as "Gemini Enterprise" or "Custom Search (general)".

- **Gemini Enterprise** — for internal workspace knowledge bases, incompatible with website data stores
- **Custom Search (general)** — for structured document/JSONL data, not website crawling
- **Site search with AI mode** ✓ — correct type for public website crawling with AI summaries

### 3.2 Create via Console

1. Go to **AI Applications → Apps → Create App**
2. Select **Search → Site search with AI mode**
3. Fill in details:
   - App name: `interlisp-site-search-v2`
   - Company name: `interlisp.org`
   - Location: `global`
4. Select data store: `interlisp-site-search`
5. Note the generated engine ID: `interlisp-site-search-v2_1777510147931`

### 3.3 Verify Engine Configuration

```bash
TOKEN=$(gcloud auth application-default print-access-token)

curl -H "Authorization: Bearer $TOKEN" \
  -H "x-goog-user-project: interlispsearch" \
  "https://discoveryengine.googleapis.com/v1/projects/interlispsearch/locations/global/collections/default_collection/engines/interlisp-site-search-v2_1777510147931" \
  | python3 -m json.tool
```

Confirm the response contains:
```json
{
  "searchEngineConfig": {
    "searchTier": "SEARCH_TIER_ENTERPRISE",
    "searchAddOns": ["SEARCH_ADD_ON_LLM"]
  }
}
```

`SEARCH_ADD_ON_LLM` is required for AI summaries.

---

## Part 4 — Cloud Function (Search Proxy)

The Cloud Function acts as a secure proxy between the public Hugo frontend and the authenticated Vertex AI Search API. It also builds the AI prompt context.

### 4.1 Project Structure

The backend lives in the `Interlisp/Interlisp-search` repository. The Cloud Function deploy unit is the **repo root** (`gcloud --source=.`); `scripts/` and `docs/` are excluded from deploys via `.gcloudignore`.

```
Interlisp-search/                 # = Cloud Function source root
├── src/
│   ├── index.js                  # HTTP entrypoint (exports.search)
│   ├── rateLimiter.js            # Firestore rate limiting
│   ├── github-reimport.js        # Pub/Sub GitHub reimport (exports.reimportGithub)
│   └── trigger-website-recrawl.js # Scheduled site recrawl trigger
├── package.json                  # main → src/index.js
├── .gcloudignore
├── scripts/                      # GCP tooling (deploy, verify, github-index, …)
└── docs/                         # Canonical build/extend documentation
```

The frontend side stays in `Interlisp.github.io` (see Part 6).

### 4.2 `package.json`

Matches the on-disk `package.json` at the repo root (authoritative).

```json
{
  "name": "interlisp-search",
  "version": "1.0.0",
  "description": "AI-assisted search backend for Interlisp.org (Google Cloud Vertex AI Search + Cloud Functions)",
  "main": "src/index.js",
  "type": "commonjs",
  "dependencies": {
    "@google-cloud/discoveryengine": "^2.6.0",
    "@google-cloud/firestore": "^8.5.0",
    "@google-cloud/storage": "^7.0.0",
    "google-auth-library": "^10.6.2"
  },
  "devDependencies": {
    "@eslint/js": "^10.0.1",
    "eslint": "^10.9.1",
    "globals": "^17.11.0"
  }
}
```

### 4.3 `src/index.js`

The function uses the raw REST API (not the Node.js SDK) to avoid SDK auto-pagination which strips the `summary` field from responses. It includes Firestore-based rate limiting and resolves citation URLs by matching document IDs from results.

> The snippet below is the conceptual core. The deployed, on-disk version in `src/` is authoritative — it additionally lazy-loads the compiled `@google-cloud/discoveryengine` helper libraries (with a try/catch downgrade to `google-auth-library`) and applies request-time engine selection (`WEBSITE_ENGINE_ID` / `GITHUB_ENGINE_ID` / fallback).

```javascript
'use strict';

const { GoogleAuth } = require('google-auth-library');
const { isRateLimited } = require('./rateLimiter');

const PROJECT_ID = process.env.PROJECT_ID;
const ENGINE_ID  = process.env.ENGINE_ID;
const LOCATION   = 'global';

const auth = new GoogleAuth({
  scopes: ['https://www.googleapis.com/auth/cloud-platform']
});

exports.search = async (req, res) => {

  // CORS — allow specific origins only
  const allowedOrigins = [
    'https://interlisp.org',
    'https://www.interlisp.org',
    'https://stumbo.github.io',
    'http://localhost:1313',
    'http://localhost:8080',
  ];

  const origin = req.headers.origin || '';
  const allowedOrigin = allowedOrigins.includes(origin)
    ? origin
    : 'https://interlisp.org';

  res.set('Access-Control-Allow-Origin', allowedOrigin);
  res.set('Access-Control-Allow-Methods', 'GET, OPTIONS');
  res.set('Access-Control-Allow-Headers', 'Content-Type');
  res.set('Access-Control-Max-Age', '3600');

  if (req.method === 'OPTIONS') {
    res.status(204).send('');
    return;
  }

  // Rate limiting
  const rateLimitResult = await isRateLimited(req);
  if (rateLimitResult.limited) {
    res.set('Retry-After', String(rateLimitResult.retryAfter));
    res.status(429).json({
      error:      'Rate limit exceeded',
      message:    rateLimitResult.reason,
      retryAfter: rateLimitResult.retryAfter
    });
    return;
  }

  const query    = req.query.q || req.body?.q || '';
  const context  = req.query.context || req.body?.context || '';
  const pageSize = parseInt(req.query.pageSize) || 10;

  if (!query.trim()) {
    res.status(400).json({ error: 'Missing query parameter q' });
    return;
  }

  try {
    const client = await auth.getClient();
    const token  = await client.getAccessToken();

    const endpoint = `https://discoveryengine.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/collections/default_collection/engines/${ENGINE_ID}/servingConfigs/default_config:search`;

    const requestBody = {
      query,
      pageSize,
      contentSearchSpec: {
        summarySpec: {
          summaryResultCount: 5,
          includeCitations: true,
          useSemanticChunks:  true,
          languageCode:       'en-US',
          modelPromptSpec: {
            preamble: buildPreamble(context)
          },
          modelSpec: {
            version: 'stable'
          }
        },
        snippetSpec: {
          returnSnippet: true
        },
        extractiveContentSpec: {
          maxExtractiveAnswerCount: 3
        }
      }
    };

    const response = await fetch(endpoint, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${token.token}`,
        'Content-Type': 'application/json',
        'x-goog-user-project': PROJECT_ID
      },
      body: JSON.stringify(requestBody)
    });

    if (!response.ok) {
      const errText = await response.text();
      throw new Error(`Vertex API error ${response.status}: ${errText}`);
    }

    const data = await response.json();

    // Strip HTML tags from snippet text
    const stripHtml = str => str ? str.replace(/<[^>]*>/g, '') : null;

    // Build document ID → URL map for citation linking
    const docIdToUrl = {};
    (data.results || []).forEach(result => {
      const id  = result.document?.id;
      const url = result.document?.derivedStructData?.link;
      if (id && url) docIdToUrl[id] = url;
    });

    // Map references to include resolved URLs by matching document IDs
    const references = (data.summary?.summaryWithMetadata?.references || [])
      .map(ref => {
        const docId = ref.document?.split('/').pop();
        return {
          title: ref.title,
          uri:   docIdToUrl[docId] || null,
        };
      });

    // REST API returns derivedStructData as flat object (not nested under .fields)
    const results = (data.results || []).map(result => {
      const derived = result.document?.derivedStructData;
      if (!derived) return null;

      const url     = derived.link || null;
      const snippet = derived.snippets?.[0]?.snippet || null;

      return {
        id:      result.document?.id,
        title:   derived.title || null,
        url,
        snippet: stripHtml(derived.snippets?.[0]?.snippet || null),
        section: url?.replace('https://interlisp.org/', '')
                     ?.split('/')?.[0] || '',
      };
    }).filter(r => r?.url);

    const summaryText = data.summary?.summaryText || null;

    res.json({
      summary: summaryText ? {
        summaryText,
        citations: references
      } : null,
      results
    });

  } catch (err) {
    console.error('Search error:', err);
    res.status(500).json({ error: 'Search failed', detail: err.message });
  }
};

function buildPreamble(context) {
  const base = `You are a search assistant for the Interlisp documentation site.
Answer questions clearly and concisely. Always cite the sources you used.
If no relevant results exist, say so directly rather than guessing.`;

  if (context) {
    return `${base}\nThe user is currently browsing the "${context}" section — prioritize results from that section where relevant.`;
  }
  return base;
}
```

### 4.4 `.gcloudignore`

Matches the on-disk `.gcloudignore` at the repo root (authoritative). Deploys bundle only the function source — docs and tooling are excluded.

```
node_modules/
.git/
*.md
scripts/
docs/
*.jsonl
```

### 4.5 Deploy

Preferred (self-locates the repo root):

```bash
./scripts/deploy-search-function.sh
```

Manual equivalent:

```bash
npm install

gcloud functions deploy search \
  --gen2 \
  --runtime=nodejs24 \
  --region=us-central1 \
  --source=. \
  --entry-point=search \
  --trigger-http \
  --allow-unauthenticated \
  --service-account=vertex-search-sa@interlispsearch.iam.gserviceaccount.com \
  --set-env-vars PROJECT_ID=interlispsearch,WEBSITE_ENGINE_ID=interlisp-website-only,GITHUB_ENGINE_ID=interlisp-github-only,ENGINE_ID=interlisp-website-only \
  --memory=256Mi \
  --timeout=30s \
  --project=interlispsearch
```

**Key deployment decisions:**
- `--gen2` — required for Cloud Run-based functions with better performance
- `--allow-unauthenticated` — public endpoint, CORS restricts access by domain in function code
- `--service-account` — function runs as the service account, which has Discovery Engine and Firestore access
- No key file needed — the service account is attached at deploy time

### 4.6 Verify Deployment

```bash
# Test without auth token (should return results)
curl -s "https://us-central1-interlispsearch.cloudfunctions.net/search?q=interlisp" \
  | python3 -m json.tool | head -30
```

---

## Part 5 — Firestore Rate Limiting

Rate limiting is implemented using Firestore to track request counts across all function instances. In-memory counters cannot be used because Cloud Functions can scale to multiple instances.

### 5.1 Create the Firestore Database

```bash
gcloud firestore databases create \
  --location=us-central1 \
  --project=interlispsearch
```

### 5.2 Set Up TTL to Auto-Clean Expired Documents

This prevents the `rate_limits` collection from growing indefinitely:

```bash
gcloud firestore fields ttls update updatedAt \
  --collection-group=rate_limits \
  --enable-ttl \
  --project=interlispsearch
```

This operation takes 5-15 minutes to propagate. Check status:

```bash
gcloud firestore fields describe updatedAt \
  --collection-group=rate_limits \
  --project=interlispsearch
```

Look for `ttlConfig.state: ACTIVE` to confirm completion.

### 5.3 `src/rateLimiter.js`

Create `rateLimiter.js` in `src/` (matches the on-disk, deployed file):

```javascript
'use strict';

const { Firestore } = require('@google-cloud/firestore');

const db = new Firestore({ projectId: process.env.PROJECT_ID });

const LIMITS = {
  perIp: {
    requests: 20,    // max 20 requests per IP
    windowSec: 60,   // per 60 second window
  },
  global: {
    requests: 500,   // max 500 total requests
    windowSec: 60,   // per 60 second window
  }
};

async function checkLimit(key, limit) {
  const ref      = db.collection('rate_limits').doc(key);
  const now      = Date.now();
  const windowMs = limit.windowSec * 1000;

  try {
    const result = await db.runTransaction(async t => {
      const doc  = await t.get(ref);
      const data = doc.exists ? doc.data() : null;

      if (!data || (now - data.windowStart) > windowMs) {
        t.set(ref, { count: 1, windowStart: now, updatedAt: now });
        return { allowed: true, count: 1 };
      }

      if (data.count >= limit.requests) {
        return { allowed: false, count: data.count };
      }

      t.update(ref, {
        count:     Firestore.FieldValue.increment(1),
        updatedAt: now
      });
      return { allowed: true, count: data.count + 1 };
    });

    return result;

  } catch (err) {
    // Fail open — don't block searches if Firestore is unavailable
    console.error('Rate limiter error:', err.message);
    return { allowed: true, count: 0 };
  }
}

async function isRateLimited(req) {
  const ip = req.headers['x-forwarded-for']
    ?.split(',')[0]?.trim() || 'unknown';

  const [ipCheck, globalCheck] = await Promise.all([
    checkLimit(`ip:${ip}`, LIMITS.perIp),
    checkLimit('global',   LIMITS.global),
  ]);

  if (!ipCheck.allowed) {
    return {
      limited:    true,
      reason:     'Too many requests. Please wait a moment before searching again.',
      retryAfter: LIMITS.perIp.windowSec
    };
  }

  if (!globalCheck.allowed) {
    return {
      limited:    true,
      reason:     'Search service is temporarily busy. Please try again shortly.',
      retryAfter: LIMITS.global.windowSec
    };
  }

  return { limited: false };
}

module.exports = { isRateLimited };
```

### 5.4 Rate Limit Configuration

| Limit | Value | Notes |
|---|---|---|
| Per IP | 20 requests / 60 seconds | Prevents individual abuse |
| Global | 500 requests / 60 seconds | Protects against aggregate overload |
| Fail behavior | Open (allow) | If Firestore unavailable, searches proceed |

### 5.5 Verify Rate Limiting

```bash
# Check Firestore documents are created after searches
gcloud firestore documents list \
  --collection=rate_limits \
  --project=interlispsearch

# Test that 429 is returned after limit is exceeded
for i in {1..25}; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    "https://us-central1-interlispsearch.cloudfunctions.net/search?q=test")
  echo "Request $i: $STATUS"
done
```

Requests 1-20 return `200`, requests 21+ return `429`.

---

## Part 6 — Frontend Integration (Interlisp.github.io)

The search UI lives in the website repo `Interlisp/Interlisp.github.io` (Hugo + **Docsy** v0.14.3, served on GitHub Pages). The backend Cloud Function is origin-agnostic — the frontend only needs to know its URL.

### 6.1 Configuration

In `config/_default/params.yaml`:

```yaml
# Keep this — Docsy won't render the search box without it
gcs_engine_id: 33ef4cbe0703b4f3a

# Add Vertex AI Search Cloud Function URL
vertex_search_url: "https://us-central1-interlispsearch.cloudfunctions.net/search"
```

### 6.2 Files

| Site-repo file | Purpose |
|---|---|
| `layouts/search.html` | Overrides Docsy's GCS results page; renders the summary + hits container |
| `assets/js/vertex-search.js` | Frontend widget — fetches the Cloud Function, renders AI summary, citations, and result links |
| `layouts/_partials/hooks/head-end.html` | Loads the bundled `vertex-search.js` |
| `assets/scss/_styles_project.scss` | Styles for `.ai-summary`, `.td-search-hit`, `.search-citations` |

Flow: Docsy's own `search.js` redirects the search box to `/search/?q=query` on Enter; `search.html` supplies the container; `vertex-search.js` reads `vertex_search_url`, sends `q` plus an optional `context` (the referring top-level section, used to bias the AI preamble), and renders the AI summary with citation links and the results list.

> The full Docsy walkthrough (rendering rules, SCSS, `head-end.html` bundling) is preserved in the git history of `Interlisp.github.io`; the on-disk files there are authoritative.

---

## Part 7 — File Summary

### New Files Created (Interlisp-search repo)

| File | Purpose |
|---|---|
| `src/index.js` | Cloud Function — proxy to Vertex AI Search, engine selection, summary + citation resolution |
| `src/rateLimiter.js` | Firestore-based rate limiting |
| `src/github-reimport.js` | Pub/Sub-triggered GitHub reimport (re-exported via `src/index.js`) |
| `src/trigger-website-recrawl.js` | Scheduled site recrawl trigger |
| `scripts/github-initial-import.js` | One-off JSONL import builder |
| `package.json` | Node.js dependencies (incl. `@google-cloud/storage` for reimport) |
| `.gcloudignore` | Excludes node_modules/docs/scripts from deploy |
| `scripts/deploy-search-function.sh` | Deploy helper |

### New Files Created (Interlisp.github.io repo)

| File | Purpose |
|---|---|
| `layouts/search.html` | Overrides Docsy's GCS results page |
| `assets/js/vertex-search.js` | Frontend search widget JS |

### Modified Files (Interlisp.github.io repo)

| File | Change |
|---|---|
| `config/_default/params.yaml` | Added `vertex_search_url`, kept `gcs_engine_id` |
| `layouts/_partials/hooks/head-end.html` | Added JS bundle load |
| `assets/scss/_styles_project.scss` | Added search result and citation styles |

---

## Part 8 — Key Lessons Learned

### Authentication
- Local `curl` testing requires the `x-goog-user-project: interlispsearch` header with ADC credentials — without it, requests are billed against a Google-internal project and fail with 403
- Cloud Functions authenticate via the attached service account at runtime — no key file needed
- Browser JS cannot call authenticated Cloud Functions directly — the function must be public (`--allow-unauthenticated`) with CORS restricting by origin in code

### Vertex AI SDK vs REST API
- The Node.js `@google-cloud/discoveryengine` SDK uses auto-pagination by default, which flattens the response into a plain array of results and **strips the `summary` field**
- Using the raw REST API via `fetch` preserves the full response structure including `summary`, `totalSize`, `attributionToken`, and `semanticState`
- The REST API returns `derivedStructData` as a flat object (e.g. `derived.title`) rather than nested under `fields` as the SDK does (e.g. `fields.title.stringValue`)

### Citations
- The `references` array in `summaryWithMetadata` contains document paths, not URLs
- URLs must be resolved by cross-referencing document IDs from the `results` array against the document path suffix in each reference
- `useSemanticChunks: true` in `summarySpec` improves citation accuracy

### Org Policies
- `constraints/iam.allowedPolicyMemberDomains` blocked `allUsers` invocation
- `constraints/iam.disableServiceAccountKeyCreation` blocked service account key files
- Both were overridden at the project level using `gcloud org-policies set-policy` — requires `roles/owner` on the project but not org-level admin access

### Data Store Type
- Must be created as **"Site search with AI mode"** in the AI Applications console
- **"Gemini Enterprise"** app type is incompatible with website data stores
- URL patterns for target sites must **not** include `https://` protocol prefix
- Advanced website indexing (upgrade from Basic) is required for AI summarization — takes 4-8 hours

### Rate Limiting
- Cloud Functions are stateless — in-memory rate limit counters don't work across scaled instances
- Firestore transactions provide atomic counter increments safe for concurrent access
- The rate limiter fails open — if Firestore is unavailable, searches proceed rather than being blocked
- Firestore TTL policies auto-clean expired rate limit documents — set on the `updatedAt` field

---

## Part 9 — Deployment Status

| Environment | URL | Status |
|---|---|---|
| Production | `https://interlisp.org/search/?q=interlisp` | ✅ Live (`search-00037-xas`) |
| Webhook endpoint | `https://us-central1-interlispsearch.cloudfunctions.net/search` | ✅ Verified 2026-09-02 |

### What is working end to end

- Search box renders in Docsy navbar and sidebar
- Typing a query and pressing Enter redirects to `/search/?q=query`
- Vertex AI Search returns relevant results from the indexed interlisp.org site
- AI-generated summary appears at the top of results with `[n]` citation markers
- Citation sources are listed below the summary with links to source pages
- Snippets are plain text (HTML stripped)
- CORS is correctly scoped to allowed origins (`interlisp.org`, `www.interlisp.org`)
- Rate limiting is active — 20 requests/minute per IP, 500/minute global
- Firestore TTL auto-cleans expired rate limit documents

---

## Part 10 — Remaining Items

- [x] Deploy to production (`interlisp.org`) — live 2026-09-02 (`search-00037-xas`)
- [x] Verify exact production domain in the CORS `allowedOrigins` list (`interlisp.org`, `www.interlisp.org`)
- [ ] Set up CI/CD to re-index when site content changes (scheduled recrawl + weekly GitHub reimport exist; CI-driven deploys deferred)
- [ ] Remove any remaining debug `console.log` statements from `src/index.js`
- [ ] Monitor Firestore `rate_limits` collection and adjust limits based on real traffic
- [ ] Consider adding query logging to Firestore for search analytics
- [ ] Review and tune the AI preamble prompt based on real query patterns
