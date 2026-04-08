#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# OpenTelemetry POC Bootstrap Script
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="otel-poc"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ─────────────────────────────────────────────────────────────
# 1. Check prerequisites
# ─────────────────────────────────────────────────────────────
check_prerequisites() {
  log_info "Checking prerequisites..."
  local missing=0

  for cmd in kind kubectl docker; do
    if command -v "$cmd" &>/dev/null; then
      log_success "$cmd found: $(command -v "$cmd")"
    else
      log_error "$cmd is not installed or not in PATH"
      missing=$((missing + 1))
    fi
  done

  if ! docker info &>/dev/null; then
    log_error "Docker daemon is not running. Please start Docker first."
    exit 1
  fi

  if [[ $missing -gt 0 ]]; then
    log_error "$missing prerequisite(s) missing. Please install them and re-run."
    echo ""
    echo "  kind:    https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
    echo "  kubectl: https://kubernetes.io/docs/tasks/tools/"
    echo "  docker:  https://docs.docker.com/get-docker/"
    exit 1
  fi

  log_success "All prerequisites satisfied."
}

# ─────────────────────────────────────────────────────────────
# 2. Create Kind cluster
# ─────────────────────────────────────────────────────────────
create_cluster() {
  log_info "Checking for existing Kind cluster '${CLUSTER_NAME}'..."

  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    log_warn "Cluster '${CLUSTER_NAME}' already exists. Skipping creation."
  else
    log_info "Creating Kind cluster '${CLUSTER_NAME}'..."
    kind create cluster --config "${SCRIPT_DIR}/kind-config.yaml"
    log_success "Cluster '${CLUSTER_NAME}' created."
  fi

  log_info "Setting kubectl context to kind-${CLUSTER_NAME}..."
  kubectl config use-context "kind-${CLUSTER_NAME}"
  log_success "kubectl context set."
}

# ─────────────────────────────────────────────────────────────
# 3. Build Docker images
# ─────────────────────────────────────────────────────────────
build_images() {
  log_info "Building Docker images..."

  local services=("api-gateway" "order-service" "inventory-service" "product-service")
  for svc in "${services[@]}"; do
    log_info "Building ${svc}:latest..."
    docker build \
      --tag "${svc}:latest" \
      --file "${SCRIPT_DIR}/services/${svc}/Dockerfile" \
      "${SCRIPT_DIR}/services/${svc}"
    log_success "Built ${svc}:latest"
  done
}

# ─────────────────────────────────────────────────────────────
# 4. Load images into Kind
# ─────────────────────────────────────────────────────────────
load_images() {
  log_info "Loading Docker images into Kind cluster '${CLUSTER_NAME}'..."

  local services=("api-gateway" "order-service" "inventory-service" "product-service")
  for svc in "${services[@]}"; do
    log_info "Loading ${svc}:latest into kind..."
    kind load docker-image "${svc}:latest" --name "${CLUSTER_NAME}"
    log_success "Loaded ${svc}:latest"
  done
}

# ─────────────────────────────────────────────────────────────
# 5. Apply Kubernetes manifests
# ─────────────────────────────────────────────────────────────
apply_manifests() {
  log_info "Applying Kubernetes manifests via Kustomize..."

  kubectl apply -k "${SCRIPT_DIR}/k8s/overlays/local/"

  log_success "All manifests applied."
}

# ─────────────────────────────────────────────────────────────
# 6. Install metrics-server (required for HPA / kubectl top)
# ─────────────────────────────────────────────────────────────
install_metrics_server() {
  log_info "Installing metrics-server..."
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  kubectl patch deployment metrics-server -n kube-system --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
  kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s
  log_success "metrics-server is ready."
}

# ─────────────────────────────────────────────────────────────
# 7. Wait for deployments to be ready
# ─────────────────────────────────────────────────────────────
wait_for_deployments() {
  log_info "Waiting for deployments to be ready (timeout: 5 minutes each)..."

  local deployments=(
    "otel-collector"
    "jaeger"
    "prometheus"
    "alertmanager"
    "loki"
    "grafana"
    "postgres"
    "product-service"
    "inventory-service"
    "order-service"
    "api-gateway"
  )

  for deploy in "${deployments[@]}"; do
    log_info "Waiting for deployment/${deploy}..."
    if kubectl rollout status deployment/"${deploy}" \
        --namespace otel-poc \
        --timeout=300s; then
      log_success "deployment/${deploy} is ready."
    else
      log_warn "deployment/${deploy} did not become ready within 5 minutes."
      log_warn "Check with: kubectl get pods -n otel-poc"
    fi
  done
}

# ─────────────────────────────────────────────────────────────
# 7. Print access URLs and usage info
# ─────────────────────────────────────────────────────────────
print_access_info() {
  echo ""
  echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}   OpenTelemetry POC — Deployment Complete!         ${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${BLUE}Access URLs (from your host machine):${NC}"
  echo ""
  echo -e "  ${GREEN}API Gateway${NC}        http://localhost:8080"
  echo -e "  ${GREEN}Grafana${NC}            http://localhost:3000"
  echo -e "  ${GREEN}Jaeger UI${NC}          http://localhost:16686"
  echo -e "  ${GREEN}Prometheus${NC}         http://localhost:9090"
  echo ""
  echo -e "${BLUE}Quick test — generate a trace:${NC}"
  echo ""
  echo '  curl -s -X POST http://localhost:8080/order \'
  echo '    -H "Content-Type: application/json" \'
  echo '    -d '"'"'{"userId":"user-123","itemId":"item-001"}'"'"' | jq .'
  echo ""
  echo -e "${BLUE}Health checks:${NC}"
  echo ""
  echo "  curl http://localhost:8080/health"
  echo ""
  echo -e "${BLUE}Kubernetes commands:${NC}"
  echo ""
  echo "  kubectl get pods -n otel-poc"
  echo "  kubectl logs -n otel-poc deployment/api-gateway -f"
  echo "  kubectl logs -n otel-poc deployment/otel-collector -f"
  echo ""
  echo -e "${BLUE}To tear down the cluster:${NC}"
  echo ""
  echo "  kind delete cluster --name ${CLUSTER_NAME}"
  echo ""
  echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
}

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║   OpenTelemetry End-to-End POC Bootstrap         ║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
  echo ""

  check_prerequisites
  create_cluster
  build_images
  load_images
  apply_manifests
  install_metrics_server
  wait_for_deployments
  print_access_info
}

main "$@"
