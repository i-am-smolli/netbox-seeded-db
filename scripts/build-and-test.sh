#!/usr/bin/env bash
# ==============================================================================
# build-and-test.sh
#
# Multi-version verification tool for netbox-seeded-db.
# Builds the pre-seeded PostgreSQL Docker image and compressed SQL dump for one
# or multiple NetBox versions, and thoroughly tests BOTH artifacts against
# vanilla NetBox to guarantee backwards compatibility and prevent regressions.
#
# Usage:
#   ./scripts/build-and-test.sh <version1> [version2] [version3]...
#   ./scripts/build-and-test.sh "v4.5.0, v4.4.10, v4.5.10"
#   ./scripts/build-and-test.sh --skip-build v4.5.0 v4.5.10
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ------------------------------------------------------------------------------
# Help & Usage
# ------------------------------------------------------------------------------
show_help() {
  cat <<'EOF'
Usage:
  ./scripts/build-and-test.sh [OPTIONS] <version1> [version2] ...

Arguments:
  <version>...          One or more NetBox versions (e.g. v4.5.10, v4.5.0, v4.4.10)
                        Accepts space-separated or comma-separated versions.

Options:
  --skip-build          Skip the build step; only test existing dumps and images.
  --skip-dump-test      Skip testing the raw SQL dump against vanilla PostgreSQL.
  --skip-image-test     Skip testing the pre-seeded Docker image.
  --fail-fast           Stop immediately on the first failed version. Default is to
                        run all versions and display a full summary matrix report.
  -h, --help            Show this help message and exit.

Examples:
  ./scripts/build-and-test.sh v4.5.10
  ./scripts/build-and-test.sh v4.5.0 v4.4.10 v4.5.10
  ./scripts/build-and-test.sh "v4.5.0, v4.4.10, v4.5.10"
  ./scripts/build-and-test.sh --skip-build v4.5.0 v4.5.10
EOF
}

# ------------------------------------------------------------------------------
# Flags & Arguments Parsing
# ------------------------------------------------------------------------------
DO_BUILD=true
DO_DUMP_TEST=true
DO_IMAGE_TEST=true
FAIL_FAST=false
RAW_VERSIONS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    --skip-build)
      DO_BUILD=false
      shift
      ;;
    --skip-dump-test)
      DO_DUMP_TEST=false
      shift
      ;;
    --skip-image-test)
      DO_IMAGE_TEST=false
      shift
      ;;
    --fail-fast)
      FAIL_FAST=true
      shift
      ;;
    *)
      # Split on commas and spaces
      IFS=', ' read -r -a SPLIT_ARGS <<< "$1"
      for arg in "${SPLIT_ARGS[@]}"; do
        if [ -n "${arg}" ]; then
          RAW_VERSIONS+=("${arg}")
        fi
      done
      shift
      ;;
  esac
done

if [ ${#RAW_VERSIONS[@]} -eq 0 ]; then
  echo "❌ Error: No NetBox versions specified!"
  echo ""
  show_help
  exit 1
fi

# ------------------------------------------------------------------------------
# Normalize Versions
# ------------------------------------------------------------------------------
VERSIONS=()
for v in "${RAW_VERSIONS[@]}"; do
  # Remove whitespace and surrounding quotes
  norm=$(echo "${v}" | tr -d '", \t\r\n')
  # Fix typos like v.4.7.3 -> v4.7.3
  norm="${norm//v./v}"
  # Ensure leading 'v' for semantic versions (e.g. 4.5.0 -> v4.5.0)
  if [[ "${norm}" =~ ^[0-9] ]]; then
    norm="v${norm}"
  fi
  if [ -n "${norm}" ]; then
    VERSIONS+=("${norm}")
  fi
done

# Helper to find a free TCP port
get_free_port() {
  local port="${1:-8010}"
  while lsof -Pi :"$port" -sTCP:LISTEN -t >/dev/null 2>&1; do
    port=$((port + 1))
  done
  echo "$port"
}

TOTAL_COUNT=${#VERSIONS[@]}
START_PORT=8010

echo "======================================================================"
echo " 🚀 NetBox Multi-Version Build & Test Suite"
echo " Versions to test : ${VERSIONS[*]} (${TOTAL_COUNT} total)"
echo " Build Image/Dump : $([ "${DO_BUILD}" = true ] && echo "YES" || echo "SKIP")"
echo " Test Raw Dump    : $([ "${DO_DUMP_TEST}" = true ] && echo "YES" || echo "SKIP")"
echo " Test Seeded Image: $([ "${DO_IMAGE_TEST}" = true ] && echo "YES" || echo "SKIP")"
echo " Fail Fast        : $([ "${FAIL_FAST}" = true ] && echo "YES" || echo "NO (full matrix)")"
echo "======================================================================"
echo ""

# Tracking arrays for summary table
RESULT_VERSIONS=()
RESULT_BUILD=()
RESULT_DUMP=()
RESULT_IMAGE=()
RESULT_TIME=()
RESULT_STATUS=()

GLOBAL_START_TIME=$(date +%s)
OVERALL_SUCCESS=true

# ------------------------------------------------------------------------------
# Execute Matrix
# ------------------------------------------------------------------------------
CURRENT_INDEX=0
for VER in "${VERSIONS[@]}"; do
  CURRENT_INDEX=$((CURRENT_INDEX + 1))
  VER_START_TIME=$(date +%s)

  echo ""
  echo "======================================================================"
  echo " [${CURRENT_INDEX}/${TOTAL_COUNT}] Processing NetBox ${VER}"
  echo "======================================================================"

  BUILD_STATUS="SKIPPED"
  DUMP_STATUS="SKIPPED"
  IMAGE_STATUS="SKIPPED"
  VER_FAILED=false

  # Step 1: Build Seeded DB & Image
  if [ "${DO_BUILD}" = true ]; then
    echo "🔨 [Phase 1/3] Building Seeded Database Image & Dump for ${VER}..."
    BUILD_STEP_START=$(date +%s)
    if "${REPO_ROOT}/scripts/build-seeded-db.sh" "${VER}"; then
      BUILD_STEP_DUR=$(($(date +%s) - BUILD_STEP_START))
      BUILD_STATUS="PASS (${BUILD_STEP_DUR}s)"
      echo "✅ Build completed successfully for ${VER}."
    else
      BUILD_STEP_DUR=$(($(date +%s) - BUILD_STEP_START))
      BUILD_STATUS="FAIL (${BUILD_STEP_DUR}s)"
      VER_FAILED=true
      echo "❌ Build FAILED for ${VER}."
    fi
  fi

  # Step 2: Test Raw Dump (Vanilla Postgres + SQL Dump)
  if [ "${DO_DUMP_TEST}" = true ] && [ "${VER_FAILED}" = false ]; then
    DUMP_PORT=$(get_free_port "${START_PORT}")
    START_PORT=$((DUMP_PORT + 1))
    echo "🧪 [Phase 2/3] Testing Raw SQL Dump on port ${DUMP_PORT} for ${VER}..."
    DUMP_STEP_START=$(date +%s)
    if "${REPO_ROOT}/scripts/test-dump.sh" "${VER}" "${DUMP_PORT}"; then
      DUMP_STEP_DUR=$(($(date +%s) - DUMP_STEP_START))
      DUMP_STATUS="PASS (${DUMP_STEP_DUR}s)"
      echo "✅ Dump verification passed for ${VER}."
    else
      DUMP_STEP_DUR=$(($(date +%s) - DUMP_STEP_START))
      DUMP_STATUS="FAIL (${DUMP_STEP_DUR}s)"
      VER_FAILED=true
      echo "❌ Dump verification FAILED for ${VER}."
    fi
  fi

  # Step 3: Test Seeded Docker Image
  if [ "${DO_IMAGE_TEST}" = true ] && [ "${VER_FAILED}" = false ]; then
    IMG_PORT=$(get_free_port "${START_PORT}")
    START_PORT=$((IMG_PORT + 1))
    echo "🐳 [Phase 3/3] Testing Seeded Docker Image on port ${IMG_PORT} for ${VER}..."
    IMG_STEP_START=$(date +%s)
    if "${REPO_ROOT}/scripts/test-image.sh" "${VER}" "${IMG_PORT}"; then
      IMG_STEP_DUR=$(($(date +%s) - IMG_STEP_START))
      IMAGE_STATUS="PASS (${IMG_STEP_DUR}s)"
      echo "✅ Seeded image verification passed for ${VER}."
    else
      IMG_STEP_DUR=$(($(date +%s) - IMG_STEP_START))
      IMAGE_STATUS="FAIL (${IMG_STEP_DUR}s)"
      VER_FAILED=true
      echo "❌ Seeded image verification FAILED for ${VER}."
    fi
  fi

  VER_TOTAL_DUR=$(($(date +%s) - VER_START_TIME))

  if [ "${VER_FAILED}" = true ]; then
    OVERALL_SUCCESS=false
    VER_SUMMARY="❌ FAIL"
  else
    VER_SUMMARY="✅ PASS"
  fi

  RESULT_VERSIONS+=("${VER}")
  RESULT_BUILD+=("${BUILD_STATUS}")
  RESULT_DUMP+=("${DUMP_STATUS}")
  RESULT_IMAGE+=("${IMAGE_STATUS}")
  RESULT_TIME+=("${VER_TOTAL_DUR}s")
  RESULT_STATUS+=("${VER_SUMMARY}")

  if [ "${VER_FAILED}" = true ] && [ "${FAIL_FAST}" = true ]; then
    echo "⛔ Fail-fast enabled. Aborting remaining versions."
    break
  fi
done

GLOBAL_TOTAL_DUR=$(($(date +%s) - GLOBAL_START_TIME))

# ------------------------------------------------------------------------------
# Summary Matrix Table
# ------------------------------------------------------------------------------
echo ""
echo "=========================================================================================================="
echo " 🏁 BUILD & TEST MATRIX RESULTS"
echo "=========================================================================================================="
printf "%-12s | %-18s | %-18s | %-18s | %-8s | %-8s\n" "VERSION" "BUILD" "TEST RAW DUMP" "TEST SEEDED IMAGE" "TIME" "STATUS"
echo "-------------+--------------------+--------------------+--------------------+----------+----------"

PASSED_COUNT=0
FAILED_COUNT=0

for i in "${!RESULT_VERSIONS[@]}"; do
  printf "%-12s | %-18s | %-18s | %-18s | %-8s | %-8s\n" \
    "${RESULT_VERSIONS[$i]}" \
    "${RESULT_BUILD[$i]}" \
    "${RESULT_DUMP[$i]}" \
    "${RESULT_IMAGE[$i]}" \
    "${RESULT_TIME[$i]}" \
    "${RESULT_STATUS[$i]}"

  if [[ "${RESULT_STATUS[$i]}" == *"PASS"* ]]; then
    PASSED_COUNT=$((PASSED_COUNT + 1))
  else
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
done

echo "=========================================================================================================="
echo " Total Duration : ${GLOBAL_TOTAL_DUR}s"
echo " Result Summary : ${PASSED_COUNT} passed, ${FAILED_COUNT} failed out of ${TOTAL_COUNT} version(s)"
echo "=========================================================================================================="

if [ "${OVERALL_SUCCESS}" = true ]; then
  echo "🎉 All versions PASSED successfully!"
  exit 0
else
  echo "❌ One or more versions FAILED. See log output above for details."
  exit 1
fi
