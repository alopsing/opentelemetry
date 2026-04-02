# OpenTelemetry End-to-End POC

A complete OpenTelemetry observability POC running on a local Kubernetes cluster (Kind) with all three signals — **traces**, **metrics**, and **logs** — flowing through the OTel Collector into Jaeger, Prometheus, and Loki, all visualized in Grafana.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Kind Cluster                         │
│                                                             │
│  ┌─────────────┐    ┌──────────────┐    ┌────────────────┐ │
│  │ api-gateway │───▶│ order-service│───▶│inventory-service│ │
│  │  :3000      │    │  :3001       │    │   :3002        │ │
│  └──────┬──────┘    └──────┬───────┘    └───────┬────────┘ │
│         │                  │                    │           │
│         └──────────────────┴────────────────────┘           │
│                            │ OTLP gRPC (:4317)              │
│                     ┌──────▼──────┐                         │
│                     │OTel Collector│                        │
│                     └──┬───┬───┬──┘                         │
│                        │   │   │                            │
│              ┌─────────┘   │   └──────────┐                 │
│              ▼             ▼              ▼                  │
│          ┌───────┐  ┌──────────┐  ┌─────────┐              │
│          │Jaeger │  │Prometheus│  │  Loki   │              │
│          │(traces)│ │(metrics) │  │ (logs)  │              │
│          └───┬───┘  └────┬─────┘  └────┬────┘              │
│              └───────────┴─────────────┘                    │
│                          │                                   │
│                    ┌─────▼──────┐                           │
│                    │  Grafana   │                           │
│                    └────────────┘                           │
└─────────────────────────────────────────────────────────────┘
```

### Services

| Service | Port | Responsibility |
|---|---|---|
| `api-gateway` | 3000 | Entry point — receives HTTP requests, calls order-service |
| `order-service` | 3001 | Validates orders, calls inventory-service |
| `inventory-service` | 3002 | Checks stock availability |

### Observability Stack

| Component | Image | Role |
|---|---|---|
| OTel Collector | `otel/opentelemetry-collector-contrib:0.100.0` | Receives OTLP, routes to backends |
| Jaeger | `jaegertracing/all-in-one:1.57` | Distributed trace storage and UI |
| Prometheus | `prom/prometheus:v2.51.0` | Metrics scraping and storage |
| Loki | `grafana/loki:2.9.0` | Log aggregation |
| Grafana | `grafana/grafana:10.4.0` | Unified observability UI |

---

## Prerequisites

| Tool | Purpose | Install |
|---|---|---|
| `docker` | Build images, run Kind nodes | [docs.docker.com](https://docs.docker.com/get-docker/) |
| `kind` | Local Kubernetes cluster | [kind.sigs.k8s.io](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) |
| `kubectl` | Interact with the cluster | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |

---

## Quick Start

```bash
./bootstrap.sh
```

The script runs 7 steps:
1. Checks prerequisites (`docker`, `kind`, `kubectl`)
2. Creates a Kind cluster named `otel-poc` (idempotent — skips if exists)
3. Builds Docker images for all 3 services
4. Loads images into Kind (no registry needed)
5. Applies all Kubernetes manifests via `kubectl apply -k k8s/overlays/local/`
6. Waits for all deployments to be ready (5 min timeout each)
7. Prints access URLs

---

## Access URLs

| UI | URL | Credentials |
|---|---|---|
| API Gateway | http://localhost:8080 | — |
| Grafana | http://localhost:3000 | Anonymous admin (no login) |
| Jaeger UI | http://localhost:16686 | — |
| Prometheus | http://localhost:9090 | — |

---

## Generating Telemetry

Send a test order to trigger a full 3-service trace:

```bash
curl -s -X POST http://localhost:8080/order \
  -H "Content-Type: application/json" \
  -d '{"userId":"user-123","itemId":"item-001"}' | jq .
```

Expected response:
```json
{
  "orderId": "order-1234567890",
  "status": "created",
  "orderDetails": {
    "orderId": "order-1234567890",
    "status": "confirmed",
    "itemId": "item-001",
    "quantity": 42,
    "timestamp": "..."
  }
}
```

Generate a burst of requests:
```bash
for i in {1..10}; do
  curl -s -X POST http://localhost:8080/order \
    -H "Content-Type: application/json" \
    -d "{\"userId\":\"user-$i\",\"itemId\":\"item-00$((i % 3 + 1))\"}"; echo
done
```

Health checks:
```bash
curl http://localhost:8080/health
curl http://localhost:8081/health   # order-service (if port-forwarded)
curl http://localhost:8082/health   # inventory-service (if port-forwarded)
```

---

## How Instrumentation Works

### 1. SDK Initialization (`tracing.js`)

Each service loads `tracing.js` as the **very first** require — before Express, axios, or any other module. This is critical because auto-instrumentation works by monkey-patching modules at load time.

```js
// index.js — must be first
require('./tracing');
```

`tracing.js` initializes:
- `OTLPTraceExporter` → sends spans to `OTEL_EXPORTER_OTLP_ENDPOINT` (default: `http://otel-collector:4317`)
- `OTLPMetricExporter` → sends metrics every 10 seconds
- `Resource` attributes: `service.name`, `service.version`, `deployment.environment`
- `getNodeAutoInstrumentations()` → auto-instruments HTTP, Express, and axios

### 2. Auto-Instrumentation (zero code changes)

| Library | What it creates |
|---|---|
| `http`/`https` | Server span for every inbound request |
| `express` | Router span per route handler |
| `axios` | Client span per outbound call + injects `traceparent` header |

### 3. Context Propagation

When `api-gateway` calls `order-service` via axios, the auto-instrumentation automatically injects the W3C `traceparent` header. `order-service` extracts it and creates child spans under the same `traceId`. This links all spans across all 3 services into a single trace tree in Jaeger.

```
api-gateway: POST /order                        [traceId: abc123]
  └─ api-gateway: process-order                 [manual span]
       └─ order-service: POST /order            [same traceId: abc123]
            └─ order-service: validate-order    [manual span]
                 └─ inventory-service: GET /inventory/check
                      └─ inventory-service: check-stock
```

### 4. Manual Spans

Each service adds custom spans for business logic:

```js
const tracer = trace.getTracer('api-gateway', '1.0.0');
const span = tracer.startSpan('process-order');
span.setAttributes({ 'order.id': orderId, 'user.id': userId });
// ... business logic ...
span.end();
```

### 5. Custom Metrics

| Service | Metric | Type |
|---|---|---|
| api-gateway | `api_gateway_requests_total` | Counter |
| api-gateway | `api_gateway_request_duration_ms` | Histogram |
| order-service | `order_service_orders_total` | Counter |
| inventory-service | `inventory_service_checks_total` | Counter |
| inventory-service | `inventory_service_stock_level` | Gauge |

In Prometheus, metrics are prefixed with `otel_` by the collector (e.g. `otel_api_gateway_requests_total`).

### 6. Structured Logs with Trace Correlation

Winston is configured to extract `traceId` and `spanId` from the active OTel span context on every log line:

```json
{
  "timestamp": "2026-04-02T03:28:00.486Z",
  "level": "info",
  "message": "Order processed successfully",
  "traceId": "6fd1c78f62e9dd5a5e9ea0a7a7bf3537",
  "spanId": "08ccfd1b715605b7",
  "orderId": "order-1234567890"
}
```

The Loki datasource in Grafana has a derived field on `traceId` — clicking it jumps directly to the trace in Jaeger.

---

## Grafana Dashboards

The **OpenTelemetry POC** dashboard (auto-provisioned, no manual setup) is under **Dashboards → OpenTelemetry POC folder**.

| Row | Panels |
|---|---|
| Overview | Total requests (stat), Error rate % (stat), p95 latency (stat) |
| Metrics | Request rate per service (time series), Request duration p95 (time series) |
| Logs | Live log stream from api-gateway with traceId links |
| Traces | Instructions for Jaeger Explore |

### Useful Prometheus Queries

```promql
# Request rate per service
rate(otel_api_gateway_requests_total[1m])
rate(otel_order_service_orders_total[1m])
rate(otel_inventory_service_checks_total[1m])

# p95 latency
histogram_quantile(0.95, sum(rate(otel_api_gateway_request_duration_ms_bucket[5m])) by (le))

# Error rate
sum(rate(otel_api_gateway_requests_total{status=~"5.."}[5m]))
  / sum(rate(otel_api_gateway_requests_total[5m])) * 100
```

### Useful Loki Queries

```logql
# All api-gateway logs
{job="api-gateway"} | json

# Only errors
{job="api-gateway"} | json | level="error"

# Filter by traceId
{job="api-gateway"} | json | traceId="<your-trace-id>"

# Order processing logs across all services
{job=~"api-gateway|order-service|inventory-service"} | json | message=~"order"
```

---

## Project Structure

```
opentelemetry/
├── bootstrap.sh                  # One-command setup script
├── kind-config.yaml              # Kind cluster with host port mappings
├── services/
│   ├── api-gateway/
│   │   ├── src/
│   │   │   ├── tracing.js        # OTel SDK init (loaded first)
│   │   │   └── index.js          # Express app
│   │   ├── package.json
│   │   └── Dockerfile
│   ├── order-service/            # same structure
│   └── inventory-service/        # same structure
└── k8s/
    ├── base/                     # Kustomize base — source of truth
    │   ├── kustomization.yaml
    │   ├── namespace.yaml
    │   ├── collector/            # OTel Collector deployment + config
    │   ├── grafana/              # Grafana + datasources + dashboards
    │   ├── jaeger/
    │   ├── loki/
    │   ├── prometheus/
    │   └── services/             # app Deployments and Services
    └── overlays/
        └── local/                # Kind-specific overlay (environment: local label)
            └── kustomization.yaml
```

---

## Kubernetes Commands

```bash
# Check all pods
kubectl get pods -n otel-poc

# Stream logs from a service
kubectl logs -n otel-poc deployment/api-gateway -f
kubectl logs -n otel-poc deployment/otel-collector -f

# Describe a pod (for events/errors)
kubectl describe pod -n otel-poc -l app=api-gateway

# Port-forward a service manually
kubectl port-forward -n otel-poc svc/order-service 3001:3001

# Re-apply manifests (after config changes)
kubectl apply -k k8s/overlays/local/

# Restart a deployment (e.g. after a config change)
kubectl rollout restart deployment/otel-collector -n otel-poc
kubectl rollout status deployment/otel-collector -n otel-poc

# Rebuild and reload a service image
docker build -t api-gateway:latest ./services/api-gateway
kind load docker-image api-gateway:latest --name otel-poc
kubectl rollout restart deployment/api-gateway -n otel-poc
```

---

## OTel Collector Signal Flow

```
Receivers          Processors              Exporters
─────────    ──────────────────────    ─────────────────
otlp gRPC ──▶ memory_limiter ──▶ batch ──▶ otlp/jaeger  (traces → :4317)
otlp HTTP                            ──▶ prometheus    (metrics → :8889)
                                     ──▶ loki          (logs → /loki/api/v1/push)
                                     ──▶ logging       (debug stdout)
```

The collector also exposes:
- `:13133` — health check endpoint (used by Kubernetes liveness/readiness probes)
- `:8888` — collector's own internal metrics

---

## Teardown

```bash
# Delete the Kind cluster (removes everything)
kind delete cluster --name otel-poc

# Or just delete the namespace (keeps the cluster)
kubectl delete namespace otel-poc
```

---

## Extending This POC

### Add a new overlay (e.g. staging)

```bash
mkdir -p k8s/overlays/staging
```

```yaml
# k8s/overlays/staging/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
commonLabels:
  environment: staging
patches:
  - patch: |-
      - op: replace
        path: /spec/replicas
        value: 2
    target:
      kind: Deployment
      name: api-gateway
```

### Add a new service

1. Create `services/my-service/` with `src/tracing.js`, `src/index.js`, `package.json`, `Dockerfile`
2. Add `k8s/base/services/my-service.yaml` (Deployment + Service)
3. Add `my-service.yaml` to `k8s/base/services/kustomization.yaml`
4. Build and load: `docker build -t my-service:latest ./services/my-service && kind load docker-image my-service:latest --name otel-poc`
5. Apply: `kubectl apply -k k8s/overlays/local/`
