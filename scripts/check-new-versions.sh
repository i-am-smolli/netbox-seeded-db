#!/usr/bin/env bash
# ==============================================================================
# check-new-versions.sh
#
# Compares releases from GitHub (netbox-community/netbox) against existing
# releases / tags in this repository.
# Supports GitHub Actions, GitLab CI, and local dry-run execution.
# ==============================================================================
set -euo pipefail

GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
CI_PROJECT_ID="${CI_PROJECT_ID:-}"
CI_JOB_TOKEN="${CI_JOB_TOKEN:-}"
CI_API_V4_URL="${CI_API_V4_URL:-https://gitlab.com/api/v4}"
CI_COMMIT_REF_NAME="${CI_COMMIT_REF_NAME:-main}"
MIN_VERSION="${MIN_VERSION:-v4.4.10}"
MAX_CHECK_RELEASES="${MAX_CHECK_RELEASES:-50}"
FORCE_VERSION="${1:-${FORCE_VERSION:-}}"

echo "======================================================================"
echo " Checking for New NetBox Upstream Releases"
echo " Upstream Target  : netbox-community/netbox"
echo " Minimum Version  : ${MIN_VERSION}"
if [ -n "${GITHUB_REPOSITORY}" ]; then
  echo " GitHub Target Repo : ${GITHUB_REPOSITORY}"
fi
echo "======================================================================"

CURL_CMD=(curl -s)
if [ -n "${GITHUB_TOKEN}" ]; then
  CURL_CMD+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

echo "🔍 Fetching stable releases from netbox-community/netbox (down to ${MIN_VERSION})..."
UPSTREAM_RELEASES=$("${CURL_CMD[@]}" "https://api.github.com/repos/netbox-community/netbox/releases?per_page=100" \
  | jq -r --arg min "${MIN_VERSION}" --argjson limit "${MAX_CHECK_RELEASES}" '
      [.[] | select(.prerelease == false) | .tag_name] as $all
      | ($all | index($min)) as $idx
      | if ($min != "" and $idx != null) then $all[0:($idx + 1)]
        elif ($limit > 0) then $all[0:$limit]
        else $all
        end
      | .[]')

if [ -z "${UPSTREAM_RELEASES}" ]; then
  echo "❌ Failed to fetch upstream releases from GitHub."
  exit 1
fi

LATEST_UPSTREAM=$(echo "${UPSTREAM_RELEASES}" | head -n 1)
echo "📋 Upstream versions found:"
echo "${UPSTREAM_RELEASES}"
echo "--------------------------------------------------"

MISSING_VERSIONS=""

# If a specific version was requested (and not 'all-missing')
if [ -n "${FORCE_VERSION}" ] && [ "${FORCE_VERSION}" != "all-missing" ]; then
  echo "🎯 Specific version requested: ${FORCE_VERSION}"
  MISSING_VERSIONS="${FORCE_VERSION}"
else
  # Fetch existing releases in THIS GitHub repository
  EXISTING_TAGS=""
  if [ -n "${GITHUB_REPOSITORY}" ]; then
    echo "🔍 Fetching existing releases from GitHub repo: ${GITHUB_REPOSITORY}..."
    EXISTING_TAGS=$("${CURL_CMD[@]}" "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases?per_page=100" \
      | jq -r '.[].tag_name' 2>/dev/null || true)
  elif [ -n "${CI_PROJECT_ID}" ] && [ -n "${CI_JOB_TOKEN}" ]; then
    echo "🔍 Fetching existing tags from GitLab Registry..."
    EXISTING_TAGS=$(curl -s --header "JOB-TOKEN: ${CI_JOB_TOKEN}" \
      "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/registry/repositories" \
      | jq -r '.[0].tags[]?.name' 2>/dev/null || true)
  else
    echo "ℹ️ Running in local/dry-run mode (no repository credentials provided)."
  fi

  for VERSION in ${UPSTREAM_RELEASES}; do
    if [ -n "${EXISTING_TAGS}" ] && echo "${EXISTING_TAGS}" | grep -q "^${VERSION}$"; then
      echo "✅ Version ${VERSION} already released. Skipping."
    else
      echo "⚡ Version ${VERSION} is MISSING!"
      MISSING_VERSIONS="${MISSING_VERSIONS} ${VERSION}"
    fi
  done
  MISSING_VERSIONS=$(echo "${MISSING_VERSIONS}" | xargs)
fi

echo "--------------------------------------------------"
if [ -z "${MISSING_VERSIONS}" ]; then
  echo "🎉 All versions are up to date! Nothing to build."
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "has_versions=false" >> "${GITHUB_OUTPUT}"
    echo "versions=[]" >> "${GITHUB_OUTPUT}"
  fi
  exit 0
fi

echo "🚀 Versions to build: ${MISSING_VERSIONS}"

# Format as JSON array for GitHub Actions matrix (e.g. ["v4.7.3", "v4.7.2"])
VERSIONS_JSON=$(echo "${MISSING_VERSIONS}" | tr ' ' '\n' | jq -R . | jq -s -c .)

# Export outputs for GitHub Actions
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "has_versions=true" >> "${GITHUB_OUTPUT}"
  echo "versions=${VERSIONS_JSON}" >> "${GITHUB_OUTPUT}"
  echo "latest_upstream=${LATEST_UPSTREAM}" >> "${GITHUB_OUTPUT}"
fi

# GitLab CI pipeline trigger fallback
if [ -n "${CI_PROJECT_ID}" ] && [ -n "${CI_JOB_TOKEN}" ]; then
  for VERSION in ${MISSING_VERSIONS}; do
    echo "⚡ Triggering GitLab build pipeline for ${VERSION}..."
    curl -s --request POST \
      --form "token=${CI_JOB_TOKEN}" \
      --form "ref=${CI_COMMIT_REF_NAME}" \
      --form "variables[BUILD_VERSION]=${VERSION}" \
      "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/trigger/pipeline" > /dev/null
    echo "🚀 Triggered pipeline for ${VERSION}"
  done
fi
