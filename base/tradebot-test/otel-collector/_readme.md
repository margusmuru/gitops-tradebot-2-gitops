# base/tradebot-test/otel-collector

In-cluster **OpenTelemetry Collector** (contrib distro) for the tradebot-test env. The base
ApplicationSet turns this directory into the ArgoCD Application `base-tradebot-test-otel-collector`,
deployed into namespace `tradebot-test-base`. Apps push telemetry to it; it forwards to the
external **Grafana stack on `dev-2-vm-1` (192.168.40.112)**.

## Flow

```
app pods (tradebot-test-app)
  --OTLP--> otel-collector.tradebot-test-base:4317 (gRPC, traces+logs)
            otel-collector.tradebot-test-base:4318 (HTTP, metrics /v1/metrics)
                 |
   Collector pipelines (memory_limiter -> resource -> batch)
                 |
   traces  -> Tempo        192.168.40.112:4327   (otlp gRPC, tls insecure)
   metrics -> Prometheus   192.168.40.112:9090   (remote-write)
   logs    -> Loki         192.168.40.112:3100   (otlp HTTP)
```

The `resource` processor stamps `deployment.environment=k8s-test` on everything (upsert).
Change that value per environment.

## What the apps set

Backend `values.yaml` point Micrometer's OTLP at the Service:

```
MANAGEMENT_OTLP_METRICS_EXPORT_URL: http://otel-collector.tradebot-test-base:4318/v1/metrics
MANAGEMENT_OTLP_TRACING_ENDPOINT:   http://otel-collector.tradebot-test-base:4317
MANAGEMENT_OTLP_LOGGING_ENDPOINT:   http://otel-collector.tradebot-test-base:4317
```

Tracing + logging use gRPC (4317); metrics use HTTP (4318) — matching the always-on base
`application.*` (`management.otlp.*.transport=grpc`, metrics export url on `/v1/metrics`).

## Config changes need a restart

`configmap.yaml` has a **stable name** (not a hashed generator) because base sync runs with
`prune: false` — a hashed ConfigMap would leave orphans that never get pruned. So editing the
config does NOT roll the pod automatically. After changing `configmap.yaml`, either bump the
`config-revision` annotation in `deployment.yaml` or run:

```
kubectl -n tradebot-test-base rollout restart deploy/otel-collector
```

## Depends on / prerequisites

- **Network**: cluster pods (via node egress) must reach `192.168.40.112` on `4327`, `9090`,
  `3100`. Check any firewall on dev-2-vm-1 allows the cluster subnet.
- **Prometheus** must run with `--web.enable-remote-write-receiver` (remote-write endpoint).
- Pinned image `otel/opentelemetry-collector-contrib:0.146.1` (matches the working
  docker-compose setup; never `latest`).

> `_readme.md` is not in `kustomization.yaml`'s `resources:`, so kustomize/ArgoCD ignore it.
