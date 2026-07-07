# base/tradebot-test

Shared platform components for the `tradebot-test` environment. The `base-appset`
discovers `base/<env>/<component>/` directories and applies each as raw manifests /
kustomize (no Helm), deploying them into namespace `<env>-base` (here `tradebot-test-base`).

## Present components

- `kafka/` — in-cluster Kafka via the **Strimzi operator** (KRaft, no ZooKeeper). A
  single `Kafka` + `KafkaNodePool` with one internal SASL listener on `:9092` using
  **SCRAM-SHA-512**, plus one `KafkaUser` per service. Services reach the broker at
  `tradebot-kafka-bootstrap.tradebot-test-base:9092`.
  - **Requires the Strimzi Cluster Operator + CRDs** installed on the cluster once,
    out-of-band (like ESO/Longhorn — not managed by this repo). Align the Kafka
    `version`/`metadataVersion` in `kafka/kafka.yaml` with the installed operator.
  - No authorization/ACLs are enabled — any authenticated user may produce/consume and
    create topics, matching the current setup. **Topics are created by the apps
    themselves** (`KafkaAdmin`/`NewTopic` beans), so no `KafkaTopic` CRs are declared.
  - Each `KafkaUser`'s SCRAM password is taken from Vault (`secret/tradebot-test/kafka/<user>`)
    via the `kafka-user-passwords` `ExternalSecret`, so **Vault is the source of truth**;
    apps read the same value in their own namespace as `KAFKA_PASSWORD`.

- `redis/` — one shared Redis (`redis:7-alpine` StatefulSet + Service, Longhorn PVC).
  Services reach it at `redis.tradebot-test-base:6379`. The password comes from Vault
  (`secret/tradebot-test/redis`) via the `redis-auth` `ExternalSecret`; the same value
  is projected into each app's namespace as its Redis password.

## Already provided by the cluster build

These exist from the cluster setup and are **not** managed by this repo — do not add
them under `base/`:

- **ESO + Vault** with a `ClusterSecretStore` named `vault-kv` (Vault KV v2, mount
  `secret`). `ExternalSecret`s just reference it. Seed paths with
  `vault kv put secret/<path> key=value`.
- **kube-prometheus-stack** in `monitoring` (Prometheus Operator + Grafana). Enable a
  service's `serviceMonitor` (with label `release: monitoring`) to be scraped.
- **Traefik** as the default IngressClass; **ArgoCD** in `argocd`; **Longhorn** default
  StorageClass.

## Adding a component

Drop a directory `base/<env>/<component>/` with raw manifests or a `kustomization.yaml`;
the base ApplicationSet turns it into an Application in `<env>-base`.

Note the split of responsibility: platform **operators** (ESO, the Strimzi operator, the
Prometheus Operator, Longhorn) are installed out-of-band as part of the cluster build;
this repo only manages the **instances** (the `Kafka`/`KafkaUser` CRs, the Redis
StatefulSet, `ExternalSecret`s referencing the existing `vault-kv` store, `ServiceMonitor`s).
Do not re-declare an operator the build already owns.
