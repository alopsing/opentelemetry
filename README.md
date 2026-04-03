# OpenTelemetry End-to-End POC

A complete OpenTelemetry observability POC running on a local Kubernetes cluster (Kind) with all three signals — **traces**, **metrics**, and **logs** — flowing through the OTel Collector into Jaeger, Prometheus, and Loki, all visualized in Grafana.

---

## Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│                          Kind Cluster (2 nodes)                   │
│                                                                   │
│  ┌─────────────┐    ┌──────────────┐    ┌────────────────┐       │
│  │ api-gateway │───▶│ order-service│───▶│inventory-service│       │
│  │  :3000 ×2   │    │  :3001 ×2   │    │   :3002 ×2     │       │
│  └──────┬──────┘    └──────┬───────┘    └───────┬────────┘       │
│         │                  │                    │                  │
│         └──────────────────┴────────────────────┘                 │
│                            │ OTLP gRPC (:4317)                    │
│                     ┌──────▼──────┐                               │
│                     │OTel Collector│ (:8888 self-metrics)         │
│                     └──┬───┬───┬──┘                               │
│                        │   │   │                                  │
│              ┌─────────┘   │   └──────────┐                       │
│              ▼             ▼              ▼                        │
│          ┌───────┐  ┌──────────┐  ┌─────────┐                    │
│          │Jaeger │  │Prometheus│  │  Loki   │                    │
│          │badger │  │+ Alerts  │  │  PVC    │                    │
│          │  PVC  │  └────┬─────┘  └────┬────┘                    │
│          └───┬───┘       │  ┌──────────┘                         │
│              │            ▼  ▼                                    │
│              │     ┌─────────────┐   ┌──────────────┐            │
│              │     │ Alertmanager│   │   Grafana    │            │
│              │     └─────────────┘   │(2 dashboards)│            │
│              └─────────────────────▶ └──────────────┘            │
└───────────────────────────────────────────────────────────────────┘
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
| Jaeger | `jaegertracing/all-in-one:1.57` | Distributed trace storage (badger, PVC) |
| Prometheus | `prom/prometheus:v2.51.0` | Metrics scraping, alerting rules, PVC |
| Alertmanager | `prom/alertmanager:v0.27.0` | Routes Prometheus alerts |
| Loki | `grafana/loki:2.9.0` | Log aggregation (PVC) |
| Grafana | `grafana/grafana:10.4.0` | Unified observability UI (2 dashboards) |

---

## Prerequisites

| Tool | Purpose | Install |
|---|---|---|
| `docker` | Build images, run Kind nodes | [docs.docker.com](https://docs.docker.com/get-docker/) |
| `kind` | Local Kubernetes cluster | [kind.sigs.k8s.io](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) |
| `kubectl` | Interact with the cluster | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |

---

## Quick Start

> **If you have a previous cluster:** the Kind config now includes a worker node. Recreate first:
> ```bash
> kind delete cluster --name otel-poc
> ```

```bash
./bootstrap.sh
```

The script runs 8 steps:
1. Checks prerequisites (`docker`, `kind`, `kubectl`)
2. Creates a Kind cluster named `otel-poc` with 1 control-plane + 1 worker node (idempotent — skips if exists)
3. Builds Docker images for all 3 services
4. Loads images into Kind (no registry needed)
5. Applies all Kubernetes manifests via `kubectl apply -k k8s/overlays/local/`
6. Installs `metrics-server` (required for HPA / `kubectl top`)
7. Waits for all deployments to be ready (5 min timeout each)
8. Prints access URLs

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

Two dashboards are auto-provisioned under **Dashboards → OpenTelemetry POC folder** (no manual setup).

### Dashboard 1: OpenTelemetry POC (Business)

| Row | Panels | Notes |
|---|---|---|
| Overview | Business requests (stat), Error rate % (stat), p95 latency (stat) | `/health` probe traffic excluded |
| Metrics | Request rate by route + status (time series), p95 + p50 latency by route (time series) | Broken down by route and outcome |
| Metrics | Inventory stock levels (bar gauge), Order outcomes (donut) | Business-level panels |
| Logs | All services live logs (filtered), Errors only | Click `traceid` → jumps to Jaeger trace |
| Traces | Correlation guide + useful Loki queries | Instructions for logs↔traces workflow |

### Dashboard 2: OTel Collector Operations

| Panel | Metric | Purpose |
|---|---|---|
| Spans Received/Exported | `otelcol_receiver_accepted_spans` | Ingest rate |
| Export Failures | `otelcol_exporter_send_failed_spans` | Exporter errors |
| Queue Size | `otelcol_exporter_queue_size` | Backpressure |
| Collector Memory | `otelcol_process_memory_rss` | Resource usage |
| Log Records Sent | `otelcol_exporter_sent_log_records` | Log pipeline health |

### Logs → Traces Correlation

The logs panels show `traceid` as a clickable derived field. Clicking it opens the exact trace in Jaeger showing the full 3-service call tree for that request.

To find all logs for a single request across all 3 services:
```logql
{job=~"api-gateway|order-service|inventory-service"} |= "<paste-traceid>"
```

### Useful Prometheus Queries

```promql
# Business request rate (excludes /health probes)
sum(rate(otel_api_gateway_requests_total{route!="/health"}[1m])) by (route)

# p95 latency by route (Prometheus appends _milliseconds to metrics with unit "ms")
histogram_quantile(0.95, sum(rate(otel_api_gateway_request_duration_ms_milliseconds_bucket{route!="/health"}[5m])) by (le, route))

# Error rate (5xx only, business traffic)
100 * sum(rate(otel_api_gateway_requests_total{status=~"5..", route!="/health"}[5m]))
  / sum(rate(otel_api_gateway_requests_total{route!="/health"}[5m]))

# Order outcomes breakdown
sum(increase(otel_order_service_orders_total[1h])) by (status)

# Inventory stock levels
otel_inventory_service_stock_level
```

### Useful Loki Queries

```logql
# Business logs only (filter out noisy /health probe logs)
{job=~"api-gateway|order-service|inventory-service"} | json body | body != "Request processed"

# Errors and warnings across all services
{job=~"api-gateway|order-service|inventory-service", level=~"ERROR|WARN"}

# All logs for a specific request (paste any traceid)
{job=~"api-gateway|order-service|inventory-service"} |= "<your-trace-id>"

# Rejected orders (out-of-stock)
{job="order-service"} |= "rejected"
```

> **Note:** Logs are shipped via OTLP and stored in Loki with `job` and `level` as stream labels. The log body is a JSON string — use `|=` for fast substring search or `| json body` to parse for structured filtering.

---

## Load Testing & Scenario Simulation

### Production simulator (`scripts/simulate.sh`)

The main simulation tool. Runs named scenarios that model real production traffic patterns — each controls request mix, concurrency, rate, and duration.

```bash
./scripts/simulate.sh <scenario> [--url URL] [--rate N] [--dur S] [--conc N]
```

| Scenario | What it does | Default rate | Default duration |
|---|---|---|---|
| `normal` | Steady baseline: ~85% 2xx, ~10% 409 (out-of-stock), ~5% 4xx | 10 req/s | 120s |
| `degraded` | Elevated errors: ~40% 2xx, ~30% 409, ~30% 4xx/misc — triggers `HighErrorRate` alert | 15 req/s | 180s |
| `spike` | Quiet → ramp up → peak → ramp down → quiet — shows HPA and latency spike in Grafana | 40 req/s peak | ~165s |
| `soak` | Long-running low-rate — surfaces memory leaks, connection exhaustion, metric drift | 3 req/s | 30 min |
| `recovery` | 90s of bad traffic then 90s of good — watch alerts fire then auto-resolve | 10 req/s | 180s |
| `chaos` | All failure modes simultaneously: 4xx, 5xx, malformed JSON, thundering herd bursts | 20 req/s | 120s |

**Request types in the mix:**

| Type | Expected code | What it exercises |
|---|---|---|
| Happy path (in-stock item) | 200 | Full 3-service trace, metrics increment |
| Out-of-stock (`item-002`) | 409 | Business rejection path, warn log, span attribute |
| Unknown item (`item-999`) | 404 | inventory-service not-found path |
| Missing field | 400 | order-service field validation |
| Malformed JSON | 400 | Express JSON parser rejection |
| Wrong HTTP method | 404 | Gateway routing |
| Large payload | 200/400 | Request body handling |
| Thundering herd burst | mixed | 10 parallel requests in one shot |

**Examples:**

```bash
# Populate all 3 signal types with realistic traffic
./scripts/simulate.sh normal

# Trigger the HighErrorRate Prometheus alert
./scripts/simulate.sh degraded

# Watch HPA scale up in real time (open another terminal: kubectl get hpa -n otel-poc -w)
./scripts/simulate.sh spike

# Watch alerts fire then resolve — good for testing Alertmanager routing
./scripts/simulate.sh recovery

# Chaos — everything at once
./scripts/simulate.sh chaos

# Custom rate and duration
./scripts/simulate.sh normal --rate 20 --dur 300

# Soak test overnight
./scripts/simulate.sh soak --dur 28800
```

Override the gateway URL:
```bash
GATEWAY_URL=http://localhost:8080 ./scripts/simulate.sh normal
```

### Basic scripts (in `scripts/`)

Simpler scripts for quick tests:

| Script | Purpose |
|---|---|
| `load-test-basic.sh [rps] [duration]` | Steady valid orders |
| `load-test-spike.sh [cycles]` | Quiet/burst cycles |
| `load-test-errors.sh [duration]` | Fixed error mix |
| `load-test-continuous.sh [workers] [rps/worker]` | Background workers, runs until Ctrl+C |

### Inventory items reference

| Item | Stock | Behaviour |
|---|---|---|
| `item-001` | 42 | Always succeeds |
| `item-002` | 0 | Always returns 409 out-of-stock |
| `item-003` | 15 | Always succeeds |
| `item-004` | 7 | Always succeeds |
| `item-999` | — | Returns 404 (not in inventory map) |

---

## Project Structure

```
opentelemetry/
├── bootstrap.sh                  # One-command setup script
├── kind-config.yaml              # Kind cluster: 1 control-plane + 1 worker + host ports
├── scripts/
│   ├── simulate.sh               # Production scenario simulator (main)
│   ├── load-test-basic.sh        # Steady load
│   ├── load-test-spike.sh        # Quiet/burst cycles
│   ├── load-test-errors.sh       # Error scenario mix
│   └── load-test-continuous.sh   # Parallel workers, runs until Ctrl+C
├── services/
│   ├── api-gateway/
│   │   ├── src/
│   │   │   ├── tracing.js        # OTel SDK init (loaded first)
│   │   │   └── index.js          # Express app
│   │   ├── package.json
│   │   └── Dockerfile            # Non-root user (appuser:appgroup)
│   ├── order-service/            # same structure
│   └── inventory-service/        # same structure
└── k8s/
    ├── base/                     # Kustomize base — source of truth
    │   ├── kustomization.yaml
    │   ├── namespace.yaml
    │   ├── rbac/                 # ServiceAccounts + Prometheus ClusterRole/ClusterRoleBinding
    │   ├── network-policies/     # 9 NetworkPolicy objects (deny-all + explicit allows)
    │   ├── collector/            # OTel Collector: configmap + deployment (securityContext)
    │   ├── grafana/              # Grafana + datasources + 2 dashboards
    │   ├── jaeger/               # Jaeger all-in-one + badger PVC
    │   ├── loki/                 # Loki + PVC
    │   ├── prometheus/           # Prometheus + PVC + alerts + recording rules
    │   ├── alertmanager/         # Alertmanager deployment + config
    │   └── services/             # app Deployments, Services, HPA, PDB
    └── overlays/
        └── local/                # Kind-specific overlay (environment: local label)
            └── kustomization.yaml
```

---

## Production-Grade Features

This POC includes the following hardening applied for local Kind development. The same patterns translate directly to EKS via a new Kustomize overlay.

### Security

| Feature | What's configured |
|---|---|
| Non-root containers | All services run as UID 1001; collector as UID 65534 (nobody); Jaeger as UID 1000; Grafana as UID 472 |
| Read-only filesystem | `readOnlyRootFilesystem: true` on all containers; `/tmp` emptyDir where Node.js needs to write |
| Dropped capabilities | `capabilities: drop: [ALL]` on all containers |
| No privilege escalation | `allowPrivilegeEscalation: false` on all containers |
| Seccomp | `seccompProfile: RuntimeDefault` on all app pods |
| ServiceAccounts | Dedicated ServiceAccount per component (9 total) |
| RBAC | Prometheus ClusterRole scoped to GET/LIST/WATCH on pods, nodes, services, endpoints |
| NetworkPolicies | Deny-all default with explicit allow rules; each service can only reach its upstream dependency and the OTel Collector |

### Reliability

| Feature | What's configured |
|---|---|
| Replicas | All 3 app services run 2 replicas |
| PodDisruptionBudgets | `minAvailable: 1` for all 3 services |
| HorizontalPodAutoscaler | CPU 60% target, min 2 / max 5 replicas (requires metrics-server) |
| Pod anti-affinity | Preferred spread across nodes (soft rule, works on single-node too) |
| Persistent storage | Prometheus (2Gi PVC), Loki (2Gi PVC), Jaeger (2Gi PVC via badger) |
| Jaeger storage | badger (file-based, embedded in all-in-one) — survives pod restarts |
| Prometheus retention | 7-day time retention, 1800MB size limit — prevents disk exhaustion |
| Collector resilience | `sending_queue` + `retry_on_failure` on all exporters |

### Alerting

Prometheus alert rules (`k8s/base/prometheus/configmap.yaml`):

| Alert | Condition |
|---|---|
| `HighErrorRate` | >5% 5xx responses over 5 minutes |
| `HighLatencyP95` | p95 request duration >1000ms over 5 minutes |
| `CollectorExporterQueueNearFull` | Exporter queue >80% full |
| `CollectorDroppingData` | Collector is dropping spans/metrics/logs |

Alertmanager is deployed and wired to Prometheus. For local dev, alerts are null-routed (no external webhook). To route real alerts, edit `k8s/base/alertmanager/configmap.yaml` and add a `receiver` with your Slack/PagerDuty webhook.

Recording rules pre-compute SLO metrics (request rate, error rate, p95 latency) for fast dashboard queries.

### EKS Migration Path

The local overlay (`k8s/overlays/local/`) already patches `NODE_ENV=local` on all three app services, so `deployment.environment=local` flows through to Loki labels and trace resource attributes. The base sets `NODE_ENV=production` which the EKS overlay can leave as-is.

All environment differences are isolated in `k8s/overlays/`. To target EKS:

```bash
mkdir -p k8s/overlays/eks
```

```yaml
# k8s/overlays/eks/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
commonLabels:
  environment: production
patches:
  # Use EBS storage class instead of local-path
  - patch: |-
      - op: replace
        path: /spec/storageClassName
        value: gp3
    target:
      kind: PersistentVolumeClaim
  # Remove NodePort (use LoadBalancer or Ingress instead)
  - patch: |-
      - op: replace
        path: /spec/type
        value: ClusterIP
    target:
      kind: Service
      name: prometheus
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

# Resource usage (requires metrics-server)
kubectl top pods -n otel-poc
kubectl top nodes

# HPA status
kubectl get hpa -n otel-poc

# PDB status
kubectl get pdb -n otel-poc

# PVC status (check storage is bound)
kubectl get pvc -n otel-poc

# NetworkPolicy list
kubectl get networkpolicy -n otel-poc

# Check Prometheus alerts
kubectl port-forward -n otel-poc svc/prometheus 9090:9090
# then open http://localhost:9090/alerts
```

---

## OTel Collector Signal Flow

```
Receivers       Processors                          Exporters
─────────    ──────────────────────────────    ────────────────────────
otlp gRPC ──▶ memory_limiter                  ┌▶ otlp/jaeger  (traces → :4317)
otlp HTTP     ├─▶ tail_sampling ──▶ batch ────┘
              │   (100% errors, 10% rest)
              └─▶ transform/loki_labels        ┌▶ prometheus   (metrics → :8889)
                  (enrich log attrs)            │▶ loki         (logs → /loki/api/v1/push)
                  ──▶ batch ────────────────────┘▶ logging      (debug stdout)
```

**Tail sampling** policies (configured on the collector):
- `errors-policy`: 100% of traces containing an error span
- `latency-policy`: 100% of traces with p99 > 500ms
- `probabilistic-policy`: 10% of remaining successful traces

All exporters use `sending_queue` + `retry_on_failure` for resilience.

The collector exposes:
- `:13133` — health check (Kubernetes liveness/readiness probes)
- `:8888` — collector's own Prometheus metrics (scraped by Prometheus, visualized in the Collector Operations dashboard)

---

## Production Readiness

See [`PRODUCTION_READINESS.md`](./PRODUCTION_READINESS.md) for a full checklist of gaps between this local POC and a production deployment, grouped by priority (critical → operational → EKS-specific → scalability).

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
