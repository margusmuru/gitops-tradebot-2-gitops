# base/tradebot-test/eso

tradebot's **ESO↔Vault wiring** — the bridge that lets every tradebot `ExternalSecret`
pull its values from Vault. The base ApplicationSet turns this directory into the
ArgoCD Application `base-tradebot-test-eso`, deployed into namespace `tradebot-test-base`.

## What ArgoCD applies

`kustomization.yaml` lists exactly two resources:

### `serviceaccount.yaml` — ServiceAccount `tradebot-eso`
The identity ESO assumes when authenticating to Vault for tradebot. ESO mints a token
for this SA (via the Kubernetes TokenRequest API) and logs into Vault's Kubernetes auth
method as it. It carries no secrets itself — it's just a name that the Vault role binds.
It lands in `tradebot-test-base` (the base ApplicationSet's destination namespace), which
is why the Vault role's `bound_service_account_namespaces` is `tradebot-test-base`.

### `clustersecretstore.yaml` — ClusterSecretStore `tradebot-vault`
The store object that tells ESO **where Vault is** and **how to log in**. Every tradebot
`ExternalSecret` references it by name (`secretStoreRef.name: tradebot-vault`).

It's **cluster-scoped** (not namespaced) on purpose: tradebot's `ExternalSecret`s live in
more than one namespace — `tradebot-test-app` (the services) and `tradebot-test-base`
(redis-auth, kafka-user-passwords) — and one `ClusterSecretStore` serves them all. But it
authenticates as the `tradebot-eso` SA, whose Vault role grants read on **only**
`secret/tradebot-test/*` — so it's shared across tradebot's namespaces yet isolated from
other projects' secrets.

Field by field:
- `provider.vault.server` — the in-cluster Vault Service, `http://` (the standalone Vault
  chart's listener has no TLS).
- `path: secret` + `version: v2` — the KV v2 engine mounted at `secret` (v2 makes ESO use
  the `data/`-prefixed API; omit it and reads fail).
- `auth.kubernetes.mountPath: kubernetes` — where the Kubernetes auth method is mounted in
  Vault.
- `auth.kubernetes.role: tradebot-test-eso` — the scoped Vault role (grants the read-only
  `tradebot-test-eso` policy).
- `auth.kubernetes.serviceAccountRef` — the `tradebot-eso` SA (name + namespace) ESO
  presents. These three — the role's `bound_*`, this SA, and the SA above — must name the
  **same identity** or login is rejected.

## GitOps vs manual: the split

- **This directory (GitOps):** the SA + the store — plain Kubernetes manifests ArgoCD
  applies.
- **Vault config (manual, root token):** the KV engine, Kubernetes auth, the scoped
  policy, and the role can't be GitOps — ArgoCD applies Kubernetes objects, not Vault
  config. They're run once with the root token (commands below; canonical source is the
  repo-root `vault/` dir — `tradebot-test-eso.hcl` + `README.md`).

The store reports **`Invalid`** until the Vault-side policy + role exist and the SA is
created; it goes **`Valid`** once all three are present.

> This README is **not** in `kustomization.yaml`'s `resources:`, so kustomize/ArgoCD
> ignore it — reference only.

## Manual Vault steps this depends on (root token)

The store stays `Invalid` until the Vault side exists: the scoped policy
`tradebot-test-eso`, its Kubernetes-auth role (bound to the `tradebot-eso` SA), and the
seeded `secret/tradebot-test/*` values — plus the once-per-cluster foundation (KV v2,
Kubernetes auth, the `vault-tokenreview` ClusterRoleBinding).

Those commands aren't duplicated here — see the repo-root **`vault/README.md`** for the
full `vault policy write` / `vault write auth/...` / `vault kv put` block, and
`vault/tradebot-test-eso.hcl` for the policy source.

## Verify

```bash
kubectl get clustersecretstore tradebot-vault              # want: STATUS=Valid
kubectl -n tradebot-test-base get externalsecret,secret    # SecretSynced=True
```

`Invalid` is almost always a name mismatch (role / SA name / namespace / mountPath) or a
missing `version: v2` — check the ESO operator logs in `external-secrets`.
