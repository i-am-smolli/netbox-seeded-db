# NetBox Seeded Database for CI/CD

[![Build & Publish](https://github.com/i-am-smolli/netbox-seeded-db/actions/workflows/build-and-publish.yml/badge.svg)](https://github.com/i-am-smolli/netbox-seeded-db/actions/workflows/build-and-publish.yml)
[![GitHub Release](https://img.shields.io/github/v/release/i-am-smolli/netbox-seeded-db?include_prereleases&style=flat-square)](https://github.com/i-am-smolli/netbox-seeded-db/releases)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL_2.0-brightgreen.svg?style=flat-square)](LICENSE)
[![Docker Image](https://img.shields.io/badge/GHCR-netbox--postgres--seeded-blue?logo=docker&style=flat-square)](https://github.com/i-am-smolli/netbox-seeded-db/pkgs/container/netbox-postgres-seeded)

> **NetBox startup in CI/CD pipelines: From minutes down to under 5 seconds.**  
> **Public, automated, and free for the open-source NetBox community.**

This repository automatically builds and publishes a **pre-migrated PostgreSQL Docker image** (`ghcr.io`) and a **compressed SQL dump** (`.sql.gz`) for every released NetBox version.

---

## 🎯 The Problem

When running NetBox in ephemeral test environments (GitHub Actions, GitLab CI, local development), an empty PostgreSQL database is initialized by default.
On first boot, NetBox's `docker-entrypoint.sh` executes:
- `./manage.py migrate --no-input` (hundreds of Django migrations sequentially across all apps)
- `./manage.py trace_paths` & `remove_stale_contenttypes`
- `./manage.py reindex --lazy`
- `./manage.py shell < super_user.py`

**The consequence:** Every test job wastes **2 to 4 minutes** just waiting for NetBox to become reachable.

---

## ⚡ The Solution

Instead of starting with an empty `postgres:alpine`, downstream pipelines use the pre-seeded image or dump:

1. PostgreSQL starts in **1 second** and applies the pre-built dump.
2. NetBox runs `./manage.py migrate --check` &rarr; **0 pending migrations**.
3. The 2–3 minute migration and reindexing block is **completely skipped**.
4. NetBox immediately launches the Granian application server.
5. **NetBox is healthy and ready to serve API requests in 3 to 6 seconds!**

---

## 📊 Benchmark

| Metric | Standard Setup | With Seeded DB |
| :--- | :--- | :--- |
| **PostgreSQL Startup** | ~5s | **~1s** |
| **Django Migrations** | ~120s – 180s | **0s** (skipped) |
| **Search Reindex & Init** | ~15s | **0s** (skipped) |
| **Superuser Creation** | ~4s | **0s** (pre-created) |
| **Total NetBox Boot Time** | **~2.5 to 3.5 minutes** | **~3 to 6 seconds** 🚀 |
| **Speedup** | Baseline | **~30x faster** |

---

## 📦 Pre-Configured Test Credentials

Every image and dump comes with a pre-created test superuser and valid API token:

| Credential | NetBox >= 4.5 | NetBox < 4.5 (Legacy) |
| :--- | :--- | :--- |
| **Username** | `admin` | `admin` |
| **Password** | `uchae4uSeiYah5roe7gauYaer` | `uchae4uSeiYah5roe7gauYaer` |
| **Auth Header** | `Authorization: Bearer nbt_haiweeni2Aiv.ahgeechahdaighah6queivoo6ahChahgo2ohch9inahyei5ahk` | `Authorization: Token 0123456789abcdef0123456789abcdef01234567` |
| **Token Pepper** | `Qy+F=OTeGskWQ(wTMgjc+NPPlz6YwFXY=KHIIg=wpYXT&e(6u8` | *None* |

*(These credentials match the upstream official `netbox-docker` test configuration).*

---

## 🚀 How to Use

### Option 1: GitHub Actions (Recommended)

Drop-in workflow snippet for testing Ansible, Terraform, Pytest, or API clients:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Start Pre-Seeded NetBox
        run: |
          docker compose -f examples/consumer-docker-compose.yml up -d

      - name: Wait for NetBox to be healthy
        run: |
          until [ "$(docker inspect -f '{{.State.Health.Status}}' $(docker compose -f examples/consumer-docker-compose.yml ps -q netbox))" == "healthy" ]; do
            sleep 1
          done
          echo "🚀 NetBox is ready in ~4 seconds!"

      - name: Run Tests
        env:
          NETBOX_URL: "http://127.0.0.1:8000"
          NETBOX_TOKEN: "nbt_haiweeni2Aiv.ahgeechahdaighah6queivoo6ahChahgo2ohch9inahyei5ahk"
        run: |
          pytest tests/
```
*(See [examples/consumer-github-actions.yml](examples/consumer-github-actions.yml) for full workflow).*

---

### Option 2: Docker Compose with Public GHCR Image

Pull the public image directly from GitHub Container Registry (no authentication needed!):

```yaml
services:
  postgres:
    # 🌟 Public pre-seeded PostgreSQL image:
    image: ghcr.io/i-am-smolli/netbox-postgres-seeded:latest
    environment:
      POSTGRES_DB: netbox
      POSTGRES_USER: netbox
      POSTGRES_PASSWORD: netboxpassword
    # Ephemeral tuning: Disable fsync & use RAM disk
    command: ["postgres", "-c", "fsync=off", "-c", "synchronous_commit=off"]
    tmpfs:
      - /var/lib/postgresql:size=512m
    healthcheck:
      test: pg_isready -q -d netbox -U netbox
      interval: 1s
      retries: 10

  valkey:
    image: valkey/valkey:9.1-alpine
    command: valkey-server --save "" --appendonly no

  netbox:
    image: docker.io/netboxcommunity/netbox:latest
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
      SECRET_KEY: "dummy-key-for-test-pipeline-environment-only-minimum-50-chars"
      API_TOKEN_PEPPER_1: "Qy+F=OTeGskWQ(wTMgjc+NPPlz6YwFXY=KHIIg=wpYXT&e(6u8"
      # IMPORTANT: Skips superuser creation (already present in database!)
      SKIP_SUPERUSER: "true"
      DB_WAIT_TIMEOUT: 1
    ports:
      - "8000:8080"
```

Start and verify:
```bash
docker compose -f examples/consumer-docker-compose.yml up -d
./examples/test-api.sh http://127.0.0.1:8000
```

---

### Option 3: Download Raw SQL Dump from GitHub Releases

If you prefer to mount a `.sql.gz` dump directly into a vanilla PostgreSQL container:

```bash
# Download the dump for your target version:
curl -fL -o dist/netbox-latest.sql.gz \
  "https://github.com/i-am-smolli/netbox-seeded-db/releases/download/latest/netbox-latest.sql.gz"

# Start compose with mounted dump:
docker compose -f examples/consumer-dump-docker-compose.yml up -d
```
*(The official PostgreSQL image automatically applies any `.sql.gz` placed in `/docker-entrypoint-initdb.d/`)*.

---

### Option 4: GitLab CI

Downstream GitLab CI pipelines can also pull directly from GHCR without credentials:
See [examples/consumer-gitlab-ci.yml](examples/consumer-gitlab-ci.yml).

---

## 🔄 Automated Release Engine

This repository runs completely automated GitHub Actions workflows:

1. **Scheduled Sync (twice daily):**
   - Queries `netbox-community/netbox` via GitHub API.
   - Detects newly published releases.
2. **Build in RAM (tmpfs):**
   - Boots NetBox with all optimizations enabled in memory.
   - Generates clean SQL dump and builds Docker image with OCI annotations.
3. **Automated Smoke Testing:**
   - Starts an ephemeral stack with the newly created dump.
   - Validates that NetBox boots cleanly with **0 pending migrations**.
   - Authenticates against the NetBox API with the pre-seeded superuser token.
4. **Publishing:**
   - Pushes Docker image to **GitHub Container Registry** (`ghcr.io`).
   - Publishes a **GitHub Release** with the compressed SQL dump attached as a release asset.
5. **Manual Trigger (`workflow_dispatch`):**
   - Easily trigger builds for specific NetBox versions (e.g. `v4.7.3` or `latest`) with a single click.

---

## 🛠️ Local Development & Testing

You can build and test images locally on your machine:

```bash
# 1. Build a pre-seeded image for a specific NetBox version (or 'latest')
./scripts/build-seeded-db.sh v4.7.3

# 2. Test the raw SQL dump integrity & boot speed
./scripts/test-dump.sh v4.7.3

# 3. Test API connectivity
./examples/test-api.sh http://127.0.0.1:8001
```

---

## 📄 License

This project is licensed under the [Mozilla Public License 2.0](LICENSE).
