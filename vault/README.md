# Vault setup for tradebot-test

Vault config is not GitOps (ArgoCD applies Kubernetes manifests, not Vault config), so
these are **manual, one-time** steps run with the **Vault root token**. They pair with
the GitOps ESO objects in `base/tradebot-test/eso/` (the `tradebot-eso` ServiceAccount +
the `tradebot-vault` ClusterSecretStore).

## Prerequisite: the universal Vault↔ESO foundation (once per cluster)

Not tradebot-specific — done once for the whole cluster (see the Obsidian note
"Kubernetes - Rancher 12 ESO + Vault"). For reference:

```bash
vault secrets enable -path=secret kv-v2
vault auth enable kubernetes
vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc
kubectl create clusterrolebinding vault-tokenreview \
  --clusterrole=system:auth-delegator --serviceaccount=vault:vault
```

## tradebot-test: scoped policy + role

Run inside the Vault pod, logged in as root:

```bash
kubectl -n vault exec -it vault-0 -- sh
vault login <root-token>
```

**1. Policy** (mirrors `tradebot-test-eso.hcl` in this dir — read-only on
`secret/tradebot-test/*`):

```bash
vault policy write tradebot-test-eso - <<'EOF'
path "secret/data/tradebot-test/*"     { capabilities = ["read"] }
path "secret/metadata/tradebot-test/*" { capabilities = ["read", "list"] }
EOF
```

**2. Role** — binds the `tradebot-eso` SA (in `tradebot-test-base`, created by
`base/tradebot-test/eso/`) to that policy. The `bound_*` values MUST match the SA and the
`serviceAccountRef` in `clustersecretstore.yaml` exactly, or login is rejected:

```bash
vault write auth/kubernetes/role/tradebot-test-eso \
  bound_service_account_names=tradebot-eso \
  bound_service_account_namespaces=tradebot-test-base \
  token_policies=tradebot-test-eso \
  token_ttl=1h \
  audience=vault
```

`audience=vault` matches the token ESO presents (the store sets `auth.kubernetes.audiences: [vault]`, which is also ESO's default). Required from Vault 1.21+; harmless on 1.20.x and clears the "role does not have an audience" warning.

Verify: `vault read auth/kubernetes/role/tradebot-test-eso` → `token_policies [tradebot-test-eso]`, `audience vault`.

## Seed the secrets

ESO only copies what already exists in Vault. Write real values (replace every
`CHANGE_ME`; use strong, distinct passwords). Paths/keys must match the `ExternalSecret`
`remoteRef`s in the chart values and the base components.

```bash
# Shared Redis password (base/tradebot-test/redis + every service's DATA_..._REDIS_PASSWORD)
vault kv put secret/tradebot-test/redis password='CHANGE_ME'

# Kafka SCRAM password per user (base/tradebot-test/kafka KafkaUsers + each service's KAFKA_PASSWORD)
vault kv put secret/tradebot-test/kafka/data-service    password='CHANGE_ME'
vault kv put secret/tradebot-test/kafka/gateway-service password='CHANGE_ME'
vault kv put secret/tradebot-test/kafka/kraken-ingest   password='CHANGE_ME'
vault kv put secret/tradebot-test/kafka/yahoo-ingest    password='CHANGE_ME'
vault kv put secret/tradebot-test/kafka/oms-service     password='CHANGE_ME'
vault kv put secret/tradebot-test/kafka/bot-engine      password='CHANGE_ME'
vault kv put secret/tradebot-test/kafka/user-service    password='CHANGE_ME'

# data-service DB creds: app-user password + migrator (postgres superuser) creds.
# db-migrator-username is 'postgres' to match the CI migrate job (LIQUIBASE_DB_USERNAME=postgres).
vault kv put secret/tradebot-test/data-service \
  db-password='CHANGE_ME' \
  db-migrator-username='postgres' \
  db-migrator-password='CHANGE_ME'

# gateway: same DB creds shape PLUS a JWT signing secret (jwt-secret -> JWT_SECRET).
# Gateway DB is a separate instance (cloudy-vm:5534), schema `tradebot`.
vault kv put secret/tradebot-test/gateway \
  db-password='CHANGE_ME' \
  db-migrator-username='postgres' \
  db-migrator-password='CHANGE_ME' \
  jwt-secret='CHANGE_ME'
```

(As more backends are onboarded, add `secret/tradebot-test/<service>` with `db-password`
+ `db-migrator-username`/`db-migrator-password` the same way. Some services also need an
extra key: **gateway** needs `jwt-secret` (mapped to `JWT_SECRET`). Add per-service extras
to that service's `secret/tradebot-test/<service>` path when you wire its `values.yaml`.)

```bash
# Private image-registry pull credential. Both projects live in the GitLab group
# `devprojects`, so use ONE group-scoped credential with `read_registry` - it pulls from
# every project in the group, covering the backend (devprojects/tradebot-2) AND the UI
# (devprojects/tradebot-2-ui). Two equivalent options (need Owner on the group):
#   - Group DEPLOY token  (Group -> Settings -> Repository -> Deploy tokens):
#       username = the deploy-token username (or gitlab+deploy-token-N), password = the token
#   - Group ACCESS token  (Group -> Settings -> Access tokens, role Reporter):
#       username = the token's NAME, password = the token value
# Both backend and UI charts point registry.vaultKey at this same path; ESO builds the
# dockerconfigjson (host registry.margusm.dev).
vault kv put secret/tradebot-test/registry \
  username='CHANGE_ME' \
  password='CHANGE_ME'
```

> **Not seeded here:** the ArgoCD repo credential lives at a **different** Vault path
> (`secret/argocd/tradebot-2-gitops`) behind a separate store/policy (`argocd-vault` /
> `argocd-eso`), because it bootstraps ArgoCD itself. See `infrastructure/README.md`.

## Verify end to end

```bash
kubectl get clustersecretstore tradebot-vault              # STATUS=Valid  (Invalid => role/SA/name mismatch)
# base components (tradebot-test-base): redis-auth + kafka-user-passwords
kubectl -n tradebot-test-base get externalsecret,secret    # SecretSynced=True
# app services (tradebot-test-app), once un-excluded: per-service secrets + dockerconfigjson
kubectl -n tradebot-test-app  get externalsecret           # data-service-{secrets,migration-secrets,registry,registry-presync} SecretSynced=True
```

`Valid` means ESO authenticated to Vault as `tradebot-eso` via the `tradebot-test-eso`
role. Once the Secrets sync, the Kafka `KafkaUser`s get their passwords, Redis can start
with its `--requirepass`, and each app service gets its DB/Redis/Kafka creds, migrator
credential, and image-pull secret. A `SecretSyncedError` on an ExternalSecret almost always
means a missing Vault key/property — cross-check against the seed commands above.
