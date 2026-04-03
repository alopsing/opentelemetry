#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Continuous background load — runs until Ctrl+C.
# Spawns N parallel workers each sending requests in a loop.
# Good for keeping Grafana dashboards populated while exploring.
#
# Usage: ./scripts/load-test-continuous.sh [workers] [rps_per_worker]
# Default: 3 workers × 2 req/s = ~6 req/s total
# ─────────────────────────────────────────────────────────────
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
WORKERS="${1:-3}"
RPS_PER_WORKER="${2:-2}"

USERS=("user-alice" "user-bob" "user-charlie" "user-diana" "user-eve")
ITEMS=("item-001" "item-001" "item-001" "item-003" "item-004" "item-002")  # item-002 causes 409s

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

interval=$(echo "scale=3; 1/$RPS_PER_WORKER" | bc)

worker() {
  local id="$1"
  while true; do
    user="${USERS[$((RANDOM % ${#USERS[@]}))]}"
    item="${ITEMS[$((RANDOM % ${#ITEMS[@]}))]}"

    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST "${GATEWAY_URL}/order" \
      -H "Content-Type: application/json" \
      -d "{\"userId\":\"${user}\",\"itemId\":\"${item}\"}" \
      --max-time 5 2>/dev/null || echo "000")

    ts=$(date +%H:%M:%S)
    if [[ "$http_code" == "200" ]]; then
      echo -e "[${ts}] worker-${id} ${GREEN}${http_code}${NC} ${user}→${item}"
    else
      echo -e "[${ts}] worker-${id} ${YELLOW}${http_code}${NC} ${user}→${item}"
    fi

    sleep "$interval"
  done
}

cleanup() {
  echo ""
  echo -e "${BLUE}Stopping all workers...${NC}"
  kill 0
  exit 0
}
trap cleanup SIGINT SIGTERM

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Continuous Load Test (Ctrl+C to stop)         ${NC}"
echo -e "${BLUE}  Target  : ${GATEWAY_URL}                      ${NC}"
echo -e "${BLUE}  Workers : ${WORKERS}                          ${NC}"
echo -e "${BLUE}  Rate    : ~$((WORKERS * RPS_PER_WORKER)) req/s total           ${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Start workers in background
pids=()
for i in $(seq 1 "$WORKERS"); do
  worker "$i" &
  pids+=($!)
  sleep 0.1  # stagger startup slightly
done

echo -e "Started ${WORKERS} workers (pids: ${pids[*]})"
echo -e "Press ${YELLOW}Ctrl+C${NC} to stop."
echo ""

# Wait for all workers
wait
