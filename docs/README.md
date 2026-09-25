# Documentation Index

Canonical build/extension documentation for the AI-assisted search backend.

| Document | Purpose |
|---|---|
| [`long_term_search_arch_proposal.md`](long_term_search_arch_proposal.md) | Architecture proposal (v4): requirements, engine/data-store matrix, dual-engine blended design, rollback plan, cleanup appendix. |
| [`long_term_search_implementation_guide.md`](long_term_search_implementation_guide.md) | Step-by-step implementation guide (Phases 1–7): data store setup, Cloud Function + `src/index.js` walkthrough, deploy/recrawl/reimport, testing checklist, troubleshooting, resource cleanup. |
| [`vertex-ai-search-implementation.md`](vertex-ai-search-implementation.md) | Vertex AI Search integration build log: GCP setup, Cloud Function internals, Firestore rate limiting, frontend pointer, lessons learned, deployment status. |
| [`search_across_data_stores.md`](search_across_data_stores.md) | Notes/experiments on querying across multiple data stores. |
| [`reference/interlispSearch.txt`](reference/interlispSearch.txt) | Reference material on Interlisp search. |
| [`reference/googleResources.txt`](reference/googleResources.txt) | Reference material on Google Cloud / Vertex AI Search resources. |

> On-disk code and scripts referenced in these docs are authoritative — under `../src/index.js`, `../src/rateLimiter.js`, and `../scripts/`.

## Reading Order

1. Architecture proposal — high-level design decisions.
2. Implementation guide — deploy and operate the backend.
3. Vertex AI integration — build log and troubleshooting context.