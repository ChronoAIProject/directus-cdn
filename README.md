# directus-cdn

Self-hosted [Directus](https://directus.io) that stores the aelf / Chrono product
blogs: article text, images, and video. Editors write in the Directus admin UI.
Product sites read published articles, and Cloudflare serves the media from
`cdn.aelf.io`.

> **Status: scaffold only.** Directus and Postgres run locally with Docker
> Compose. The schema, the custom extensions (`publish-to-s3`, `preview-md`), and
> the production deployment do not exist yet. Provisioning is tracked in
> [NyxID#525](https://github.com/ChronoAIProject/NyxID/issues/525). The full
> design is in [IMPLEMENTATION.md](./IMPLEMENTATION.md).

## Contents

- [How it works](#how-it-works)
- [Repository layout](#repository-layout)
- [Run locally](#run-locally)
- [Content model](#content-model)
- [Permissions](#permissions)
- [Schema as code](#schema-as-code)
- [Custom extensions](#custom-extensions)
- [Deploying to production](#deploying-to-production)
- [Consumers](#consumers)
- [Roadmap](#roadmap)

## How it works

```
Editor ──▶ Directus admin UI ──▶ Postgres (content, users, permissions)
                │                └▶ S3 / Cloudflare R2 (uploaded files)
                │
                ├─ on publish ──▶ writes <product>/<slug>.md to the shared bucket
                │                 and calls the product site's build webhook
                │
                └─ /preview-md/:id ──▶ draft markdown for the site's preview route

Browser ──▶ cdn.aelf.io/assets/<file-id> ──▶ Cloudflare edge cache ──▶ Directus
```

- **Directus** is the CMS and the media library. One instance serves every product
  site. Each article belongs to one product.
- **Postgres** holds the schema, the article content, users, and permissions.
- **S3-compatible storage** (Cloudflare R2 in production, a local folder in dev)
  holds uploaded files and the published markdown.
- **Cloudflare** caches `/assets/*` at the edge and does not store the originals.
- **Product sites** build statically. On publish, Directus calls the site's build
  webhook. The site's CI then downloads its markdown from the bucket and rebuilds.

[IMPLEMENTATION.md](./IMPLEMENTATION.md) explains why each of these choices was made.

## Repository layout

```
.
├── docker-compose.yml   # Local dev: Directus + Postgres 16
├── Dockerfile           # Production image; copies extensions/ and snapshots/ in
├── .env.example         # Every environment variable, with defaults; copy to .env
├── IMPLEMENTATION.md    # Design, contracts, and rollout plan
├── extensions/          # Custom Directus extensions (none built yet)
├── snapshots/           # Directus schema-as-code (schema.yaml goes here)
└── uploads/             # Local file storage for dev; contents are gitignored
```

## Run locally

Requirements: Docker with Compose v2.

```bash
cp .env.example .env

# Generate KEY and SECRET, then paste one value into each in .env
openssl rand -hex 32
openssl rand -hex 32

docker compose up
```

Open the admin UI at <http://localhost:8055>. Sign in with `ADMIN_EMAIL` and
`ADMIN_PASSWORD` from `.env`. Directus creates this admin account the first time
the database starts and ignores both values after that.

Change `DB_PASSWORD` and `ADMIN_PASSWORD` before using the stack anywhere other
than your own machine.

To check that the API is up:

```bash
curl http://localhost:8055/server/health
```

To reset everything, including the database:

```bash
docker compose down -v
```

## Content model

`IMPLEMENTATION.md` §2.2 is the source of truth. In summary:

- **`products`**: one row per product site. It stores the site URL, the bucket
  prefix (`content_path`), and the build webhook (`trigger_url`,
  `trigger_method`, `trigger_auth_header`, `trigger_payload_template`).
- **`blog_articles`**: the articles. The UUID `id` doubles as the preview secret.
  Fields: `product`, `slug`, `title`, `description`, `body` (GitHub-flavored
  markdown, without a `# Title` line), `tags`, `series`, `author`, `hero_image`,
  `published_at`, and `status`. `status` is one of `draft`, `in_review`,
  `published`, or `archived`. The publish flow also sets `s3_key` and `s3_url`.
  Track Revisions should be on, so every draft is kept.
- **`tags`** and **`series`**: lookup collections, each with a unique `slug`.
- **`blog_publishes`**: the audit log. Each publish attempt gets a row, and the
  product site's CI reports the final success or failure back to it.

A published article is stored as markdown with YAML frontmatter (title, slug,
description, dates, author, hero image, tags, series, reading time). The format
is defined in `IMPLEMENTATION.md` §4.1. The publish operation and the preview
endpoint must build this markdown with the same code.

### First-time setup

There is no committed `snapshots/schema.yaml` yet, so the first person to set up
the schema does it by hand:

1. Start the stack and sign in.
2. In **Settings → Data Model**, create the collections listed above.
3. Set up roles under **Settings → Access Policies** (see [Permissions](#permissions)).
4. Take a schema snapshot and commit it (see [Schema as code](#schema-as-code)).

After this, every other environment applies the snapshot instead of repeating
these steps.

## Permissions

- **Editor**: can create, read, update, and delete articles for products listed
  in their `product_access`. Can set status to `draft` or `in_review` only.
- **Publisher**: everything an Editor can do, and can also set `published` or
  `archived`.
- **Admin**: no restrictions. Only Admins can see `products.trigger_auth_header`.
- **Public**: read access to `blog_articles` where `status = published`, and to
  `directus_files`.

Do not give the Public role read access to drafts. Directus's `/items` endpoint
returns everything a role is allowed to read, so anyone could list all draft
UUIDs, and a UUID is the only thing protecting a preview. The `preview-md`
endpoint should fetch drafts using its own server-side permissions.

## Schema as code

Collections, fields, and permissions you create in the admin UI exist only in
that environment's database. To share them, save them in a schema snapshot and
commit the file.

```bash
# Save the current schema to snapshots/schema.yaml
docker compose exec directus npx directus schema snapshot --yes ./snapshots/schema.yaml

# Load it into another environment, e.g. during a deploy
docker compose exec directus npx directus schema apply --yes ./snapshots/schema.yaml
```

In production, run `npx directus schema apply` in the Directus container before
it starts accepting traffic, for example from a Kubernetes init container or Job.
The production image already contains `snapshots/`.

## Custom extensions

Extensions go in `extensions/`. During local development, Directus reloads them
whenever they change (`EXTENSIONS_AUTO_RELOAD=true`).

```bash
cd extensions
npx create-directus-extension@latest
cd <extension-name>
npm run dev    # rebuilds on every change; the running container picks it up
```

Two extensions are planned (`IMPLEMENTATION.md` §2.4):

- **`operations/publish-to-s3`**: a step for Directus Flows. It builds the
  article's markdown and uploads it to `<content_path><slug>.md` in the bucket.
- **`endpoints/preview-md`**: `GET /preview-md/:id`. It returns the draft as
  `text/markdown` with `Cache-Control: private, no-store` and
  `X-Robots-Tag: noindex`.

Both extensions should build the markdown with one shared module (`lib/build-md.ts`).

`Dockerfile` copies `extensions/` into the image unchanged. Build each extension
(`npm run build`) before building the image, so its `dist/` output is included.

## Deploying to production

Production runs on Kubernetes, with Cloudflare in front of `cdn.aelf.io`.

```bash
docker build -t aelf/directus-cdn:<version> .
```

Set the image's `DIRECTUS_VERSION` build argument to an exact Directus release
instead of the default `11`.

### Environment

`.env.example` lists every variable. In production:

- `KEY` and `SECRET`: random 32-byte hex values. Store them in a Kubernetes Secret.
- `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USER`, `DB_PASSWORD`: connection
  details for the managed Postgres.
- `ADMIN_EMAIL` and `ADMIN_PASSWORD`: used only on first boot.
- `PUBLIC_URL=https://cdn.aelf.io`
- `STORAGE_LOCATIONS=s3` and the `STORAGE_S3_*` settings for R2:

  ```env
  STORAGE_LOCATIONS=s3
  STORAGE_S3_DRIVER=s3
  STORAGE_S3_KEY=<r2 access key>
  STORAGE_S3_SECRET=<r2 secret>
  STORAGE_S3_BUCKET=<bucket>
  STORAGE_S3_REGION=auto
  STORAGE_S3_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
  ```

- `CORS_ORIGIN`: the product sites' origins. The default, `true`, allows any origin.
- `EXTENSIONS_AUTO_RELOAD=false`

### Cloudflare

1. Create a proxied DNS record for `cdn.aelf.io` that points at the Kubernetes ingress.
2. Under **Rules → Cache Rules**, cache `/assets/*` according to the origin's
   `Cache-Control` header. `ASSETS_CACHE_TTL` controls that header; the default
   is 30 days.
3. Bypass the cache for `/items/*`, `/users/*`, `/auth/*`, `/graphql`,
   `/admin/*`, and `/preview-md/*`.

### Backups

Postgres holds the only copy of drafts and article history, so back it up with
`pg_dump` at least daily. Turn on object versioning for the bucket.

## Consumers

- **NyxID**: [`frontend/src/features/blog`](https://github.com/ChronoAIProject/NyxID/tree/main/frontend/src/features/blog)
  provides `/blog`, `/blog/:slug`, and `/preview/:id`. These pages currently
  read in-bundle mock data that copies Directus's `{ data: ... }` response
  shape. To go live, replace that mock data with requests to this service.
  Its types predate the bucket design: they still use
  `content_commit_sha`/`content_url` where this plan uses `s3_key`/`s3_url`,
  and they include GitHub-dispatch fields on `Product`. Update them when the
  mock data is replaced. See NyxID's `docs/BLOG_IMPLEMENTATION.md`.
- **Other product sites**: each needs a server-rendered `/blog/preview?id=<uuid>`
  route and a CI job that downloads its markdown from the bucket and rebuilds.
  The required contract is in `IMPLEMENTATION.md` §3.

## Roadmap

These phases come from `IMPLEMENTATION.md` §5:

1. **Foundation**: commit `snapshots/schema.yaml` and add the five product rows.
2. **Preview**: build `preview-md` and add a preview route to one pilot site.
3. **Publish**: build `publish-to-s3`, create the publish Flow, and wire up the
   pilot site's webhook.
4. **Audit loop**: the pilot site's CI reports its result back to `blog_publishes`.
5. **Rollout**: connect the remaining four sites.
6. **Hardening**: retry stuck publishes, add Slack alerts, scheduled publishing,
   and editor docs.
