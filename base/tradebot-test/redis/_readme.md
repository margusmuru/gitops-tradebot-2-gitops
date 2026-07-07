# base/tradebot-test/redis

One shared in-cluster **Redis** for the tradebot-test environment. The base
ApplicationSet turns this directory into the ArgoCD Application `base-tradebot-test-redis`,
deployed into namespace `tradebot-test-base`. Services reach it at
`redis.tradebot-test-base:6379`.

## What ArgoCD applies

`kustomization.yaml` lists three resources:

- **`externalsecret.yaml`** — `ExternalSecret` `redis-auth`. Projects the shared Redis
  password from Vault (`secret/tradebot-test/redis`, key `password`) into a K8s Secret via
  the `tradebot-vault` store. No plaintext lives in git.
- **`statefulset.yaml`** — a single-replica `redis:7-alpine` StatefulSet with a 2Gi
  Longhorn PVC (`appendonly yes`). The password is injected from the `redis-auth` Secret as
  the `REDIS_PASSWORD` env var, and `redis-server --requirepass $(REDIS_PASSWORD)` reads it
  via the `$(VAR)` form (which resolves against the container's `env`). Readiness runs
  `redis-cli -a "$REDIS_PASSWORD" ping`.
- **`service.yaml`** — a `ClusterIP` Service named `redis` exposing `6379`, giving the
  stable in-cluster name `redis.tradebot-test-base`.

## How the password flows

`secret/tradebot-test/redis` (Vault) → `redis-auth` Secret (ESO) → the StatefulSet's
`--requirepass`. Each app service reads the **same** Vault value in its own namespace
(as its `*_REDIS_PASSWORD`), so the one Redis password has a single source of truth.

## Depends on

The `tradebot-vault` ClusterSecretStore being `Valid` (see `base/tradebot-test/eso/`) —
until then `redis-auth` won't sync and the pod won't reach Ready (no password).

> This `_readme.md` is not in `kustomization.yaml`'s `resources:`, so kustomize/ArgoCD
> ignore it — reference only.
