#!/usr/bin/env bash
# ==============================================================================
# build-seeded-db.sh
# 
# Spins up NetBox + Postgres + Valkey in RAM (tmpfs), applies all migrations,
# sets up a standard superuser and API token, dumps the database, and builds
# a ready-to-run PostgreSQL Docker image with pre-seeded data.
# ==============================================================================
set -euo pipefail

NETBOX_VERSION="${1:-latest}"

# Determine Registry Image Base
if [ -n "${REGISTRY_IMAGE:-}" ]; then
  IMAGE_BASE="${REGISTRY_IMAGE}"
elif [ -n "${GITHUB_REPOSITORY:-}" ]; then
  OWNER_LOWER="$(echo "${GITHUB_REPOSITORY_OWNER:-${GITHUB_REPOSITORY%%/*}}" | tr '[:upper:]' '[:lower:]')"
  REPO_IMAGE_NAME="${IMAGE_NAME:-netbox-postgres-seeded}"
  IMAGE_BASE="ghcr.io/${OWNER_LOWER}/${REPO_IMAGE_NAME}"
elif [ -n "${CI_REGISTRY_IMAGE:-}" ]; then
  IMAGE_BASE="${CI_REGISTRY_IMAGE}"
else
  IMAGE_BASE="netbox-postgres-seeded"
fi

OUTPUT_IMAGE="${IMAGE_BASE}:${NETBOX_VERSION}"
PROJECT_NAME="netbox_seed_$(date +%s)_${RANDOM}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Standard Test Credentials (hardcoded for test isolation & predictability)
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.org}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-uchae4uSeiYah5roe7gauYaer}"

# Detect if target version is legacy NetBox (< 4.5)
if [[ "${NETBOX_VERSION}" =~ ^v?3\. ]] || [[ "${NETBOX_VERSION}" =~ ^v?4\.[0-4](\.|$) ]]; then
  API_KEY=""
  API_TOKEN="${API_TOKEN:-0123456789abcdef0123456789abcdef01234567}"
  FULL_AUTH_TOKEN="${API_TOKEN}"
  AUTH_TYPE="Token"
  API_TOKEN_PEPPER_1=""
else
  API_KEY="${API_KEY:-haiweeni2Aiv}"
  API_TOKEN="${API_TOKEN:-ahgeechahdaighah6queivoo6ahChahgo2ohch9inahyei5ahk}"
  FULL_AUTH_TOKEN="nbt_${API_KEY}.${API_TOKEN}"
  AUTH_TYPE="Bearer"
  API_TOKEN_PEPPER_1="${API_TOKEN_PEPPER_1:-Qy+F=OTeGskWQ(wTMgjc+NPPlz6YwFXY=KHIIg=wpYXT&e(6u8}"
fi

TMP_DIR="/tmp/${PROJECT_NAME}"

cleanup() {
  echo "🧹 [Cleanup] Stopping and removing temporary containers..."
  docker compose -p "${PROJECT_NAME}" -f "${TMP_DIR}/docker-compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "${TMP_DIR}" || true
}
trap cleanup EXIT

echo "======================================================================"
echo " Building Pre-Seeded NetBox Database Image"
echo " NetBox Version : ${NETBOX_VERSION}"
echo " Target Image   : ${OUTPUT_IMAGE}"
echo " Project Name   : ${PROJECT_NAME}"
echo "======================================================================"

mkdir -p "${TMP_DIR}"
mkdir -p "${REPO_ROOT}/dist"

# Generate temporary optimized docker-compose
cat <<EOF > "${TMP_DIR}/docker-compose.yml"
services:
  postgres:
    image: postgres:18-alpine
    environment:
      POSTGRES_DB: netbox
      POSTGRES_USER: netbox
      POSTGRES_PASSWORD: netboxpassword
    command:
      - postgres
      - -c
      - fsync=off
      - -c
      - synchronous_commit=off
      - -c
      - full_page_writes=off
    tmpfs:
      - /var/lib/postgresql:size=1024m
    healthcheck:
      test: pg_isready -d netbox -U netbox
      interval: 1s
      timeout: 3s
      retries: 30

  valkey:
    image: valkey/valkey:9.1-alpine
    command: valkey-server --save "" --appendonly no

  netbox:
    image: netboxcommunity/netbox:${NETBOX_VERSION}
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DB_HOST: postgres
      DB_NAME: netbox
      DB_USER: netbox
      DB_PASSWORD: netboxpassword
      REDIS_HOST: valkey
      REDIS_CACHE_HOST: valkey
      SECRET_KEY: "dummy-secret-key-for-seed-generation-purpose-only-minimum-50-chars"
      API_TOKEN_PEPPER_1: "${API_TOKEN_PEPPER_1}"
      DB_WAIT_DEBUG: 1
      SKIP_SUPERUSER: "false"
      SUPERUSER_NAME: "${ADMIN_USER}"
      SUPERUSER_EMAIL: "${ADMIN_EMAIL}"
      SUPERUSER_PASSWORD: "${ADMIN_PASSWORD}"
      SUPERUSER_API_KEY: "${API_KEY}"
      SUPERUSER_API_TOKEN: "${API_TOKEN}"
      DB_WAIT_TIMEOUT: 1
    healthcheck:
      test: curl -sf http://localhost:8080/login/ >/dev/null || exit 1
      interval: 3s
      timeout: 5s
      retries: 240
      start_period: 30s
EOF

echo "🚀 [1/4] Starting temporary stack in RAM..."
docker compose -p "${PROJECT_NAME}" -f "${TMP_DIR}/docker-compose.yml" up -d

echo "⏳ [2/4] Waiting for NetBox to finish migrations & healthcheck..."
MAX_WAIT="${BUILD_TIMEOUT:-720}"
ELAPSED=0
NETBOX_CID=$(docker compose -p "${PROJECT_NAME}" -f "${TMP_DIR}/docker-compose.yml" ps -q netbox)

until [ "$(docker inspect -f '{{.State.Health.Status}}' "${NETBOX_CID}")" == "healthy" ]; do
  # Check if container died prematurely
  CONTAINER_STATUS=$(docker inspect -f '{{.State.Status}}' "${NETBOX_CID}" 2>/dev/null || echo "unknown")
  if [ "${CONTAINER_STATUS}" == "exited" ] || [ "${CONTAINER_STATUS}" == "dead" ]; then
    echo ""
    echo "❌ NetBox container exited unexpectedly with status '${CONTAINER_STATUS}'!"
    docker compose -p "${PROJECT_NAME}" -f "${TMP_DIR}/docker-compose.yml" logs netbox
    exit 1
  fi

  sleep 3
  ELAPSED=$((ELAPSED + 3))
  if [ "${ELAPSED}" -ge "${MAX_WAIT}" ]; then
    echo ""
    echo "❌ Timeout of ${MAX_WAIT}s reached waiting for NetBox!"
    docker compose -p "${PROJECT_NAME}" -f "${TMP_DIR}/docker-compose.yml" logs netbox
    exit 1
  fi
  printf "."
done
echo ""
echo "✅ NetBox is healthy! (Took ~${ELAPSED}s in RAM)"

PG_CID=$(docker compose -p "${PROJECT_NAME}" -f "${TMP_DIR}/docker-compose.yml" ps -q postgres)

# NetBox >= 4.5 generates a random 12-char key if not explicitly set in the model.
# Update the key deterministically so consumers can authenticate with predictable test credentials.
if [ -n "${API_KEY}" ]; then
  echo "🔑 Setting deterministic API token key '${API_KEY}'..."
  docker exec "${PG_CID}" psql -U netbox -d netbox -c \
    "UPDATE users_token SET key = '${API_KEY}' WHERE user_id = (SELECT id FROM users_user WHERE username = '${ADMIN_USER}');" >/dev/null
fi

# Verify API token before dumping to guarantee image integrity
echo "🔍 Verifying API superuser token..."
if ! docker exec "${NETBOX_CID}" curl -sf \
  -H "Authorization: ${AUTH_TYPE} ${FULL_AUTH_TOKEN}" \
  -H "Accept: application/json" \
  http://localhost:8080/api/users/users/ >/dev/null; then
  echo "❌ Error: API token verification failed on temporary stack!"
  docker compose -p "${PROJECT_NAME}" -f "${TMP_DIR}/docker-compose.yml" logs netbox
  exit 1
fi
echo "✅ API token successfully verified!"

echo "💾 [3/4] Exporting PostgreSQL Dump..."
DUMP_FILE="${REPO_ROOT}/dist/netbox-${NETBOX_VERSION}.sql.gz"

docker exec "${PG_CID}" pg_dump \
  -U netbox \
  -d netbox \
  --clean \
  --if-exists \
  --no-owner \
  --no-privileges \
  | sed "s/set_config('search_path', '', false)/set_config('search_path', 'public, pg_catalog', false)/" \
  | gzip > "${DUMP_FILE}"

echo "📦 Dump created: ${DUMP_FILE} ($(du -h "${DUMP_FILE}" | cut -f1))"

echo "🐳 [4/4] Building Docker Image '${OUTPUT_IMAGE}'..."
cp "${DUMP_FILE}" "${TMP_DIR}/dump.sql.gz"
cp "${REPO_ROOT}/Dockerfile" "${TMP_DIR}/Dockerfile"

docker build \
  -t "${OUTPUT_IMAGE}" \
  --build-arg NETBOX_VERSION="${NETBOX_VERSION}" \
  --build-arg GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}" \
  -f "${TMP_DIR}/Dockerfile" \
  "${TMP_DIR}"

if [ "${NETBOX_VERSION}" != "latest" ] && [ "${TAG_LATEST:-false}" == "true" ]; then
  docker tag "${OUTPUT_IMAGE}" "${IMAGE_BASE}:latest"
fi

echo "======================================================================"
echo "🎉 SUCCESS!"
echo "   Docker Image: ${OUTPUT_IMAGE}"
echo "   Raw Dump    : ${DUMP_FILE}"
echo "   Test Token  : ${AUTH_TYPE} ${FULL_AUTH_TOKEN}"
echo "======================================================================"
