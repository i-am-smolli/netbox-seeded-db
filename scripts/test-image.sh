#!/usr/bin/env bash
# ==============================================================================
# test-image.sh
# Verifies that a pre-seeded PostgreSQL Docker image (netbox-postgres-seeded:<ver>)
# boots in ~1s and NetBox starts without migrations, passing API authentication.
# ==============================================================================
set -euo pipefail

TARGET="${1:-latest}"
PORT="${2:-8001}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Resolve image and NetBox version
if [[ "${TARGET}" == *":"* ]] || [[ "${TARGET}" == *"/"* ]]; then
  IMAGE="${TARGET}"
  # Extract version tag after the colon
  NETBOX_VERSION="${TARGET##*:}"
else
  NETBOX_VERSION="${TARGET}"
  IMAGE="netbox-postgres-seeded:${NETBOX_VERSION}"
  # If local tag doesn't exist, check if image exists in GHCR format
  if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    if [ -n "${REGISTRY_IMAGE:-}" ]; then
      IMAGE="${REGISTRY_IMAGE}:${NETBOX_VERSION}"
    elif [ -n "${GITHUB_REPOSITORY:-}" ]; then
      OWNER_LOWER="$(echo "${GITHUB_REPOSITORY_OWNER:-${GITHUB_REPOSITORY%%/*}}" | tr '[:upper:]' '[:lower:]')"
      IMAGE="ghcr.io/${OWNER_LOWER}/netbox-postgres-seeded:${NETBOX_VERSION}"
    fi
  fi
fi

# Ensure version has 'v' prefix if not latest
if [ "${NETBOX_VERSION}" != "latest" ] && [[ "${NETBOX_VERSION}" =~ ^[0-9] ]]; then
  NETBOX_VERSION="v${NETBOX_VERSION}"
fi

echo "======================================================================"
echo " Testing Seeded PostgreSQL Docker Image"
echo " NetBox Version : ${NETBOX_VERSION}"
echo " Docker Image   : ${IMAGE}"
echo " Test Port      : ${PORT}"
echo "======================================================================"

# Verify image exists locally or in registry
echo "🔍 [1/4] Checking Docker image availability..."
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "Image '${IMAGE}' not found locally. Attempting to pull..."
  if ! docker pull "${IMAGE}"; then
    echo "❌ Error: Docker image '${IMAGE}' is not available locally or in registry!"
    echo "   Run './scripts/build-seeded-db.sh ${NETBOX_VERSION}' first to build it."
    exit 1
  fi
fi
echo "✅ Docker image verified: ${IMAGE}"

PROJECT_NAME="netbox_imgtest_$(date +%s)_${RANDOM}"
TMP_DIR="/tmp/${PROJECT_NAME}"
mkdir -p "${TMP_DIR}"

cleanup() {
  echo "🧹 [Cleanup] Stopping and removing temporary image test containers..."
  docker compose -p "${PROJECT_NAME}" -f "${TMP_DIR}/docker-compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "${TMP_DIR}" || true
}
trap cleanup EXIT

# Generate temporary compose file using the seeded image
cat <<EOF > "${TMP_DIR}/docker-compose.yml"
services:
  postgres:
    image: ${IMAGE}
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
      - /var/lib/postgresql:size=512m
    healthcheck:
      test: pg_isready -q -d netbox -U netbox
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
      valkey:
        condition: service_started
    ports:
      - "${PORT}:8080"
    environment:
      DB_HOST: postgres
      DB_NAME: netbox
      DB_USER: netbox
      DB_PASSWORD: netboxpassword
      REDIS_HOST: valkey
      REDIS_CACHE_HOST: valkey
      SECRET_KEY: "dummy-key-for-test-pipeline-environment-only-minimum-50-chars"
      API_TOKEN_PEPPER_1: "Qy+F=OTeGskWQ(wTMgjc+NPPlz6YwFXY=KHIIg=wpYXT&e(6u8"
      SKIP_SUPERUSER: "true"
      DB_WAIT_TIMEOUT: 1
    healthcheck:
      test: curl -sf http://localhost:8080/login/ >/dev/null || exit 1
      interval: 2s
      timeout: 3s
      retries: 30
EOF

# Start stack with pre-seeded postgres image
echo "🚀 [2/4] Starting test stack with seeded postgres image..."
START_TIME=$(date +%s)
docker compose -p "${PROJECT_NAME}" -f "${TMP_DIR}/docker-compose.yml" up -d

echo "⏳ [3/4] Waiting for NetBox to finish initialization..."
MAX_WAIT="${IMAGE_TEST_TIMEOUT:-120}"
ELAPSED=0
NETBOX_CID=$(docker compose -p "${PROJECT_NAME}" -f "${TMP_DIR}/docker-compose.yml" ps -q netbox)
PG_CID=$(docker compose -p "${PROJECT_NAME}" -f "${TMP_DIR}/docker-compose.yml" ps -q postgres)

until [ "$(docker inspect -f '{{.State.Health.Status}}' "${NETBOX_CID}")" == "healthy" ]; do
  # Check if postgres container exited prematurely
  PG_STATUS=$(docker inspect -f '{{.State.Status}}' "${PG_CID}" 2>/dev/null || echo "unknown")
  if [ "${PG_STATUS}" == "exited" ] || [ "${PG_STATUS}" == "dead" ]; then
    echo ""
    echo "❌ PostgreSQL container exited unexpectedly!"
    docker compose -p "${PROJECT_NAME}" -f "${TMP_DIR}/docker-compose.yml" logs postgres
    exit 1
  fi

  # Check if NetBox container exited prematurely
  NETBOX_STATUS=$(docker inspect -f '{{.State.Status}}' "${NETBOX_CID}" 2>/dev/null || echo "unknown")
  if [ "${NETBOX_STATUS}" == "exited" ] || [ "${NETBOX_STATUS}" == "dead" ]; then
    echo ""
    echo "❌ NetBox container exited unexpectedly!"
    docker compose -p "${PROJECT_NAME}" -f "${TMP_DIR}/docker-compose.yml" logs netbox
    exit 1
  fi

  sleep 1
  ELAPSED=$((ELAPSED + 1))
  if [ "${ELAPSED}" -ge "${MAX_WAIT}" ]; then
    echo ""
    echo "❌ Timeout waiting for NetBox to become healthy with seeded image!"
    docker compose -p "${PROJECT_NAME}" -f "${TMP_DIR}/docker-compose.yml" logs
    exit 1
  fi
  printf "."
done
echo ""
END_TIME=$(date +%s)
TOTAL_STARTUP=$((END_TIME - START_TIME))
echo "✅ NetBox is healthy! (Total startup time: ${TOTAL_STARTUP}s)"

# Verify API and token
echo "📡 [4/4] Verifying NetBox API & credentials..."
"${REPO_ROOT}/examples/test-api.sh" "http://127.0.0.1:${PORT}"

echo "======================================================================"
echo "🎉 SUCCESS: Seeded Image '${IMAGE}' is 100% valid and operational!"
echo "   NetBox Version : ${NETBOX_VERSION}"
echo "   Startup Time   : ${TOTAL_STARTUP}s"
echo "======================================================================"
