# ICC 2026 Version Control Workshop

Demo stack for the Inductive Automation ICC 2026 workshop on version control and
deployment modes in Ignition. It spins up a pair of Ignition gateways (`dev` and
`prod`) each in a different `ignition.config.mode`, backed by their own Postgres
databases, so you can practice a Git-based workflow for promoting config and
project changes from dev to prod.

## Stack

- **`demo-vcs-modes-dev`** — Ignition gateway running in `dev` config mode
- **`demo-vcs-modes-prod`** — Ignition gateway running in `prod` config mode
- **`postgres-dev`** / **`postgres-prod`** — Postgres 15 databases, one per gateway

Gateway config and projects are bind-mounted from `services/dev` and
`services/prod` respectively, so changes made in the gateway (or checked out via
Git) show up on disk and vice versa.

## Prerequisites

- Docker and Docker Compose

## Getting started

```bash
cp .env.example .env
# adjust ports/credentials in .env if needed
docker compose up -d
```

Gateways are available at:

- Dev: `http://localhost:${IGN_PORT_DEV:-8188}`
- Prod: `http://localhost:${IGN_PORT_PROD:-8189}`

Default gateway login is `admin` / `password`.

## Repo layout

```
docker-compose.yaml   Compose stack (gateways + Postgres)
dockerfile            Builds an Ignition image with services/ baked in
services/dev/         Config resources and projects for the dev gateway
services/prod/        Config resources and projects for the prod gateway
.github/workflows/    Release and deploy automation
```

## GitHub Actions

- **1. Create Release** (`create-release.yml`) — manually triggered; tags the
  repo (auto-generated `yyyy.mm.dd.hh.ss` version or a custom one) and creates a
  GitHub release with the commit log since the last release.
- **2. Deploy to Prod** (`deploy-to-prod.yml`) — manually triggered; checks out a
  release tag on the self-hosted prod runner and hits the Ignition Gateway API
  to trigger a config/project rescan.
