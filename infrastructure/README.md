# infrastructure

**Manual, out-of-band bootstrap** — applied by hand, **not** reconciled by ArgoCD. The
GitOps loop only reads `argocd/`, `charts/`, `environments/`, and `base/`; nothing here.

## ArgoCD → GitLab repo credential (`argocd-repo-credential.yaml`)

The one credential that can't be GitOps-managed: it's what lets ArgoCD *read this private
repo in the first place* (chicken-and-egg — ArgoCD can't apply a manifest from a repo it
can't yet clone). So it's seeded once, by hand, **before** `argocd/bootstrap.yaml`.

The value lives in Vault; ESO projects it into the `argocd` namespace as an ArgoCD
`repository` Secret (so rotation is a single Vault write). Scoped to this repo only.

Prerequisite (once per cluster, already done): the universal ESO↔Vault foundation — KV v2
at `secret`, Kubernetes auth, and the `vault-tokenreview` ClusterRoleBinding
(see `vault/README.md`).

### 1. Create a GitLab deploy token

On the **`tradebot-2-gitops` project** → Settings → Repository → Deploy tokens: scope
`read_repository`. Note the generated username + token.

### 2. Vault (root token, once)

```bash
kubectl -n vault exec -it vault-0 -- sh
vault login <root-token>
```
```bash
# Seed the deploy-token creds
vault kv put secret/argocd/tradebot-2-gitops \
  username='<deploy-token-username>' \
  password='<deploy-token>'

# Read-only policy for argocd paths (tradebot-vault is scoped to secret/tradebot-test/* and can't read these)
vault policy write argocd-eso - <<'EOF'
path "secret/data/argocd/*" { capabilities = ["read"] }
EOF

# K8s-auth role bound to the argocd-eso SA in the argocd namespace
vault write auth/kubernetes/role/argocd-eso \
  bound_service_account_names=argocd-eso \
  bound_service_account_namespaces=argocd \
  token_policies=argocd-eso \
  token_ttl=1h \
  audience=vault
```

### 3. Apply the K8s objects (SA + SecretStore + ExternalSecret)

```bash
kubectl apply -f infrastructure/argocd-repo-credential.yaml
```

### 4. Verify

```bash
kubectl -n argocd get secretstore argocd-vault                       # want: STATUS=Valid
kubectl -n argocd get externalsecret tradebot-2-gitops-repo          # SecretSynced=True
kubectl -n argocd get secret tradebot-2-gitops-repo                  # the repository Secret ESO created
```

Once the Secret exists, ArgoCD can clone the repo — proceed with `argocd/bootstrap.yaml`.

> Note: the resulting `repository` Secret is a normal K8s Secret in etcd (ESO writes it) —
> Vault is the source of truth for *rotation*, not extra encryption at rest.
