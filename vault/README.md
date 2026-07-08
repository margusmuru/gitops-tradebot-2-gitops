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
```

(As more backends are onboarded, add `secret/tradebot-test/<service>` with `db-password`
+ `db-migrator-username`/`db-migrator-password` the same way.)

```bash
# Private image-registry pull credential. Both projects live in the GitLab group
# `devprojects`, so use a GROUP deploy token (Group -> Settings -> Repository -> Deploy
# tokens) with scope read_registry - it pulls from every project in the group, covering
# both the backend (devprojects/tradebot-2) and the UI (devprojects/tradebot-2-ui).
# username = deploy-token username, password = the token. Both backend and UI charts point
# registry.vaultKey at this same path. ESO builds the dockerconfigjson (host registry.margusm.dev).
vault kv put secret/tradebot-test/registry \
  username='CHANGE_ME' \
  password='CHANGE_ME'
```

## Verify end to end

```bash
kubectl get clustersecretstore tradebot-vault              # STATUS=Valid  (Invalid => role/SA/name mismatch)
kubectl -n tradebot-test-base get externalsecret,secret    # SecretSynced=True; redis-auth + kafka-user-passwords Secrets exist
```

`Valid` means ESO authenticated to Vault as `tradebot-eso` via the `tradebot-test-eso`
role. Once the Secrets sync, the Kafka `KafkaUser`s get their passwords and Redis can
start with its `--requirepass`.
