# tradebot-2-gitops

GitOps repository for **tradebot-2** — a Spring Boot microservice platform (8 backend
services + an Angular UI) deployed to a self-managed Kubernetes cluster via ArgoCD.

Delivery mechanics: an ArgoCD **ApplicationSet + Git directory generator** creates one
Application per service directory, with environment-partitioned paths and a
**Kustomize+Helm hybrid** render. Helm charts live **in this repo** (`charts/`), not in
an OCI registry — each service directory is a Kustomize directory (`kustomization.yaml`
+ `values.yaml`) that pulls an in-repo chart via Kustomize's `helmCharts` field.

> Status: **base platform live.** The pipeline, shared charts, and the in-cluster platform —
> Kafka (Strimzi), Redis, and the ESO/Vault secret store — are deployed and green on the
> cluster. The application layer is next: `data-service` is scaffolded but held out
> (`exclude: true` in the workload appset) until its image tag + external DB host are real;
> the other backends and the UI aren't added yet. See `CLAUDE.md` for current state, the
> fan-out plan, and the deployment lessons learned.

## Design decisions

- **In-repo charts, no OCI.** No registry, no pull auth. Charts render straight from the
  working tree; each service reaches the shared `charts/` via `helmGlobals.chartHome`.
- **Kustomize+Helm hybrid.** Each service's `kustomization.yaml` pulls a chart via
  `helmCharts` + `chartHome`. Requires `kustomize.buildOptions:
  "--enable-helm --load-restrictor LoadRestrictionsNone"` in `argocd-cm` (see
  Prerequisites) — acceptable because we manage this ArgoCD ourselves.
- **One environment now, multi-env-ready.** Paths are environment-partitioned
  (`environments/tradebot-test/`); a second environment is a new directory, not a
  refactor. Namespace per environment: each env deploys into `<env>-app`.
- **Secrets via ESO + Vault.** Every service's DB / Redis / Kafka credentials are
  projected from Vault by the External Secrets Operator. Vault is the single source of
  truth. (The chart also carries a `spring-config` mode, unused here.)
- **External database.** No in-cluster database; apps connect out to a separate machine
  (Postgres / TimescaleDB), reached via a stable in-cluster `ExternalName`.
- **In-cluster Kafka + Redis.** Kafka runs via the Strimzi operator (1.1.0; KRaft,
  SCRAM-SHA-512, CRDs at `kafka.strimzi.io/v1`, Kafka 4.2.0); a single shared Redis runs as
  a StatefulSet. Both live under `base/tradebot-test/`.
- **DB migrations as a PreSync hook.** Liquibase runs as an ArgoCD PreSync-hook Job
  (rendered by `common-service`) before each service's Deployment rolls.

## Layout

```text
.
├── argocd/
│   ├── bootstrap.yaml              # apply once by hand -> syncs argocd/appsets/
│   └── appsets/
│       ├── workload-appset.yaml    # discovers environments/*/*  -> one App per service
│       └── base-appset.yaml        # discovers base/*/*          -> platform components
├── charts/                         # in-repo Helm charts (no OCI)
│   ├── common-service/             # reusable backend chart (Deployment, Service, Ingress,
│   │                               #   HPA, ESO, external-DB wiring, PreSync migration Job)
│   └── mfe/                        # reusable static-MFE chart (nginx) for the Angular UI
├── base/
│   └── tradebot-test/              # platform instances (operators are build-provided)
│       ├── eso/                    # tradebot-vault ClusterSecretStore + SA (ESO -> Vault)
│       ├── kafka/                  # Strimzi Kafka (KRaft) + KafkaUsers
│       ├── otel-collector/         # OTel Collector -> external Grafana stack (Tempo/Prom/Loki)
│       └── redis/                  # shared Redis StatefulSet
├── environments/
│   └── tradebot-test/              # the single environment today
│       ├── common-values.yaml      # env-wide Helm defaults, merged under each service
│       ├── data-service/           # reference backend (live: DB + Redis + Kafka + migration + OTLP)
│       └── gateway/                # API gateway (R2DBC, downstream calls; held out until images built)
├── vault/                          # Vault policy + setup commands (manual, root token; not ArgoCD)
└── infrastructure/                 # out-of-band bootstrap: ArgoCD git credential (not read by ArgoCD)
```

## How it works

1. `argocd/bootstrap.yaml` is applied once. It creates a single ArgoCD Application that
   syncs `argocd/appsets/`.
2. `workload-appset.yaml` uses a Git **directory** generator over `environments/*/*`. For
   each service directory it creates an Application named `<env>-<service>` (e.g.
   `tradebot-test-data-service`), deployed into namespace `<env>-app` (`tradebot-test-app`).
3. `base-appset.yaml` does the same over `base/*/*`, deploying platform components into
   `<env>-base` (`tradebot-test-base`).
4. Each Application's source is its directory. ArgoCD runs `kustomize build --enable-helm`,
   which pulls the in-repo chart and renders it with the directory's `values.yaml`.

## Prerequisites

- An ArgoCD with the ApplicationSet controller enabled and **read access to this private
  repo** — a `repository` credential (GitLab project deploy token, `read_repository` scope),
  applied out-of-band before bootstrap; see `infrastructure/README.md`. Adjust
  `namespace: argocd` in the three `argocd/` files if ArgoCD lives elsewhere.
- **`argocd-cm` must enable the Kustomize+Helm hybrid** (one-time):

  ```bash
  kubectl -n argocd patch cm argocd-cm --type merge \
    -p '{"data":{"kustomize.buildOptions":"--enable-helm --load-restrictor LoadRestrictionsNone"}}'
  kubectl -n argocd rollout restart deploy argocd-repo-server
  ```

- **External Secrets Operator + Vault**, wired once (KV v2 at `secret`, Kubernetes auth, the
  `vault-tokenreview` ClusterRoleBinding). tradebot then uses its own **scoped** store
  `tradebot-vault` (`base/tradebot-test/eso/`), which needs a Vault policy + role and the
  seeded secret paths — see `vault/README.md` and Secrets below.
- **The Strimzi Cluster Operator 1.x** (provides the `kafka.strimzi.io/v1` CRDs). Not part of
  the base cluster build — install it once (homelab `906-strimzi-kafka-operator.yml`). The
  Kafka `version` in `base/tradebot-test/kafka/` must be one the installed operator supports
  (1.1.0 → Kafka 4.1.x/4.2.0). See `base/tradebot-test/README.md`.
- **An external Postgres/TimescaleDB** reachable from the cluster, and (for the OTLP path)
  an external OTLP endpoint (OTel Collector / Grafana Alloy).
- Observability is otherwise satisfied by the cluster build: an in-cluster
  kube-prometheus-stack is present (so `serviceMonitor` works with a `release: monitoring`
  label).

## Bootstrapping

**Out-of-band first** (once, not GitOps — these can't be repo-managed because they gate
ArgoCD's access to the repo and to secrets):

0. Wire the ArgoCD git credential (`infrastructure/README.md`) and the tradebot Vault
   policy/role + seeded secrets (`vault/README.md`); ensure the Strimzi operator and the
   `argocd-cm` buildOptions are in place (see Prerequisites).

Then:

1. Confirm `repoURL` in the three files under `argocd/` matches this repo.
2. Push to `main`.
3. Apply the root Application once:

   ```bash
   kubectl apply -f argocd/bootstrap.yaml
   ```

ArgoCD then discovers and syncs everything under `environments/` and `base/`.

## Quickstart

The base platform (ESO/Vault, Kafka, Redis, OTel Collector) and the reference backend
`data-service` are live. Each service is its own ArgoCD Application (from the workload
ApplicationSet), so services go green independently.

```bash
argocd app list                                    # base-tradebot-test-* + tradebot-test-data-service
kubectl -n tradebot-test-app get pods              # data-service Running
kubectl -n tradebot-test-app port-forward svc/data-service 8081:8081
curl localhost:8081/data-service/actuator/health   # {"status":"UP"}
```

## Adding a service

Create a directory `environments/<env>/<service>/` with a `kustomization.yaml` (selects
the chart) and a `values.yaml` (the Helm values). `data-service` is the reference:

```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
helmGlobals:
  chartHome: ../../../charts
helmCharts:
  - name: common-service          # or "mfe" for the Angular UI
    releaseName: <service>        # becomes the resource names
    valuesFile: values.yaml
```

Backend `values.yaml` highlights (see `environments/tradebot-test/data-service/values.yaml`
for the full worked example and `charts/common-service/values.yaml` for all knobs):

```yaml
image:
  repository: <registry>/<service>
  tag: <commit-sha>
env:
  SPRING_PROFILES_ACTIVE: k8s             # self-contained k8s profile: see "Spring profiles" below
  KAFKA_BOOTSTRAP_SERVER_URL: tradebot-kafka-bootstrap.tradebot-test-base:9092
  KAFKA_USERNAME: <kafka-user>
secrets:
  mode: eso                               # DB/Redis/Kafka passwords from Vault
externalDb:
  enabled: true
  stableDns: { enabled: true, serviceName: <service>-db, externalName: <db-host> }
  env: { DB_..._URL: jdbc:postgresql://<service>-db:5432/tradebot }
migration:                                # DB-backed services only
  enabled: true
  repository: <registry>/db-migrator-<service>
  tag: <db-changelog-sha>
```

The ApplicationSet picks up the new directory on the next refresh.

## Spring profiles (the `k8s` profile)

Services run with `SPRING_PROFILES_ACTIVE=k8s` — a **single, self-contained** profile
(activating two profiles at once was confusing). The always-on base `application.*` supplies
env-agnostic defaults; the `k8s` profile overrides every environment-specific value (hosts,
credentials, OTLP endpoints, Kafka auth), exactly as `prod` does. It is in fact a **copy of
the `prod` profile** with one change: Kafka SASL mechanism → `SCRAM-SHA-512` (protocol stays
`SASL_PLAINTEXT`), because the in-cluster Strimzi operator's native `KafkaUser` auth is SCRAM,
not the `PLAIN` used elsewhere. The existing `prod` profile is left **unchanged** (still used
by the docker-compose deployment). The `k8s` files live in the API repo
(`application-k8s.{properties,yml}` per service); Kafka username/password come from the
`KAFKA_USERNAME` env and the Vault-projected `KAFKA_PASSWORD`. Note: `k8s` now duplicates
`prod`, so a future `prod` env-wiring change must be mirrored into `k8s`.

## Health probes

`common-service` defaults liveness/readiness to Spring Boot Actuator's health-group
endpoints. **Mind the context path**: a service with `server.servlet.context-path`
serves Actuator under it, so override the probe path accordingly — e.g. `data-service`
uses `/data-service/actuator/health/liveness`. Non-Actuator apps (like the `mfe` chart)
probe `/`.

## Secrets (ESO + Vault)

`secrets.mode: eso` makes `common-service` render an `ExternalSecret` (with
`secretStoreRef.name: tradebot-vault`) that projects a Secret named `<service>-secrets` from
Vault; the container consumes it via `envFrom`. List the keys under `secrets.eso.data`. The
`tradebot-vault` store (`base/tradebot-test/eso/`) is read-scoped to `secret/tradebot-test/*`.
Vault path convention:

- `secret/tradebot-test/<service>` — the service's DB credentials (and, for DB-backed
  services, the `db-migrator` superuser credential used by the migration Job).
- `secret/tradebot-test/redis` — the shared Redis password.
- `secret/tradebot-test/kafka/<user>` — each service's Kafka SCRAM password.

## External database

No in-cluster database. Under `externalDb`, `stableDns.enabled: true` renders an
`ExternalName` Service so apps target a stable in-cluster name (`<service>-db`) instead of
the raw DB host — change the host in one place. Credentials come through the ESO block.

## Messaging (Kafka) and cache (Redis)

Both run in-cluster under `base/tradebot-test/` (namespace `tradebot-test-base`):

- **Kafka** via Strimzi (KRaft, SCRAM-SHA-512). Broker at
  `tradebot-kafka-bootstrap.tradebot-test-base:9092`; one `KafkaUser` per service, passwords
  sourced from Vault. Topics are created by the apps themselves (no `KafkaTopic` CRs).
- **Redis** as a shared StatefulSet at `redis.tradebot-test-base:6379`, password from Vault.

See `base/tradebot-test/README.md` for details and the Strimzi prerequisite.

## Database migrations

DB-backed services set `migration.enabled: true`. `common-service` then renders an ArgoCD
**PreSync hook**: an `ExternalSecret` (wave −2) projecting the migrator credential, and a
`Job` (wave −1) running the `db-migrator-<service>` image (`liquibase update`) before the
Deployment rolls. The migrator carries its **own pinned tag** (`migration.tag`), separate
from the app image, because CI builds it only on DB-changelog changes; Liquibase `update`
is idempotent, so re-running it on app-only syncs is a no-op. Migrations run as the DB
superuser (`postgres`), a more privileged credential than the app's runtime user.

## Observability

- **OTLP push (default).** Services push traces/metrics/logs to an external Grafana stack
  via Micrometer's `MANAGEMENT_OTLP_*` properties, set through `env:` in each service's
  values (point them at an external OTel Collector / Grafana Alloy).
- **ServiceMonitor scrape (opt-in, default off).** Set `serviceMonitor.enabled: true`
  (with label `release: monitoring`) to have the in-cluster kube-prometheus-stack scrape
  `/actuator/prometheus`.

## CI image bumps

ArgoCD watches **this** repo, not the service repos or the registry. A service's running
version is the `image.tag` in its `values.yaml` here. Deploying a new build is a two-repo
dance: the service repo's CI builds and pushes an image, then edits this repo's tag,
commits, and pushes to `main`; ArgoCD re-renders and rolls the Deployment.

Two tags per DB-backed service, bumped on different triggers (mirroring the service repo's
CI):

```bash
# every build of the service (app image, commit SHA):
yq -i '.image.tag = "<sha>"' environments/tradebot-test/<service>/values.yaml
# only when database/<service>/** changed (migrator image):
yq -i '.migration.tag = "<sha>"' environments/tradebot-test/<service>/values.yaml
```

## Validate locally

Render a full service directory the way ArgoCD does (Kustomize + Helm):

```bash
kubectl kustomize --enable-helm --load-restrictor LoadRestrictionsNone \
  environments/tradebot-test/data-service
```

Note: Kustomize's helm integration expects a **helm 3** CLI; a helm 4 binary fails with
`unknown shorthand flag: 'c'` — point it at helm 3 with `--helm-command /path/to/helm3`.
The ArgoCD repo-server bundles a compatible helm, so this only affects local validation.

## Caveats

- **In-repo chart blast radius.** Editing `charts/common-service` re-renders every service
  using it on the next sync — review the ArgoCD diff before merging chart changes.
- **Placeholders.** Replace the external DB host and image tags before real use (marked in
  `data-service/values.yaml`). Registry host (`registry.margusm.dev/devprojects/...`) and the
  OTLP endpoint (in-cluster `otel-collector.tradebot-test-base`) are now resolved.
- **Sync ≠ Health in ArgoCD.** A failed apply surfaces as `OutOfSync` + a `SyncError`, and
  CRs without a health check report `Healthy` by default — so an app can look green while a
  resource silently failed to apply. Judge by Sync status + the last sync result, not the
  health dot.
- **Don't rename/replace the sole KRaft controller on a live cluster.** Renaming the Kafka
  cluster or its NodePool triggers a node replacement; on a single-node KRaft cluster that
  breaks the controller quorum (recovery = wipe + rebuild). Leave Strimzi names alone
  post-deploy, or run 3 controllers for HA.
