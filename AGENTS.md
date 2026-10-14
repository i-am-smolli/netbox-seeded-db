# AGENTS.md — Maintenance & Coding Guide

This document is for AI coding agents and human developers maintaining this repository.

---

## 1. Project Purpose & Core Architecture

The purpose of this repository is to solve the **NetBox startup bottleneck** in CI/CD pipelines.

### The Problem
When running NetBox in ephemeral test environments (GitHub Actions, GitLab CI, Docker-in-Docker), a blank PostgreSQL instance is initialized on every run. NetBox's `docker-entrypoint.sh` executes Django migrations across all modules (`manage.py migrate`), generates search indexes, and runs initializers. This process takes **2 to 4 minutes** on CI disk I/O.

### The Solution
This repository builds and publishes a **public pre-seeded PostgreSQL Docker image** on GitHub Container Registry (`ghcr.io/<owner>/netbox-postgres-seeded:<version>`) and a compressed SQL dump (`netbox-<version>.sql.gz`) on GitHub Releases for every released NetBox version.
When downstream pipelines use this seeded database image instead of standard `postgres:alpine`:
- Postgres starts in **1 second** and applies the dump immediately.
- NetBox detects that all migrations already exist (`manage.py migrate --check` returns 0).
- The entire 2-minute migration and indexing block is skipped.
- NetBox starts in **~20 seconds** (saving 2–3 minutes on every run).

---

## 2. Repository Layout

```
.
├── .github/
│   └── workflows/
│       └── build-and-publish.yml     # GitHub Actions: Detects releases, builds, tests, pushes to GHCR & creates GitHub Releases
├── .gitlab-ci.yml                    # GitLab CI pipeline fallback
├── .gitignore                        # Excludes /dist, dumps, temporary files
├── Dockerfile                        # PostgreSQL image template embedding dump.sql.gz (with OCI annotations)
├── LICENSE                           # Mozilla Public License 2.0 (MPL-2.0)
├── README.md                         # Public documentation and consumption instructions
├── AGENTS.md                         # This file
├── scripts/
│   ├── build-seeded-db.sh            # Starts NetBox in tmpfs, dumps DB, builds Docker image
│   ├── check-new-versions.sh         # Compares upstream GitHub releases vs repository releases
│   └── test-dump.sh                  # Tests raw SQL dump against vanilla postgres + NetBox
└── examples/
    ├── consumer-docker-compose.yml      # Drop-in compose using seeded Docker image (Option A)
    ├── consumer-dump-docker-compose.yml # Drop-in compose using raw SQL dump (Option B)
    ├── consumer-github-actions.yml      # Complete GitHub Actions example for test pipelines
    ├── consumer-gitlab-ci.yml           # Complete GitLab CI example for test pipelines
    └── test-api.sh                      # Smoke-test script verifying API & token
```

---

## 3. Critical Conventions & Design Rules

### A. Predictable Test Credentials
Do not randomize or remove the default test superuser credentials in `scripts/build-seeded-db.sh`.
Downstream pipelines rely on:
- **Username**: `admin`
- **Password**: `uchae4uSeiYah5roe7gauYaer`
- **API Token (NetBox >= 4.5)**: `nbt_haiweeni2Aiv.ahgeechahdaighah6queivoo6ahChahgo2ohch9inahyei5ahk`
- **API Token Pepper (NetBox >= 4.5)**: `Qy+F=OTeGskWQ(wTMgjc+NPPlz6YwFXY=KHIIg=wpYXT&e(6u8`
- **API Token (NetBox < 4.5)**: `0123456789abcdef0123456789abcdef01234567` (Auth header: `Token <token>`)
*(These exact credentials match the official `netbox-docker` test configuration across versions).*

### B. PostgreSQL Auto-Import Mechanism
The official PostgreSQL Docker image entrypoint natively supports `.sql.gz` files inside `/docker-entrypoint-initdb.d/`.
- During build, the dump is named `/docker-entrypoint-initdb.d/01-netbox.sql.gz`.
- Do not extract the file during build; keeping it gzipped keeps the Docker image layers small (~60MB compressed).

### C. RAM Execution (`tmpfs`)
When running `build-seeded-db.sh`:
- Always mount `/var/lib/postgresql` on `tmpfs`.
- Always set `-c fsync=off -c synchronous_commit=off -c full_page_writes=off` on PostgreSQL.
This reduces the dump build time from ~120s down to ~15-20s.

### D. Downstream Optimization Requirements
When assisting users with consuming the seeded image, ensure they:
1. Set `SKIP_SUPERUSER: "true"` on NetBox (skips python shell execution).
2. Set `DB_WAIT_TIMEOUT: 1` on NetBox.
3. Keep `tmpfs` enabled for Postgres in test jobs.
4. Set `API_TOKEN_PEPPER_1: "Qy+F=OTeGskWQ(wTMgjc+NPPlz6YwFXY=KHIIg=wpYXT&e(6u8"` when NetBox >= 4.5 is used.

### E. GitHub Container Registry (GHCR) Conventions
- Docker image repository names on GHCR must be strictly lowercase (e.g. `ghcr.io/owner/netbox-postgres-seeded`). Always sanitize strings with `tr '[:upper:]' '[:lower:]'`.
- All images are public and can be pulled anonymously by downstream pipelines without `docker login`.
- Set `org.opencontainers.image.source` label to link packages automatically to the GitHub repository.

---

## 4. Scripting & Quality Standards

- All bash scripts must use `set -euo pipefail`.
- Always use `trap cleanup EXIT` to prevent orphaned Docker containers in CI runners.
- Do not introduce Python or Node.js dependencies in the base runner images; rely only on `bash`, `curl`, `jq`, `docker`, and `docker-compose`.
