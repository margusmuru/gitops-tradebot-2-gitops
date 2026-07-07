# tradebot-2-gitops — Working Context

GitOps repo that deploys **tradebot-2** (8 Spring Boot backends + Angular UI) to a
self-managed Kubernetes cluster via ArgoCD. Built by putting tradebot onto the
`skeleton-01` GitOps baseline as a practice run for the real Nortal setup. Read `README.md`
for the user-facing docs; this file is the internal state + plan so we don't lose context
between sessions.

## Related repos / paths

- **This repo:** `/Users/margusmuru/Developer/gitlab/gitops/tradebot-2-gitops`
  (remote `https://gitlab.margusm.dev/gitops/tradebot-2-gitops.git`)
- **API (backends):** `/Users/margusmuru/Developer/gitlab/tradebot-2-worktrees/tradebot-2`
  (remote `.../margusmuru/tradebot-2.git`) — Gradle multi-module, Jib images, Liquibase
- **UI (Angular):** `/Users/margusmuru/Developer/gitlab/tradebot-2-ui-worktrees/tradebot-2-ui`
  — nginx-served static build; image `frontend`
- **Skeleton baseline:** `/Users/margusmuru/Developer/gitlab/gitops/skeleton-01`
- **Design doc:** Obsidian note "DevOps - Nortal GitOps redesign" (iCloud DevVault/30 Work/SKAIS)

## Locked architecture decisions

- **Env name:** `tradebot-test` → app ns `tradebot-test-app`, base ns `tradebot-test-base`.
- **Render:** Kustomize+Helm hybrid, in-repo charts (`common-service`, `mfe`), no OCI.
- **Secrets:** ESO + Vault (`vault-kv` ClusterSecretStore). Vault is source of truth.
  Paths: `secret/tradebot-test/<svc>` (DB creds + migrator cred), `secret/tradebot-test/redis`
  (shared), `secret/tradebot-test/kafka/<user>` (per Kafka user).
- **DB:** external Postgres/TimescaleDB, reached via `externalDb.stableDns` ExternalName.
- **Kafka + Redis:** in-cluster under `base/tradebot-test/`. Kafka = Strimzi (KRaft,
  SCRAM-SHA-512, no ACLs, cluster name `tradebot`, bootstrap
  `tradebot-kafka-bootstrap.tradebot-test-base:9092`). Topics are app-managed (NewTopic
  beans) — no KafkaTopic CRs. Redis = one shared StatefulSet `redis.tradebot-test-base:6379`.
- **Migrations:** Liquibase as an ArgoCD **PreSync hook**, templated inside `common-service`
  (`migration.enabled`). Separate **pinned** `migration.tag` (never `latest`), because CI
  builds the migrator only on `database/<svc>/**` changes while the app image builds on any
  service change. Runs as DB superuser `postgres` (separate ESO cred from the app user).
- **Observability:** OTLP push via Micrometer `MANAGEMENT_OTLP_*` props (set through `env:`,
  NOT the chart's `observability.enabled`, which injects agent `OTEL_*` vars the app doesn't
  use). Optional `serviceMonitor` for in-cluster Prometheus.

## Kafka auth: the `k8s` Spring profile (API repo change)

The app hardcodes Kafka `SASL_PLAINTEXT` + `mechanism=PLAIN` in prod; Strimzi's native
KafkaUser auth is SCRAM-SHA-512. Solution: a new **`k8s` Spring profile** activated as
`SPRING_PROFILES_ACTIVE=prod,k8s`. `-prod` is untouched and fully reused; `-k8s` layers on
top and overrides ONLY the SASL mechanism → SCRAM-SHA-512 (protocol stays SASL_PLAINTEXT).
Created in the API repo per service:
- `.properties`: data-service, kraken-ingest, yahoo-ingest, order-management-service
- `.yml`: gateway, bot-engine, user-service
Each references `username="${KAFKA_USERNAME:<user>}" password="${KAFKA_PASSWORD}"`.
`kraken-exec` NOT touched (skeleton, not deployed).

## Service inventory (from API CLAUDE.md + CI + configs)

| Service | Port | context-path | DB | Redis | Kafka user | Migrator |
|---|---|---|---|---|---|---|
| gateway | 8080 | (none) | ✓ **r2dbc** | ✓ | gateway-service | ✓ |
| data-service | 8081 | /data-service | ✓ (Timescale) | ✓ | data-service | ✓ |
| order-management-service | 8082 | /order-management-service | ✓ | ✓ | oms-service | ✓ |
| kraken-ingest | 8083 | (none) | — | — | kraken-ingest | — |
| kraken-exec | 8084 | (none) | — | — | (kraken-exec) | — (CI commented out; skip) |
| yahoo-ingest | 8085 | (none) | — | — | yahoo-ingest | — |
| user-service | 8086 | /user-service | ✓ | ✓ | user-service | ✓ |
| bot-engine | 8087 | /bot-engine | ✓ | ✓ | bot-engine | ✓ |
| UI (frontend) | 80 | — | — | — | — | — (mfe chart) |

Probe path per service = `<context-path>/actuator/health/{liveness,readiness}` (or
`/actuator/...` when no context-path). Images: `$CI_REGISTRY_IMAGE/<service>:<sha>`,
migrators `$CI_REGISTRY_IMAGE/db-migrator-<service>:<sha>`, UI `frontend:<sha>` (UI is a
separate GitLab project → different registry base).

## Current state

**DONE — Phase 0 (scaffold):** copied skeleton → `tradebot-2-gitops`; argocd/ repoURL set;
env renamed `tradebot-test`; RabbitMQ base removed; `whoami` smoke test kept; all
`nortal`/`skais` references purged; README + base README rewritten for tradebot.

**DONE — Phase 1 (platform + reference service):**
- `charts/common-service`: added `templates/migration-job.yaml` (PreSync ExternalSecret
  wave −2 + Job wave −1) and the `migration:` values block.
- `base/tradebot-test/kafka/`: Strimzi `Kafka`+`KafkaNodePool` (KRaft) + 7 `KafkaUser`s +
  `kafka-user-passwords` ExternalSecret (passwords from Vault). Kafka version 3.9.0 /
  metadataVersion 3.9-IV0 — **align to installed Strimzi operator**.
- `base/tradebot-test/redis/`: `redis:7-alpine` StatefulSet (2Gi PVC, `--requirepass` from
  ESO) + Service + `redis-auth` ExternalSecret.
- `environments/tradebot-test/data-service/`: the reference service (kustomization + values).
- API repo: 7 `application-k8s.*` profile files.

Validated: all YAML parses; base dirs render via `kubectl kustomize`. **Full Kustomize+Helm
render NOT validated locally** (no helm/kustomize installed; local helm would be v4 anyway).
It renders on the ArgoCD repo-server, or locally with a helm 3 binary.

## TODO / future plan

1. **Fan out the remaining 6 backends** following `data-service/values.yaml`:
   - DB-backed (migration + Redis + ESO): `user-service`, `gateway`, `order-management-service`,
     `bot-engine`. Set the right port, context-path-aware probe path, Kafka username.
   - **gateway specifics:** reactive (R2DBC, not JDBC — DB URL is `r2dbc:postgresql://...`);
     needs `JWT_SECRET` (ESO) and downstream service URLs (`DATA_SERVICE_URL=http://data-service:8081`,
     `USER_SERVICE_URL=http://user-service:8086`, `BOT_ENGINE_URL=http://bot-engine:8087`,
     `ORDER_MANAGEMENT_SERVICE_URL=http://order-management-service:8082`). Liquibase disabled
     in the gateway app, but a `db-migrator-gateway` image exists → migration hook still applies.
   - Kafka-only (no DB/Redis/migration): `kraken-ingest`, `yahoo-ingest`. Both need
     `DATA_SERVICE_URL`.
2. **UI (mfe chart):** `environments/tradebot-test/tradebot-ui/` (or similar). nginx image
   already proxies `/api`, `/auth`, `/stream` to `http://gateway:8080` — resolves to the
   `gateway` Service in the same namespace. UI gets the single public **ingress** (Traefik).
   Confirm the UI registry base (separate GitLab project).
3. **CI bump wiring** in the API + UI repos: last CI step edits this repo — `image.tag` on
   every build; `migration.tag` ONLY in `database/<svc>/**` pipelines. Needs a GITOPS token.
4. **Rewrite `infrastructure/README.md`** if it carries skeleton content (not yet reviewed).

## Placeholders to resolve before a real deploy (all marked in files)

- **Registry host** for `$CI_REGISTRY_IMAGE` — currently `registry.margusm.dev/margusmuru/tradebot-2`
  (guess). Confirm actual GitLab registry host/port.
- **External DB host** — `postgres.db.internal` placeholder in `data-service` externalName.
- **OTLP endpoint** — `otel-collector.observability.example` placeholder.
- **Image tags** — `REPLACE_ME` (CI will bump).

## Prerequisites (out-of-band, not managed by this repo)

- Strimzi Cluster Operator installed once.
- Vault paths seeded: `secret/tradebot-test/{<svc>,redis,kafka/<user>}`.
- `argocd-cm` `kustomize.buildOptions: "--enable-helm --load-restrictor LoadRestrictionsNone"`.
- ESO + `vault-kv` ClusterSecretStore, kube-prometheus-stack, Traefik, Longhorn — from the
  cluster build.
