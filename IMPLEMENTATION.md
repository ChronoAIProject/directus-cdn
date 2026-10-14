# Blog CMS — Implementation Plan

**Status:** Draft v2 (refines *Multi-Site Blog CMS Integration Plan v2*)
**Last updated:** 2026-04-30

This document covers concrete execution: what gets built in **Directus**, what gets built in each **product site**, and the contracts between them. For broader context (goals, success criteria, risks) see the v2 plan; this doc only captures decisions and execution detail refined in the latest planning session.

---

## 1. Architecture

```
                ┌────────────────────┐
                │  Editor (admin UI) │
                └──────────┬─────────┘
                           │
                           ▼
              ┌────────────────────────────────┐
              │           Directus             │
              │  Postgres + S3 storage adapter │
              │  • /preview-md/:uuid endpoint  │
              │  • Publish Flow                │
              └──────────┬───────────┬─────────┘
                         │           │
              On publish:│           │ On publish:
                         │           │
                  PUT MD ▼           ▼ POST {{ product.trigger_url }}
              ┌─────────────────┐    ┌──────────────────────┐
              │  Shared S3      │    │ Product site CI/CD   │
              │  bucket         │    │ (k8s / GHA / …)      │
              │                 │◀───│ • fetch MD from S3   │
              │ blog/<prod>/*   │ GET│ • build SSG image    │
              │ directus_files/ │    │ • deploy             │
              └─────────────────┘    │ • PATCH audit log ───┼──┐
                                     └──────────┬───────────┘  │
                                                │ deploy       │
                                                ▼              │
                                    ┌────────────────────────┐ │
                                    │ Cloudflare-fronted SSG │ │
                                    │ www.<product>.com      │ │
                                    └────────────────────────┘ │
                                                               │
                                    Directus blog_publishes ◀──┘

Image delivery: Cloudflare CDN edge → cdn.aelf.io/assets/<id> → Directus
```

### Decisions captured in this session

| Topic | Decision |
|---|---|
| Editor UX | Form-based fields in Directus admin. **No JSON frontmatter** to hand-edit. |
| Content delivery | Build-time (SSG) per product site. **Pulled from shared S3 bucket.** Each site's existing CI/CD takes over after Directus's job. |
| Storage | **Single shared S3-compatible bucket.** `blog/<product>/<slug>.md` for content; `directus_files/...` for image uploads. Different IAM scopes per consumer. |
| Image hosting | Directus owns storage; Cloudflare caches `/assets/*` at edge — it does not store. |
| File format | **MD with YAML frontmatter** (universal SSG format). |
| Preview model | Public endpoint, **UUID-as-secret**. No JWT, no preview_token field. |
| Trigger | **Per-product webhook URL** configured on `products` collection. Directus is agnostic to the receiver — it just POSTs the payload. GHA, k8s, anything HTTP works. |
| Publish entrypoint | Custom Directus operation extension + a Webhook step. Both committed in this repo. |
| Schema as code | `snapshots/schema.yaml` committed; applied on deploy. |
| Failure modes | Happy path only for V1. Reconciler deferred to phase 6. |
| Per-site CI | Existing pipelines per site. Each site's secret, trigger URL, and payload template are configurable per-product in Directus. |

---

## 2. Directus-side execution

### 2.1 Infrastructure (already scaffolded in this repo)

- `docker-compose.yml` — Directus + Postgres for local dev
- `Dockerfile` — production image with `extensions/` and `snapshots/` baked in
- `.env.example` — env contract; in k8s these come from Secret/ConfigMap
- Storage: Directus's S3-compatible storage adapter, pointed at the **shared content bucket** (R2 in prod, local volume in dev). Both `blog/...` MD files and `directus_files/...` image uploads live in the same bucket; consumer access is split via IAM scope.
- CDN: Cloudflare-proxied `cdn.aelf.io` → k8s ingress → Directus. Cloudflare caches `/assets/*` at edge based on `ASSETS_CACHE_TTL`; it doesn't store originals.

### 2.2 Schema

#### `products` collection

| Field | Type | Notes |
|---|---|---|
| `id` | Manual String (PK) | e.g. `product-a` |
| `name` | String | Display name |
| `site_url` | String | e.g. `https://www.a.com` (used in Preview URL) |
| `content_path` | String | S3 key prefix, e.g. `blog/product-a/` (trailing slash) |
| `trigger_url` | String | Webhook URL — Directus POSTs here on publish |
| `trigger_method` | String (default `POST`) | HTTP method |
| `trigger_auth_header` | String, **hidden in non-admin UI** | e.g. `Bearer ghp_xxx` |
| `trigger_payload_template` | JSON, optional | Custom body shape; see §4.3. Default flat shape used if blank. |

Seed 5 records on first boot. `trigger_auth_header` field permission: read-only for Admin only (Editors / Publishers must not see it).

#### `blog_articles` collection

| Field | Type | Interface | Notes |
|---|---|---|---|
| `id` | UUID (PK) | — | UUID is the preview-URL secret |
| `product` | M2O → `products` | Dropdown | Determines S3 key prefix |
| `slug` | String | Slug | Lowercase, hyphenated |
| `title` | String | Input | |
| `description` | Text | Textarea | SEO summary, 120–160 chars |
| `body` | Text | **Markdown** | GFM body. No `# Title` line. |
| `tags` | M2M → `tags` | Tag input | |
| `series` | M2O → `series` | Dropdown | Optional |
| `author` | M2O → `directus_users` | User | |
| `hero_image` | File relation | File | |
| `published_at` | Timestamp | Datetime | Set by Flow on publish |
| `status` | Dropdown | Dropdown | `draft`, `in_review`, `published`, `archived` |
| `s3_key` | String | Input (read-only) | Set by Flow — `<content_path><slug>.md` |
| `s3_url` | String | Input (read-only) | Set by Flow — full S3 URL |

Enable **Track Revisions** for free draft history.

#### Supporting collections

- **`tags`** — `id`, `slug` (unique), `name`
- **`series`** — `id`, `slug` (unique), `name`, `description`
- **`blog_publishes`** (audit log) — `article` (M2O), `triggered_by` (M2O → users), `status` (`pending|s3_written|trigger_fired|success|failed`), `s3_key`, `s3_url`, `trigger_response_status` (int), `site_run_url`, `error`, `timestamp`

### 2.3 Permissions

Add an M2M field `product_access` on `directus_users` ↔ `products`.

| Role | `blog_articles` permissions | Status they can set | `products.trigger_auth_header` |
|---|---|---|---|
| Editor | CRUD filtered by `product._in: $CURRENT_USER.product_access.id` | `draft`, `in_review` | hidden |
| Publisher | Same filter | All | hidden |
| Admin | Unrestricted | All | visible |

**Public role:** `read` on `blog_articles` (so `/preview-md/:id` works without auth). Alternative: keep Public locked, have the endpoint use a service token internally.

### 2.4 Custom extensions (under `./extensions/`)

#### `operations/publish-to-s3/`

A Directus Flow operation that:

1. Receives the article (with deep relations) as input.
2. Computes `reading_time_minutes` (word count / 200wpm).
3. Assembles YAML frontmatter from structured fields (single source of truth — see §4.1).
4. Combines frontmatter + body → MD string.
5. PUTs the MD to S3 at `<product.content_path><slug>.md` using the same S3 credentials Directus's storage adapter already has.
6. Returns `{ s3_key, s3_url }`.

Required env (already configured for storage): `STORAGE_S3_KEY`, `STORAGE_S3_SECRET`, `STORAGE_S3_BUCKET`, `STORAGE_S3_ENDPOINT`, `STORAGE_S3_REGION`, `PUBLIC_URL`.

#### `endpoints/preview-md/`

Adds an HTTP route to Directus:

```
GET /preview-md/:id   →   text/markdown
```

Implementation:

1. Reads article by `id` (deep relations).
2. Calls the **same MD-assembly logic** as the publish operation (factored into `lib/build-md.ts`, shared between both extensions).
3. Returns assembled MD as `text/markdown; charset=utf-8`.
4. Sets `Cache-Control: private, no-store` and `X-Robots-Tag: noindex`.

**Single source of truth for MD format.** Preview and publish use the same code.

### 2.5 Publish Flow

**Trigger:** Event Hook on `items.blog_articles.update` (and `create`), filter `payload.status === 'published'`.

| # | Step name | Operation | What it does |
|---|---|---|---|
| 1 | `read_article` | Read Item — deep `*,product.*,author.*,tags.*,series.*,hero_image.*` | Fetch article with relations |
| 2 | `publish_to_s3` | Custom op `publish-to-s3` | Build MD, PUT to S3. Returns `{ s3_key, s3_url }`. |
| 3 | `update_article` | Update Item — `s3_key`, `s3_url`, `published_at = now()` | Provenance |
| 4 | `create_publish_log` | Create Item on `blog_publishes` — status `s3_written` | Audit row |
| 5 | `fire_trigger` | **Webhook** — `{{ product.trigger_method }} {{ product.trigger_url }}` with `Authorization: {{ product.trigger_auth_header }}`; body from `{{ product.trigger_payload_template }}` (default in §4.3) | Pings the product site CI |
| 6 | `update_publish_log` | Update Item on `blog_publishes` — status `trigger_fired`, store HTTP response status | Audit |

**Unpublish flow** (`status → archived`): mirror Flow that DELETEs `<content_path><slug>.md` from S3 and fires the same trigger with `action: "unpublish"` so the site can rebuild without the article.

### 2.6 Env vars

No new env vars beyond the existing storage config — per-product trigger URLs and auth tokens are stored as fields on the `products` collection (Postgres). `trigger_auth_header` is hidden from non-admin UI roles.

For multi-environment setups (staging vs prod), seed different `trigger_url` values per env's `products` table. The same Directus deployment doesn't need different env vars per environment for trigger routing.

### 2.7 Repo workflow

```bash
# After schema changes via UI:
docker compose exec directus npx directus schema snapshot --yes ./snapshots/schema.yaml

# Commit the snapshot, push, deploy. CI applies on the deploy target:
docker compose exec directus npx directus schema apply --yes ./snapshots/schema.yaml
```

---

## 3. Product site-side execution

Each of the 5 sites implements the same contract.

### 3.1 Preview route — `/blog/preview`

**Contract:**

```
GET /blog/preview?id=<article-uuid>
```

**Behavior:** server-renders a draft using the production blog component. No client-side fetching — the HTML returned to the iframe must already contain rendered content.

**Next.js (App Router) sketch:**

```ts
// app/blog/preview/page.tsx
import { notFound } from 'next/navigation';
import matter from 'gray-matter';
import { BlogPostRenderer } from '@/components/blog/BlogPostRenderer';

export const dynamic = 'force-dynamic';

export default async function PreviewPage({ searchParams }: { searchParams: { id?: string } }) {
  const id = searchParams.id;
  if (!id) notFound();

  const r = await fetch(`${process.env.DIRECTUS_URL}/preview-md/${id}`, { cache: 'no-store' });
  if (!r.ok) notFound();

  const md = await r.text();
  const { data: frontmatter, content: body } = matter(md);

  return <BlogPostRenderer frontmatter={frontmatter} body={body} isDraft />;
}
```

**Astro variant:** `src/pages/blog/preview.astro` with SSR (`output: 'server'` or `'hybrid'`), `export const prerender = false`. Same data flow.

**Required response headers:**
- `Cache-Control: private, no-store`
- `X-Robots-Tag: noindex`
- `Content-Security-Policy: frame-ancestors https://cdn.aelf.io` — allows the Directus admin iframe to embed this route. **Do not also set `X-Frame-Options: DENY`** (it overrides CSP).

### 3.2 Production blog rendering

The component used at `/blog/[slug]` (production) and `/blog/preview` (drafts) **must be the same**. Only the data source differs:

- **Production** — parsed from `./content/<product>/<slug>.md` synced from S3 at build time.
- **Preview** — parsed from `/preview-md/<uuid>` at request time.

Both pass `{ frontmatter, body }` of the same shape (§4.1) into the renderer.

### 3.3 Build-time content fetch from S3

Each site's existing CI fetches MD from the shared bucket at build time. AWS CLI example:

```yaml
- name: Fetch blog content from S3
  env:
    AWS_ACCESS_KEY_ID: ${{ secrets.S3_READ_KEY }}
    AWS_SECRET_ACCESS_KEY: ${{ secrets.S3_READ_SECRET }}
  run: |
    aws s3 sync s3://${{ secrets.CONTENT_BUCKET }}/blog/product-a/ ./content/product-a/ \
      --endpoint-url ${{ secrets.S3_ENDPOINT }} \
      --exact-timestamps \
      --delete
```

(`--endpoint-url` is needed for R2 / non-AWS S3 buckets. Drop it for AWS S3.)

The site's existing build then reads `./content/product-a/*.md`.

**S3 IAM scope per site CI:** read-only on `s3://<bucket>/blog/<product>/*` only. Each product site gets its own scoped key — no access to `directus_files/` or to other products' content.

### 3.4 Receiving the trigger

Directus POSTs the payload (§4.3) to whatever `trigger_url` is configured per product. Two common patterns:

#### Pattern A — GitHub Actions (`repository_dispatch`)

Directus `products` row for this site:

| Field | Value |
|---|---|
| `trigger_url` | `https://api.github.com/repos/<owner>/<site-repo>/dispatches` |
| `trigger_auth_header` | `Bearer <PAT or App token with actions:write>` |
| `trigger_payload_template` | (see below) |

`trigger_payload_template`:

```json
{
  "event_type": "blog-publish",
  "client_payload": {
    "article_id": "{{ article.id }}",
    "publish_id": "{{ publish.id }}",
    "slug": "{{ article.slug }}",
    "product": "{{ article.product.id }}",
    "s3_key": "{{ s3_key }}",
    "action": "publish"
  }
}
```

Site workflow:

```yaml
name: Blog Publish
on:
  repository_dispatch:
    types: [blog-publish]
jobs:
  rebuild:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Fetch content from S3
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.S3_READ_KEY }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.S3_READ_SECRET }}
        run: |
          aws s3 sync s3://${{ secrets.CONTENT_BUCKET }}/blog/product-a/ ./content/product-a/ \
            --endpoint-url ${{ secrets.S3_ENDPOINT }}

      - name: Build & deploy
        run: |
          # site-specific

      - name: Notify Directus
        if: always()
        run: |
          curl -X PATCH "${{ secrets.DIRECTUS_URL }}/items/blog_publishes/${{ github.event.client_payload.publish_id }}" \
            -H "Authorization: Bearer ${{ secrets.DIRECTUS_TOKEN }}" \
            -H "Content-Type: application/json" \
            -d '{
              "status": "${{ job.status == 'success' && 'success' || 'failed' }}",
              "site_run_url": "${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"
            }'
```

#### Pattern B — k8s webhook receiver

Directus `products` row:

| Field | Value |
|---|---|
| `trigger_url` | `https://hooks.aelf.io/blog/product-a` |
| `trigger_auth_header` | `Bearer <shared secret>` |
| `trigger_payload_template` | leave blank (uses default flat shape from §4.3) |

A small webhook receiver service in your cluster handles the POST: validates the auth header, creates a k8s Job that fetches from S3, builds the SSG image, deploys, and PATCHes the audit log on completion.

Both patterns look identical to Directus — only the URL, headers, and payload shape differ per product.

### 3.5 Site-level secrets

| Secret | Purpose |
|---|---|
| `S3_READ_KEY` / `S3_READ_SECRET` | Read-only IAM creds for `s3://<bucket>/blog/<product>/*` |
| `S3_ENDPOINT` | Bucket endpoint (R2 / S3 / MinIO URL) |
| `CONTENT_BUCKET` | Bucket name |
| `DIRECTUS_URL` | `https://cdn.aelf.io` |
| `DIRECTUS_TOKEN` | Scoped Directus token — `update` on `blog_publishes` only |

### 3.6 Iframe embedding gotchas

- CSP `frame-ancestors` must include the Directus admin origin on `/blog/preview`.
- `X-Frame-Options: DENY` overrides CSP — don't set both.
- CORS isn't needed here — preview fetches Directus **server-side**, not from the browser.

---

## 4. Shared contracts

### 4.1 MD file format

```markdown
---
title: "Introducing X"
slug: introducing-x
description: "120–160 char SEO summary."
published_at: 2026-04-30T10:00:00.000Z
last_updated_at: 2026-04-30T10:00:00.000Z
author:
  name: "Calvin Tan"
  avatar_url: https://cdn.aelf.io/assets/<uuid>
hero_image:
  url: https://cdn.aelf.io/assets/<uuid>
  alt: "Alt text"
tags:
  - launch
  - product
series: "X Launch"
reading_time_minutes: 6
---

GFM body content here…
```

Owned by the Directus `lib/build-md.ts` module — used by both the publish operation and the `/preview-md` endpoint. Frontends parse with `gray-matter` (Node) or equivalent.

A shared TypeScript type (`@aelf/blog-schema`) consumed by all 5 sites is recommended but not blocking V1.

### 4.2 Preview URL contract

Configured once in **Directus → Data Model → blog_articles → Preview URL**:

```
{{ product.site_url }}/blog/preview?id={{ id }}
```

- `id` is the article UUID
- No token, no expiry — UUID is the secret
- All 5 sites share this exact path

### 4.3 Trigger payload (default)

When `trigger_payload_template` is not set on a product, Directus sends:

```json
{
  "article_id": "<uuid>",
  "publish_id": "<uuid>",
  "slug": "introducing-x",
  "product": "product-a",
  "s3_key": "blog/product-a/introducing-x.md",
  "s3_url": "https://<bucket>.s3.<region>.amazonaws.com/blog/product-a/introducing-x.md",
  "action": "publish" | "unpublish"
}
```

If a product's CI expects a different shape (e.g., GHA `repository_dispatch` requires nesting under `client_payload`), set `trigger_payload_template` on that product to a JSON template using the available variables: `article`, `publish`, `s3_key`, `s3_url`, `action`.

### 4.4 Audit-log callback

Site → Directus `PATCH /items/blog_publishes/<publish_id>`:

```json
{
  "status": "success" | "failed",
  "site_run_url": "https://github.com/.../actions/runs/<id>"
}
```

---

## 5. Phased rollout

| Phase | Scope | Exit criteria |
|---|---|---|
| **1. Foundation** | Schema + permissions in `snapshots/schema.yaml`. Seed 5 product records (placeholder `trigger_url` for now). | Editor can create a draft and it persists. |
| **2. Preview** | Build `endpoints/preview-md`. Configure Preview URL. Implement `/blog/preview` on **one pilot site**. | Editor clicks Preview in Directus, sees draft rendered in pilot site's chrome. |
| **3. Publish + trigger** | Build `operations/publish-to-s3`. Wire into Flow with Webhook step. Configure pilot product's `trigger_url`. Pilot site CI fetches from S3 on build. | Publishing in Directus → S3 PUT + trigger fires → pilot site CI receives and rebuilds. |
| **4. Audit close-the-loop** | Pilot site CI calls back to update `blog_publishes`. Verify end-to-end. | Audit log shows `success` for a real publish-to-deploy cycle. |
| **5. Roll out** | Remaining 4 sites: configure `trigger_url` + `trigger_payload_template` in Directus, add `/blog/preview` route, wire CI to fetch from S3. Smoke test each. | All 5 sites on the platform. |
| **6. Hardening** | Reconciler for stuck publishes. Slack notifications. Scheduled publishing. Editor docs. | Operationally stable. |

---

## 6. Deferred items (known, not blocking V1)

- **Failure-mode reconciler.** Cron Flow that re-fires triggers for `blog_publishes` rows stuck in `s3_written` or `trigger_fired` longer than N minutes.
- **S3 versioning policy.** Enable on bucket for free history; document retention/restore procedure.
- **Per-site IAM key rotation.** Calendar-based rotation for the read-only S3 keys handed to each product CI.
- **Reusable webhook receiver template.** If 5 sites end up with near-identical k8s Job handlers, factor out.
- **Per-product preview secrets.** N/A under UUID-only model; revisit if threat model changes.
- **i18n / multi-language.** Open question; v2 plan §12.
- **Search across products.** Postgres trigram or Typesense/Meilisearch; out of scope for V1.

---

## 7. Open questions to track

- Concurrent edits to the same article (Directus shows a UI warning; no real lock).
- SMTP setup for editor invites + password resets (required once non-admin editors land).
- `pg_dump` cadence and offsite retention for self-host backup (suggested: daily, 30-day retention).
- Image upload size policy in Directus (cap at 5MB? auto-compress on upload?).
- Whether to enable S3 bucket versioning at provisioning time (recommended yes).
