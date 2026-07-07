# base/tradebot-test/kafka

In-cluster **Kafka** via the Strimzi operator (KRaft, no ZooKeeper), dedicated to
tradebot. The base ApplicationSet turns this directory into the ArgoCD Application
`base-tradebot-test-kafka`, deployed into namespace `tradebot-test-base`. Services reach
the broker at `tradebot-kafka-bootstrap.tradebot-test-base:9092`.

## What ArgoCD applies

`kustomization.yaml` lists three resources:

- **`externalsecret.yaml`** — `ExternalSecret` `kafka-user-passwords`. Projects each Kafka
  user's SCRAM password from Vault (`secret/tradebot-test/kafka/<user>`, key `password`)
  into one K8s Secret via the `tradebot-vault` store.
- **`kafka.yaml`** — the `KafkaNodePool` (`kafka`, 1 replica, controller+broker, 5Gi
  Longhorn PVC) and the `Kafka` CR (`tradebot`). One internal listener on `:9092`,
  `tls: false`, `scram-sha-512` auth; replication factors set to 1 (single broker). The
  `entityOperator` runs the topic + user operators (the latter reconciles the KafkaUsers).
- **`kafkausers.yaml`** — seven `KafkaUser`s (one per service:
  `data-service`, `gateway-service`, `kraken-ingest`, `yahoo-ingest`, `oms-service`,
  `bot-engine`, `user-service`). Each takes its desired SCRAM password from a key in the
  `kafka-user-passwords` Secret, so **Vault is the source of truth**. Apps read the same
  value in their own namespace as `KAFKA_PASSWORD`.

## Auth & topics

- **SCRAM-SHA-512, no ACLs** — any authenticated user may produce/consume/create topics,
  matching the pre-existing SASL-without-ACLs setup.
- **Topics are created by the apps** (`KafkaAdmin`/`NewTopic` beans in data-service,
  kraken-ingest, yahoo-ingest), so no `KafkaTopic` CRs are declared here.

## Version coupling (important)

`spec.kafka.version` MUST be one the installed Strimzi operator supports. Strimzi
**1.1.0** supports Kafka 4.2.0 / 4.2.1 / 4.3.0 — we pin **4.2.0**. `metadataVersion` is
omitted so Strimzi defaults it to the version's metadata version. Bump both together when
upgrading the operator.

## Depends on

- The **Strimzi operator + CRDs** installed once, out-of-band (homelab
  `playbooks/906-strimzi-kafka-operator.yml`) — without it, `kind: Kafka` won't apply.
- The `tradebot-vault` ClusterSecretStore being `Valid` (see `base/tradebot-test/eso/`) —
  until then `kafka-user-passwords` won't sync and the KafkaUsers have no passwords.

> This `_readme.md` is not in `kustomization.yaml`'s `resources:`, so kustomize/ArgoCD
> ignore it — reference only.
