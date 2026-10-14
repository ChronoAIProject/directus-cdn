ARG DIRECTUS_VERSION=11
FROM directus/directus:${DIRECTUS_VERSION}

COPY --chown=node:node extensions /directus/extensions
COPY --chown=node:node snapshots /directus/snapshots
