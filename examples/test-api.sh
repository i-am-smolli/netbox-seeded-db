#!/usr/bin/env bash
# ==============================================================================
# test-api.sh
# Smoke test script to verify NetBox API responsiveness and token authentication.
# ==============================================================================
set -euo pipefail

NETBOX_URL="${1:-http://127.0.0.1:8000}"
USER_TOKEN="${2:-}"

echo "Testing NetBox API at ${NETBOX_URL}..."

# 0. Check if NetBox is reachable (with short retry loop for server startup)
MAX_WAIT=15
WAIT_COUNT=0
CONNECT_ERR=""
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  if CONNECT_ERR=$(curl -sS --connect-timeout 2 --max-time 3 "${NETBOX_URL}/" 2>&1 >/dev/null); then
    break
  fi
  sleep 1
  WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
  echo "❌ Error: Cannot connect to NetBox at ${NETBOX_URL} after ${MAX_WAIT}s!"
  echo "   ${CONNECT_ERR}"
  echo "   (Make sure the NetBox container is running: e.g. docker compose -f examples/consumer-docker-compose.yml up -d)"
  exit 1
fi

# 1. Test basic API status & detect version
STATUS_RESPONSE=$(curl -s \
  --connect-timeout 5 \
  --max-time 10 \
  -H "Authorization: Bearer nbt_haiweeni2Aiv.ahgeechahdaighah6queivoo6ahChahgo2ohch9inahyei5ahk" \
  -H "Accept: application/json" \
  "${NETBOX_URL}/api/status/" || true)


if ! echo "${STATUS_RESPONSE}" | grep -q "netbox-version"; then
  # Fallback for legacy versions (< 4.5) with LOGIN_REQUIRED
  STATUS_RESPONSE=$(curl -s \
    --connect-timeout 5 \
    --max-time 10 \
    -H "Authorization: Token 0123456789abcdef0123456789abcdef01234567" \
    -H "Accept: application/json" \
    "${NETBOX_URL}/api/status/" || true)
fi

if ! echo "${STATUS_RESPONSE}" | grep -q "netbox-version"; then
  # Fallback without authentication
  STATUS_RESPONSE=$(curl -s \
    --connect-timeout 5 \
    --max-time 10 \
    -H "Accept: application/json" \
    "${NETBOX_URL}/api/status/" || true)
fi

if ! echo "${STATUS_RESPONSE}" | grep -q "netbox-version"; then
  echo "❌ Error: Could not retrieve API status from NetBox:"
  echo "${STATUS_RESPONSE}"
  exit 1
fi

VERSION=$(echo "${STATUS_RESPONSE}" | grep -o '"netbox-version":"[^"]*' | cut -d'"' -f4)
echo "✅ NetBox is responsive (Version: ${VERSION})"

# 2. Select appropriate token based on user input or detected NetBox version
if [ -n "${USER_TOKEN}" ]; then
  TOKEN="${USER_TOKEN}"
  if [[ "${TOKEN}" == nbt_* ]]; then
    AUTH_PREFIX="Bearer"
  else
    AUTH_PREFIX="Token"
  fi
else
  # Auto-detect token based on version:
  # NetBox < 4.5 uses v1 tokens (40-char hex); >= 4.5 uses v2 tokens (nbt_*)
  if [[ "${VERSION}" =~ ^3\. ]] || [[ "${VERSION}" =~ ^4\.[0-4](\.|$) ]]; then
    TOKEN="0123456789abcdef0123456789abcdef01234567"
    AUTH_PREFIX="Token"
  else
    TOKEN="nbt_haiweeni2Aiv.ahgeechahdaighah6queivoo6ahChahgo2ohch9inahyei5ahk"
    AUTH_PREFIX="Bearer"
  fi
fi

# 3. Test token authentication on protected endpoint
echo "🔑 Verifying API superuser token (${AUTH_PREFIX})..."
AUTH_RESPONSE=$(curl -s \
  --connect-timeout 5 \
  --max-time 10 \
  -H "Authorization: ${AUTH_PREFIX} ${TOKEN}" \
  -H "Accept: application/json" \
  "${NETBOX_URL}/api/users/users/" || true)

if echo "${AUTH_RESPONSE}" | grep -q '"username":"admin"'; then
  echo "✅ Token authentication successful! Authenticated as 'admin' superuser."
  exit 0
else
  echo "❌ Error: Token authentication failed:"
  echo "${AUTH_RESPONSE}"
  exit 1
fi
