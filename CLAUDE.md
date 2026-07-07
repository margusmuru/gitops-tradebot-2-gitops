# tradebot-2-gitops — Working Context

GitOps repo that deploys **tradebot-2** (8 Spring Boot backends + Angular UI) to a
self-managed RKE2 cluster (`kube-11`, prod inventory) via ArgoCD. Built by putting tradebot
onto the `skeleton-01` GitOps baseline as a practice run for the real Nortal setup. Read
`README.md` for user-facing docs; this file is the internal state + plan.

## Related repos / paths

- **This repo:** `/Users/margusmuru/Developer/gitlab/gitops/tradebot-2-gitops`
  (remote `https://gitlab.margusm.dev/gitops/tradebot-2-gitops.git`)
- **API (backends):** `/Users/margusmuru/Developer/gitlab/tradebot-2-worktrees/tradebot-2`
  (remote `.../margusmuru/tradebot-2.git`) — Gradle multi-module, Jib images, Liquibase
- **UI (Angular):** `/Users/margusmuru/Developer/gitlab/tradebot-2-ui-worktrees/tradebot-2-ui`
  — nginx-served static build; image `frontend`
- **Cluster (ansible):** `/Users/margusmuru/Developer/gitlab/homelab/kube-cluster/kubernetes-RKE2`
  (prod inventory = `kube-11` @ 192.168.40.141; verify via `ansible rke2_server -i inventories/prod/hosts.ini`)
- **Skeleton baseline:** `/Users/margusmuru/Developer/gitlab/gitops/skeleton-01`
- **Design docs (Obsidian):** "DevOps - Nortal GitOps redesign" + "Kubernetes - Rancher 12 ESO + Vault"

## Locked architecture decisions

- **Env name:** `tradebot-test` → app ns `tradebot-test-app`, base ns `tradebot-test-base`.
- **Render:** Kustomize+Helm hybrid, in-repo charts (`common-service`, `mfe`), no OCI.
  Needs `argocd-cm` `kustomize.buildOptions: --enable-helm --load-restrictor LoadRestrictionsNone` (set).
- **Secrets:** ESO + Vault, **per-project scoped**. Store = **`tradebot-vault`** ClusterSecretStore
  (in `base/tradebot-test/eso/`), authenticating as SA `tradebot-eso` via Vault role
  `tradebot-test-eso` (scoped policy: read `secret/data/tradebot-test/*` only). Vault paths:
  `secret/tradebot-test/<svc>` (DB creds + migrator cred), `secret/tradebot-test/redis` (shared),
  `secret/tradebot-test/kafka/<user>` (per Kafka user). `audiences: [vault]` goes under
  `auth.kubernetes.serviceAccountRef` (ESO 2.6.0 schema), matched by the Vault role `audience=vault`.
- **DB:** external Postgres/TimescaleDB, reached via `externalDb.stableDns` ExternalName.
- **Kafka + Redis:** in-cluster under `base/tradebot-test/`. Kafka = **Strimzi 1.1.0** operator
  (KRaft, SCRAM-SHA-512, no ACLs), CRDs at **`kafka.strimzi.io/v1`** (NOT v1beta2), **Kafka 4.2.0**.
  Cluster `tradebot`, single NodePool `kafka` (controller+broker) → pod `tradebot-kafka-0`, bootstrap
  `tradebot-kafka-bootstrap.tradebot-test-base:9092`. Topics app-managed (NewTopic beans) — no KafkaTopic CRs.
  Redis = one shared StatefulSet `redis.tradebot-test-base:6379`.
- **Migrations:** Liquibase as an ArgoCD **PreSync hook**, templated in `common-service`
  (`migration.enabled`). Separate **pinned** `migration.tag` (never `latest`) — CI builds the
  migrator only on `database/<svc>/**` changes. Runs as DB superuser `postgres` (own ESO cred).
- **Observability:** OTLP push via Micrometer `MANAGEMENT_OTLP_*` props (via `env:`, NOT the chart's
  `observability.enabled`/agent `OTEL_*`). Optional `serviceMonitor` for in-cluster Prometheus.

## Kafka auth: the `k8s` Spring profile (API repo change)

App hardcodes Kafka `SASL_PLAINTEXT` + `mechanism=PLAIN` in prod; Strimzi's native KafkaUser auth
is SCRAM-SHA-512. Solution: a `k8s` Spring profile, `SPRING_PROFILES_ACTIVE=prod,k8s`. `-prod`
untouched + reused; `-k8s` overrides ONLY the SASL mechanism → SCRAM-SHA-512 (protocol stays
SASL_PLAINTEXT). Per service: `.properties` (data-service, kraken-ingest, yahoo-ingest,
order-management-service), `.yml` (gateway, bot-engine, user-service). Each uses
`username="${KAFKA_USERNAME:<user>}" password="${KAFKA_PASSWORD}"`. `kraken-exec` not touched.

## Service inventory

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

Probe path = `<context-path>/actuator/health/{liveness,readiness}` (or `/actuator/...` if no
context-path). Images `$CI_REGISTRY_IMAGE/<service>:<sha>`, migrators `db-migrator-<service>:<sha>`,
UI `frontend:<sha>` (UI is a separate GitLab project → different registry base).

## Deployment status (2026-07-07)

**Repo pushed + `bootstrap.yaml` applied. Base platform is LIVE and fully green** on `kube-11`:
- `base-tradebot-test-eso` — `tradebot-vault` ClusterSecretStore `Valid`, SA `tradebot-eso`.
- `base-tradebot-test-redis` — `redis-0` Running (password from Vault via `redis-auth`).
- `base-tradebot-test-kafka` — Kafka `tradebot` `Ready` (v4.2.0, node `tradebot-kafka-0`), 7 KafkaUsers `Ready`.
- `tradebot-test-whoami` — Synced/Healthy (pipeline smoke test).
- All Synced + Healthy on both axes.

**GitLab auth for ArgoCD (bootstrap credential, applied manually):** `infrastructure/argocd-repo-credential.yaml`
(SA `argocd-eso` + namespaced `SecretStore argocd-vault` + ExternalSecret → the `repository`-labeled
Secret). Vault side: `secret/argocd/tradebot-2-gitops` (project deploy token, read_repository) +
`argocd-eso` policy/role. See `infrastructure/README.md`. Not GitOps (chicken-and-egg).

**Universal Vault↔ESO foundation (manual, once):** KV v2 at `secret`, Kubernetes auth,
`vault-tokenreview` ClusterRoleBinding. Strimzi operator installed via homelab
`playbooks/906-strimzi-kafka-operator.yml` (chart 1.1.0, `watchAnyNamespace`).

**`data-service` is present but `exclude: true`** in the workload appset — kept out until its
image tag + external DB host are real.

## Deployment gotchas / lessons (all resolved)

- **ArgoCD Sync ≠ Health.** A failed apply shows as OutOfSync + SyncError (and "Missing" health),
  and CRs without a health check default to "Healthy" — so an app can look green while sync failed.
  Watch **Sync status + last sync result**, not just the health dot.
- **Version-pinned CRD schemas:** ESO 2.6.0 wants `audiences` under `serviceAccountRef` (not
  `auth.kubernetes`); Strimzi 1.x serves `kafka.strimzi.io/v1` (not `v1beta2`). One invalid resource
  fails the whole app sync (applies nothing). Always check the *installed* operator's schema.
- **Cosmetic OutOfSync, two flavors:** ESO defaults `.spec.data[].remoteRef.{conversionStrategy,
  decodingStrategy,metadataPolicy,nullBytePolicy}` → handled by `ignoreDifferences` in BOTH appset
  templates. StatefulSet `volumeClaimTemplates` gets `apiVersion: v1`/`kind: PersistentVolumeClaim`
  from the API server → declared explicitly in `redis/statefulset.yaml` (stable values).
- **NEVER rename/replace the sole controller on live single-node KRaft.** Renaming the nodepool
  (dual-role→kafka) replaced node 0→1; the quorum broke (dead node still a voter → no majority →
  NotReady, SCRAM timeouts). Fixed by a clean rebuild (delete Kafka CR + nodepool + PVCs → ArgoCD
  recreated fresh as node 0). For rename-safety/HA use 3 controllers. Don't do cosmetic renames post-deploy.
- **Fixes never reach ArgoCD until committed AND pushed** — local edits don't count; ArgoCD syncs `main`.
- **Bootstrap secret exception:** the ArgoCD repo credential can't be GitOps-managed (needed to read
  the repo). Applied by hand (Vault-backed via ESO in `infrastructure/`).

## TODO / next (application layer)

1. **Bring in `data-service`** — remove `exclude: true` in `argocd/appsets/workload-appset.yaml`
   once it has a real image tag (not `REPLACE_ME`) and the real external DB host (not
   `postgres.db.internal`). Vault path `secret/tradebot-test/data-service` already seeded; pattern proven.
2. **Fan out the other 6 backends** following `data-service/values.yaml`:
   - DB-backed (migration + Redis + ESO): `user-service`, `gateway`, `order-management-service`, `bot-engine`.
   - **gateway:** reactive (R2DBC), needs `JWT_SECRET` (ESO) + downstream URLs
     (`DATA_SERVICE_URL=http://data-service:8081`, `USER_SERVICE_URL=http://user-service:8086`,
     `BOT_ENGINE_URL=http://bot-engine:8087`, `ORDER_MANAGEMENT_SERVICE_URL=http://order-management-service:8082`).
     App liquibase disabled but `db-migrator-gateway` exists → migration hook still applies.
   - Kafka-only (no DB/Redis/migration): `kraken-ingest`, `yahoo-ingest` (both need `DATA_SERVICE_URL`).
   Each needs a KafkaUser password seeded in Vault + `application-k8s.*` already in the API repo.
3. **UI (mfe chart):** `environments/tradebot-test/tradebot-ui/`. nginx already proxies `/api`,
   `/auth`, `/stream` to `http://gateway:8080` (same-ns Service). UI gets the single public **ingress**
   (Traefik). Confirm the UI registry base (separate GitLab project).
4. **CI bump wiring** (API + UI repos): last CI step edits this repo — `image.tag` on every build;
   `migration.tag` ONLY on `database/<svc>/**`. Needs a **write** GitLab token (separate from ArgoCD's read).

## Placeholders to resolve per service (marked in files)

- **Registry host** for `$CI_REGISTRY_IMAGE` — using `registry.margusm.dev/margusmuru/tradebot-2`
  (Jib: `${CI_REGISTRY}/${CI_PROJECT_PATH}/<svc>`). Confirm actual registry host.
- **External DB host** — `postgres.db.internal` placeholder.
- **OTLP endpoint** — `otel-collector.observability.example` placeholder.
- **Image tags** — `REPLACE_ME` (CI will bump).

## Cluster prerequisites (out-of-band, done)

- Strimzi operator (homelab playbook 906, chart 1.1.0). ESO + Vault (playbooks 904/905).
- Vault↔ESO wiring + tradebot policy/role + seeded secrets (manual, root token — see `vault/README.md`).
- ArgoCD repo credential (manual — see `infrastructure/README.md`).
- `argocd-cm` buildOptions set. kube-prometheus-stack, Traefik, Longhorn from the cluster build.
