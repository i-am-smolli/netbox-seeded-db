#!/usr/bin/env bash
# ==============================================================================
# test-dump.sh
# Verifies that a raw PostgreSQL dump (netbox-<version>.sql.gz) correctly
# initializes a vanilla PostgreSQL instance and NetBox starts without migrations.
# ==============================================================================
set -euo pipefail

TARGET="${1:-latest}"
PORT="${2:-8001}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Resolve dump file and NetBox version
if [ -f "${TARGET}" ]; then
  DUMP_FILE="$(cd "$(dirname "${TARGET}")" && pwd)/$(basename "${TARGET}")"
  # Extract version from filename pattern netbox-<version>.sql.gz
  NETBOX_VERSION="$(basename "${DUMP_FILE}" | sed -E 's/^netbox-(.+)\.sql\.gz$/\1/')"
else
  NETBOX_VERSION="${TARGET}"
  DUMP_FILE="${REPO_ROOT}/dist/netbox-${NETBOX_VERSION}.sql.gz"
fi

if [ ! -f "${DUMP_FILE}" ]; then
  echo "❌ Error: Dump file not found: ${DUMP_FILE}"
  echo "   Run './scripts/build-seeded-db.sh ${NETBOX_VERSION}' first to generate the dump."
  exit 1
fi

echo "======================================================================"
echo " Testing Raw PostgreSQL Dump"
echo " NetBox Version : ${NETBOX_VERSION}"
echo " Dump File      : ${DUMP_FILE} ($(du -h "${DUMP_FILE}" | cut -f1))"
echo " Test Port      : ${PORT}"
echo "======================================================================"

# 1. Verify gzip integrity
echo "🔍 [1/4] Verifying gzip archive integrity..."
if ! gzip -t "${DUMP_FILE}"; then
  echo "❌ Error: Corrupt gzip archive: ${DUMP_FILE}"
  exit 1
fi
echo "✅ Dump archive integrity verified."

PROJECT_NAME="netbox_dumptest_$(date +%s)_${RANDOM}"
TMP_DIR="/tmp/${PROJECT_NAME}"
mkdir -p "${TMP_DIR}"

cleanup() {
  echo "🧹 [Cleanup] Stopping and removing temporary dump test containers..."
  docker compose -p "${PROJECT_NAME}" -f "${TMP_DIR}/docker-compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "${TMP_DIR}" || true
}
trap cleanup EXIT

# 2. Generate temporary compose file using vanilla postgres + mounted dump
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
    volumes:
      - "${DUMP_FILE}:/docker-entrypoint-initdb.d/01-netbox.sql.gz:ro"
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

# 3. Start stack with vanilla postgres + mounted dump
echo "🚀 [2/4] Starting test stack with vanilla postgres & mounted dump..."
START_TIME=$(date +%s)
docker compose -p "${PROJECT_NAME}" -f "${TMP_DIR}/docker-compose.yml" up -d

echo "⏳ [3/4] Waiting for NetBox to finish initialization..."
MAX_WAIT="${DUMP_TEST_TIMEOUT:-120}"
ELAPSED=0
NETBOX_CID=$(docker compose -p "${PROJECT_NAME}" -f "${TMP_DIR}/docker-compose.yml" ps -q netbox)
PG_CID=$(docker compose -p "${PROJECT_NAME}" -f "${TMP_DIR}/docker-compose.yml" ps -q postgres)

until [ "$(docker inspect -f '{{.State.Health.Status}}' "${NETBOX_CID}")" == "healthy" ]; do
  # Check if postgres container exited prematurely (e.g. dump import error)
  PG_STATUS=$(docker inspect -f '{{.State.Status}}' "${PG_CID}" 2>/dev/null || echo "unknown")
  if [ "${PG_STATUS}" == "exited" ] || [ "${PG_STATUS}" == "dead" ]; then
    echo ""
    echo "❌ PostgreSQL container exited unexpectedly during dump import!"
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
    echo "❌ Timeout waiting for NetBox to become healthy with dump!"
    docker compose -p "${PROJECT_NAME}" -f "${TMP_DIR}/docker-compose.yml" logs
    exit 1
  fi
  printf "."
done
echo ""
END_TIME=$(date +%s)
TOTAL_STARTUP=$((END_TIME - START_TIME))
echo "✅ NetBox is healthy! (Total startup time: ${TOTAL_STARTUP}s)"

# 4. Verify API and token
echo "📡 [4/4] Verifying NetBox API & credentials..."
"${REPO_ROOT}/examples/test-api.sh" "http://127.0.0.1:${PORT}"

echo "======================================================================"
echo "🎉 SUCCESS: Dump '${DUMP_FILE}' is 100% valid and operational!"
echo "   NetBox Version : ${NETBOX_VERSION}"
echo "   Startup Time   : ${TOTAL_STARTUP}s"
echo "======================================================================"
