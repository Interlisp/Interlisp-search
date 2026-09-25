#!/usr/bin/env node
/**
 * github-initial-import.js — One-off initial GitHub seeding for interlisp-search-unified
 *
 * Fetches Interlisp/medley, maiko, Interlisp.github.io issues/PRs/README,
 * builds JSONL with additive metadata (source/priority/last_indexed extend
 * existing repo/type/created_date), uploads to
 * gs://interlispsearch-search-imports/github-initial-*.jsonl, then calls
 * POST .../documents:import.
 *
 * Usage:
 *   export GITHUB_TOKEN=ghp_...
 *   gcloud auth application-default login && gcloud auth application-default set-quota-project interlispsearch
 *   gcloud config set project interlispsearch
 *   cd search-function && npm install
 *   GITHUB_TOKEN=$GITHUB_TOKEN node github-initial-import.js
 *   # or: GITHUB_TOKEN=$GITHUB_TOKEN node github-initial-import.js --dry-run  (writes /tmp/github-initial-*.jsonl only)
 *
 * Verify:
 *   TOKEN=$(gcloud auth application-default print-access-token)
 *   curl -s -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: interlispsearch" \
 *     "https://discoveryengine.googleapis.com/v1/projects/interlispsearch/locations/global/collections/default_collection/dataStores/interlisp-search-unified/branches/default/documents?pageSize=5" | python3 -m json.tool
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { GoogleAuth } = require('google-auth-library');
const { Storage } = require('@google-cloud/storage');

const PROJECT_ID = process.env.PROJECT_ID || 'interlispsearch';
const LOCATION = 'global';
// For structured GitHub docs, import into the NO_CONTENT store, not the PUBLIC_WEBSITE store.
// interlisp-search-unified (PUBLIC_WEBSITE) holds crawled interlisp.org/files.interlisp.org;
// interlisp-github-v2 (NO_CONTENT) holds structured issues/PRs/markdown. The unified ENGINE
// then combines both dataStores (like interlisp-search-v3 does with site-search + github-v2).
const DATA_STORE_ID = process.env.DATA_STORE_ID || 'interlisp-github-v2';
const GITHUB_TOKEN = process.env.GITHUB_TOKEN;
const GITHUB_ORG = 'Interlisp';
const GITHUB_REPOS = ['medley', 'maiko', 'Interlisp.github.io'];
const BUCKET_NAME = `${PROJECT_ID}-search-imports`;
const DRY_RUN = process.argv.includes('--dry-run');

const sanitizeId = s => s.replace(/[^a-zA-Z0-9-_]/g, '-');

if (!GITHUB_TOKEN) {
  console.warn('WARN: GITHUB_TOKEN not set — using anonymous GitHub API (60 req/hour, public repos only). For higher rate limit, set GITHUB_TOKEN.');
}

const auth = new GoogleAuth({ scopes: ['https://www.googleapis.com/auth/cloud-platform'] });
const storage = new Storage({ projectId: PROJECT_ID });

async function ghFetch(url, accept = 'application/vnd.github.v3+json') {
  const headers = { Accept: accept, 'User-Agent': 'interlisp-initial-import' };
  if (GITHUB_TOKEN) headers.Authorization = `token ${GITHUB_TOKEN}`;
  const res = await fetch(url, { headers });
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`${url} -> ${res.status} ${res.statusText} ${body.slice(0, 200)}`);
  }
  if (accept.includes('raw')) return res.text();
  return res.json();
}

async function fetchIssues() {
  const out = [];
  for (const repo of GITHUB_REPOS) {
    try {
      const url = `https://api.github.com/repos/${GITHUB_ORG}/${repo}/issues?state=all&per_page=100`;
      const items = await ghFetch(url);
      for (const issue of items) {
        if (issue.pull_request) continue; // issues endpoint includes PRs
        out.push({
          id: sanitizeId(`github-issue-${repo}-${issue.number}`),
          title: issue.title,
          url: issue.html_url,
          content: issue.body || issue.title || '',
          metadata: {
            source: 'github',
            priority: 3,
            content_type: 'issue',
            repo: `${GITHUB_ORG}/${repo}`,
            issue_number: issue.number,
            state: issue.state,
            created_date: issue.created_at,
            updated_date: issue.updated_at,
            last_indexed: new Date().toISOString(),
          },
        });
      }
      console.log(`  issues ${GITHUB_ORG}/${repo}: ${items.filter(i=>!i.pull_request).length}`);
    } catch (e) {
      console.warn(`  issues ${GITHUB_ORG}/${repo} failed: ${e.message}`);
    }
  }
  return out;
}

async function fetchPRs() {
  const out = [];
  for (const repo of GITHUB_REPOS) {
    try {
      const url = `https://api.github.com/repos/${GITHUB_ORG}/${repo}/pulls?state=all&per_page=100`;
      const items = await ghFetch(url);
      for (const pr of items) {
        out.push({
          id: sanitizeId(`github-pr-${repo}-${pr.number}`),
          title: pr.title,
          url: pr.html_url,
          content: `${pr.title}\n\n${pr.body || ''}`.trim(),
          metadata: {
            source: 'github',
            priority: 3,
            content_type: 'pull_request',
            repo: `${GITHUB_ORG}/${repo}`,
            pr_number: pr.number,
            state: pr.state,
            created_date: pr.created_at,
            updated_date: pr.updated_at,
            last_indexed: new Date().toISOString(),
          },
        });
      }
      console.log(`  PRs ${GITHUB_ORG}/${repo}: ${items.length}`);
    } catch (e) {
      console.warn(`  PRs ${GITHUB_ORG}/${repo} failed: ${e.message}`);
    }
  }
  return out;
}

async function fetchMarkdown() {
  const out = [];
  for (const repo of GITHUB_REPOS) {
    try {
      const url = `https://api.github.com/repos/${GITHUB_ORG}/${repo}/readme`;
      const content = await ghFetch(url, 'application/vnd.github.v3.raw');
        out.push({
          id: sanitizeId(`github-markdown-${repo}-README`),
        title: `${repo} README`,
        url: `https://github.com/${GITHUB_ORG}/${repo}/blob/main/README.md`,
        content,
        metadata: {
          source: 'github',
          priority: 3,
          content_type: 'markdown',
          repo: `${GITHUB_ORG}/${repo}`,
          file: 'README.md',
          last_indexed: new Date().toISOString(),
        },
      });
      console.log(`  README ${GITHUB_ORG}/${repo}: ok`);
    } catch (e) {
      console.warn(`  README ${GITHUB_ORG}/${repo}: ${e.message}`);
    }
  }
  return out;
}

async function main() {
  console.log(`[${new Date().toISOString()}] Initial GitHub import -> ${PROJECT_ID}/${DATA_STORE_ID} (dryRun=${DRY_RUN})`);
  const docs = [];
  docs.push(...await fetchIssues());
  docs.push(...await fetchPRs());
  docs.push(...await fetchMarkdown());
  console.log(`Total documents: ${docs.length}`);
  if (docs.length === 0) {
    console.error('No documents fetched — check GITHUB_TOKEN and repo names');
    process.exit(1);
  }
  // Discovery Engine NO_CONTENT schema expects Document.structData, not top-level title/url.
  // Convert our flat {id,title,url,content,metadata} into {id, structData:{...}}
  const jsonl = docs.map(d => JSON.stringify({
    id: d.id,
    structData: {
      id: d.id,
      title: d.title,
      url: d.url,
      content: d.content,
      ...d.metadata,
    }
  })).join('\n');
  const tmpFile = `/tmp/github-initial-${Date.now()}.jsonl`;
  fs.writeFileSync(tmpFile, jsonl);
  console.log(`Wrote JSONL locally: ${tmpFile} (${Buffer.byteLength(jsonl)} bytes)`);

  if (DRY_RUN) {
    console.log('DRY RUN — not uploading/importing. Inspect file, then re-run without --dry-run');
    return;
  }

  // Ensure bucket exists
  const bucket = storage.bucket(BUCKET_NAME);
  try {
    const [exists] = await bucket.exists();
    if (!exists) {
      console.log(`Creating bucket gs://${BUCKET_NAME}`);
      await storage.createBucket(BUCKET_NAME, { location: 'US' });
    }
  } catch (e) {
    console.warn(`Bucket check/create warning: ${e.message}`);
  }

  const gcsName = `github-initial-${Date.now()}.jsonl`;
  console.log(`Uploading to gs://${BUCKET_NAME}/${gcsName}`);
  await bucket.file(gcsName).save(jsonl, { contentType: 'application/jsonl' });

  const client = await auth.getClient();
  const token = await client.getAccessToken();
  const importUrl = `https://discoveryengine.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/collections/default_collection/dataStores/${DATA_STORE_ID}/branches/0/documents:import`;
  console.log(`POST ${importUrl}`);
  const res = await fetch(importUrl, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token.token}`,
      'Content-Type': 'application/json',
      'x-goog-user-project': PROJECT_ID,
    },
    body: JSON.stringify({ gcsSource: { inputUris: [`gs://${BUCKET_NAME}/${gcsName}`] } }),
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`Import failed ${res.status}: ${body}`);
  console.log(`Import started: ${body.slice(0, 500)}`);
  console.log(`[${new Date().toISOString()}] Done — monitor with: gcloud functions logs read ... or GET .../documents`);
}

main().catch(e => { console.error(e); process.exit(1); });
