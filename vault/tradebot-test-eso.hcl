# Scoped, read-only Vault policy for tradebot-test's ESO identity.
# Attached to the Kubernetes-auth role `tradebot-test-eso` (see README.md), which binds
# the tradebot-eso ServiceAccount. This is what isolates tradebot: its ESO can read ONLY
# paths under secret/tradebot-test/, nothing else in the shared `secret/` KV engine.
#
# KV v2 quirk: reads/writes at logical path secret/tradebot-test/... go through the
# underlying API path secret/data/tradebot-test/..., so the policy targets `data/`.

path "secret/data/tradebot-test/*" {
  capabilities = ["read"]
}

# Only needed if ESO ever lists/finds secrets (getAllSecrets); harmless to keep.
path "secret/metadata/tradebot-test/*" {
  capabilities = ["read", "list"]
}
