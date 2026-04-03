# Production Readiness Checklist

Tracks the gaps between the current local Kind POC and a production deployment (EKS or equivalent).
Items are grouped by priority. The Kustomize overlay pattern is already in place — most of these are implemented in `k8s/overlays/eks/` without touching the base.

---

## Critical (must-have before any production traffic)

### TLS / Encryption in transit
- [ ] Enable TLS on OTel Collector OTLP receivers (gRPC + HTTP)
- [ ] Enable TLS on Loki, Prometheus, Jaeger endpoints
- [ ] Add an Ingress controller (nginx / AWS ALB) with TLS termination for Grafana and Jaeger UI
- [ ] Consider mTLS between services via a service mesh (Istio, Linkerd) or cert-manager + SPIFFE

### Secret management
- [ ] Move any credentials (Grafana admin password, Alertmanager webhook URLs) out of ConfigMaps into Kubernetes Secrets
- [ ] Integrate with an external secrets manager (AWS Secrets Manager, HashiCorp Vault) via External Secrets Operator
- [ ] Rotate secrets on a schedule; never commit secrets to git

### Ingress / Load balancing
- [ ] Replace NodePort Services with ClusterIP + Ingress resources
- [ ] Configure AWS ALB Ingress Controller (or nginx) in the EKS overlay
- [ ] Add rate limiting and authentication to public-facing endpoints (Grafana, Jaeger UI)

### High availability for stateful components
- [ ] **Prometheus**: deploy in HA pair (2 replicas scraping the same targets) or adopt Thanos/Cortex for long-term storage and deduplication
- [ ] **Loki**: switch from all-in-one to microservices mode backed by S3 (read path / write path / compactor separated)
- [ ] **Jaeger**: replace all-in-one + badger with separate Collector + Query + storage (Elasticsearch or OpenSearch)
- [ ] **Alertmanager**: run 2+ replicas in cluster mode (`--cluster.peer`) to avoid alert notification gaps during restarts
- [ ] **Grafana**: add a shared database backend (RDS PostgreSQL) so multiple replicas share state

### Backup and restore
- [ ] Enable EBS snapshot policy for all PVCs (Prometheus, Loki, Jaeger)
- [ ] Test restore procedure and document RTO/RPO targets
- [ ] For Loki on S3: enable S3 versioning and lifecycle policies

---

## Operational (must-have before sustained production use)

### CI/CD pipeline
- [ ] Build Docker images in CI (GitHub Actions / GitLab CI / Tekton)
- [ ] Push images to a container registry (ECR, GCR, GHCR) — remove `imagePullPolicy: Never`
- [ ] Pin image tags to immutable digests (`image: api-gateway@sha256:...`) not `:latest`
- [ ] Automate `kubectl apply -k k8s/overlays/eks/` in CD after image push and tests pass
- [ ] Add a rollback step triggered on failed rollout status

### Container image security
- [ ] Scan images for vulnerabilities in CI (Trivy, Grype, or Snyk)
- [ ] Fail the build on CRITICAL CVEs
- [ ] Use minimal base images (consider `node:20-alpine` → `gcr.io/distroless/nodejs20` for smaller attack surface)
- [ ] Sign images with cosign and verify signatures at deploy time

### Alerting destinations
- [ ] Configure a real Alertmanager receiver: Slack, PagerDuty, or OpsGenie
- [ ] Add `runbook_url` annotations to all alert rules pointing to remediation docs
- [ ] Add a deadman's switch alert (Prometheus must always fire one heartbeat alert — silence = problem)
- [ ] Test alert routing end-to-end (fire a synthetic alert, confirm notification received)

### Resource tuning
- [ ] Run load tests at expected production traffic levels
- [ ] Right-size CPU/memory requests and limits for all pods based on actual profiling
- [ ] Set JVM/Node.js heap limits aligned with container memory limits to prevent OOM kills
- [ ] Configure Prometheus `--storage.tsdb.retention.*` based on actual data growth rate

### Logging
- [ ] Add log sampling for high-volume INFO logs to reduce Loki ingest costs
- [ ] Set a Loki ingest rate limit per tenant to prevent runaway log bursts
- [ ] Define a log retention policy in Loki (currently unlimited)

---

## EKS-specific

### Storage
- [ ] Create an EKS overlay that patches all PVCs to use `storageClassName: gp3`
- [ ] Enable EBS CSI driver on the EKS cluster
- [ ] For Loki: replace PVC with S3 bucket (update Loki config `storage_config`)

### IAM / Identity
- [ ] Enable IRSA (IAM Roles for Service Accounts) for any pod needing AWS API access (Loki → S3, etc.)
- [ ] Scope IAM policies to least-privilege (e.g. Loki S3 role: `s3:GetObject`, `s3:PutObject` on the specific bucket only)
- [ ] Remove any hardcoded AWS credentials; rely entirely on IRSA

### Networking
- [ ] Deploy OTel Collector as a DaemonSet (one per node) to eliminate cross-node telemetry hops, or scale the Deployment behind an NLB
- [ ] Enable VPC CNI network policy enforcement (or use Calico) so Kubernetes NetworkPolicies are actually enforced on EKS
- [ ] Restrict Prometheus and Grafana to internal VPC access only (no public Ingress)

### Cluster hardening
- [ ] Enable EKS control plane logging (API, audit, authenticator, controllerManager, scheduler)
- [ ] Use managed node groups with bottlerocket OS for reduced attack surface
- [ ] Enable AWS GuardDuty for EKS runtime threat detection
- [ ] Apply Pod Security Standards (`restricted` profile) at the namespace level

---

## Scalability (for high-volume production)

| Component | Current | Production alternative |
|---|---|---|
| Loki | All-in-one single binary | Microservices mode + S3 backend |
| Prometheus | Single instance | HA pair + Thanos sidecar for long-term storage |
| Jaeger | All-in-one + badger | Jaeger Collector + OpenSearch backend |
| OTel Collector | Single Deployment | DaemonSet per node or scaled Deployment + HPA |
| Trace sampling | Tail sampling in collector | Add head sampling at SDK level for very high volume |

---

## What's already production-grade (no action needed)

- Non-root containers, read-only filesystems, dropped capabilities, seccomp
- RBAC with least-privilege ServiceAccounts
- NetworkPolicies (deny-all + explicit allow)
- HPA, PDB, pod anti-affinity for app services
- PersistentVolumeClaims for all stateful components
- Alerting rules + Alertmanager wired to Prometheus
- Tail sampling + retry queues on OTel Collector
- Structured logs with trace correlation (logs → Jaeger deep links)
- Kustomize overlay pattern ready for EKS overlay
- `deployment.environment` label flowing through to Loki and traces
- Container image non-root user in Dockerfiles
- `.dockerignore` on all services
