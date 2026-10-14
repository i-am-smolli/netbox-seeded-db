ARG POSTGRES_VERSION=18-alpine
FROM postgres:${POSTGRES_VERSION}

ARG NETBOX_VERSION="unknown"
ARG GITHUB_REPOSITORY=""

LABEL org.opencontainers.image.title="NetBox Pre-Seeded PostgreSQL" \
      org.opencontainers.image.description="PostgreSQL image with pre-migrated schema, initial data, and test superuser for NetBox" \
      org.opencontainers.image.netbox.version="${NETBOX_VERSION}" \
      org.opencontainers.image.source="https://github.com/${GITHUB_REPOSITORY}" \
      org.opencontainers.image.licenses="MPL-2.0"

# The official PostgreSQL docker-entrypoint automatically unzips *.sql.gz files
# placed in /docker-entrypoint-initdb.d/ on the first startup of an empty database.
COPY dump.sql.gz /docker-entrypoint-initdb.d/01-netbox.sql.gz

# Healthcheck to verify postgres is ready to accept connections
HEALTHCHECK --interval=2s --timeout=3s --retries=10 \
  CMD pg_isready -q -d ${POSTGRES_DB:-netbox} -U ${POSTGRES_USER:-netbox} || exit 1
