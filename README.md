# Interlisp AI Search

AI-assisted search backend for [interlisp.org](https://interlisp.org), powered by Google Cloud Vertex AI Search (Discovery Engine). The public-facing search UI lives in the website repo (see [Frontend integration](#frontend-integration)); this repository contains all backend code and the documentation for building and extending it.

## Overview

The backend is a set of Gen2 Cloud Functions in GCP project `interlispsearch` (region `us-central1`) that proxy search requests from the Hugo/Docsy site to Vertex AI Search and return results with an AI-generated summary and resolved citation links.

```
Browser → Hugo search page → search Cloud Function (proxy) → Vertex AI Search engines
                                   │
                                   ├─ Firestore rate_limits (per-IP + global TTL)
                                   └─ CORS origin allow-list
```

- **`search`** — HTTP proxy. Fetches from the website engine (`interlisp-website-only`) and GitHub engine (`interlisp-github-only`) in parallel, merges, adds the AI summary, resolves citations, and applies Firestore rate limiting.
- **`trigger-website-recrawl`** — scheduled Pub/Sub trigger for refreshing the website data store.
- **`github-reimport`** — Pub/Sub-triggered GitHub content reimport (re-exported from `src/index.js` via `exports.reimportGithub`).

## Repository Map

```
Interlisp-search/            # = Cloud Function source root (gcloud --source=.)
├── src/                     # Deployed application code (all Cloud Functions)
│   ├── index.js             # HTTP entrypoint (exports.search), engine selection, CORS, re-exports reimportGithub
│   ├── rateLimiter.js       # Firestore-backed per-IP + global rate limiting
│   ├── github-reimport.js   # Pub/Sub GitHub reimport (exports.reimportGithub)
│   └── trigger-website-recrawl.js # Scheduled site recrawl trigger
├── scripts/
│   ├── deploy-search-function.sh    # Deploy the search function (self-locates repo root)
│   ├── verify-deployment.sh         # Post-deploy smoke checks
│   ├── test-citations.sh            # Citation-resolution tests
│   ├── github-index.js              # Build github-*.jsonl import files from GitHub
│   ├── github-initial-import.js     # One-off JSONL import builder + uploader (local CLI)
│   ├── create-unified-datastore.sh  # Creates the unified website data store
│   ├── add-target-sites.sh          # Adds target site URI patterns
│   ├── check-indexing-status.sh     # Target-site indexing status
│   ├── check-datastore-status.sh    # Target-site status via REST
│   ├── deployment-checklist.sh      # 8-point deployment health check
│   ├── inventory-interlispsearch.sh # Read-only resource inventory (run before deletes)
│   └── cleanup-interlispsearch.sh   # DESTRUCTIVE — delete stale GCP resources
├── docs/
│   ├── long_term_search_arch_proposal.md       # Architecture proposal (v4)
│   ├── long_term_search_implementation_guide.md# Implementation guide (phases 1–7)
│   ├── vertex-ai-search-implementation.md      # Vertex AI integration build log + lessons
│   ├── search_across_data_stores.md            # Cross-data-store search notes
│   └── reference/                              # old_index.js (retired variant), research notes
├── package.json               # main → src/index.js (deploy unit for all functions)
├── .gcloudignore              # Excludes scripts//docs/*.md/*.jsonl from deploys
└── .github/workflows/ci.yml   # Lint-only CI for pull requests
```

## Prerequisites

- Node.js **20+** (runtime on GCP is `nodejs24`)
- Google Cloud CLI (`gcloud`) authenticated with access to project `interlispsearch`
- Application Default Credentials (`gcloud auth application-default login`) for REST-based tooling
- A GitHub token for the import/reimport tooling (repo read scope)

## Quick Start

```bash
npm install
npm run lint          # zero errors expected (pre-existing warnings are intentional)
node --check src/*.js  # syntax check the function source before deploying

./scripts/deploy-search-function.sh   # deploys the `search` function
./scripts/verify-deployment.sh        # smoke test
./scripts/test-citations.sh           # citation tests
```

## Environment Variables

| Variable | Used by | Purpose |
|---|---|---|
| `PROJECT_ID` | `src/index.js`, `src/trigger-website-recrawl.js`, `scripts/github-initial-import.js`, `src/rateLimiter.js` | GCP project (`interlispsearch`) |
| `ENGINE_ID` | `src/index.js` | Fallback single-engine ID (deploy sets to `interlisp-website-only`) |
| `WEBSITE_ENGINE_ID` | `src/index.js` | Primary engine (`interlisp-website-only`) |
| `GITHUB_ENGINE_ID` | `src/index.js` | GitHub content engine (`interlisp-github-only`) |
| `WEBSITE_DATA_STORE_ID` | `src/trigger-website-recrawl.js` | Website data store (`interlisp-web-sites_1741606671710`) |
| `DATA_STORE_ID` | `scripts/github-initial-import.js` | Target data store for JSONL import |
| `GITHUB_TOKEN` | `src/github-reimport.js`, `scripts/github-initial-import.js`, `scripts/github-index.js` | GitHub API auth (repo read). `GH_TOKEN` / `GITHUB_PAT` also accepted by `scripts/github-index.js` |

## Frontend Integration

The search UI is in `Interlisp/Interlisp.github.io`:

- `config/_default/params.yaml` — `vertex_search_url: "https://us-central1-interlispsearch.cloudfunctions.net/search"` (Docsy search box requires `gcs_engine_id` too)
- `layouts/search.html` — overrides the Docsy results page
- `assets/js/vertex-search.js` — frontend widget (fetch + render summary/citations/results)
- `assets/scss/_styles_project.scss` — `.ai-summary`, `.td-search-hit`, `.search-citations`

See `docs/vertex-ai-search-implementation.md` Part 6 for the integration summary.

## Documentation

Start with `docs/long_term_search_arch_proposal.md` (architecture) and `docs/long_term_search_implementation_guide.md` (phases, scripts, troubleshooting). See `docs/README.md` for the full index.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Interlisp.org.