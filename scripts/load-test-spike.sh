#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Spike load test — alternates between quiet and burst phases
# Useful for seeing autoscaling, latency spikes, and error rate
# spikes in Grafana dashboards.
#
# Usage: ./scripts/load-test-spike.sh [cycles]
# Each cycle = 20s quiet (2 req/s) + 20s burst (30 req/s)
# ─────────────────────────────────────────────────────────────
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
CYCLES="${1:-5}"

USERS=("user-alice" "user-bob" "user-charlie" "user-diana" "user-eve" "user-frank")
ITEMS=("item-001" "item-002" "item-003" "item-004")

QUIET_RPS=2
QUIET_DURATION=20
BURST_RPS=30
BURST_DURATION=20

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

total=0
success=0
failure=0

send_request() {
  local user="${USERS[$((RANDOM % ${#USERS[@]}))]}"
  local item="${ITEMS[$((RANDOM % ${#ITEMS[@]}))]}"

  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${GATEWAY_URL}/order" \
    -H "Content-Type: application/json" \
    -d "{\"userId\":\"${user}\",\"itemId\":\"${item}\"}" \
    --max-time 3 2>/dev/null || echo "000")

  total=$((total + 1))
  if [[ "$http_code" == "200" ]]; then
    success=$((success + 1))
    echo -e "  ${GREEN}✓${NC} ${http_code} ${user}→${item}"
  else
    failure=$((failure + 1))
    echo -e "  ${RED}✗${NC} ${http_code} ${user}→${item}"
  fi
}

run_phase() {
  local label="$1"
  local rps="$2"
  local duration="$3"
  local color="$4"
  local interval
  interval=$(echo "scale=4; 1/$rps" | bc)
  local end_time=$(( $(date +%s) + duration ))

  echo -e "${color}━━━ ${label} phase: ${rps} req/s for ${duration}s ━━━${NC}"

  while [[ $(date +%s) -lt $end_time ]]; do
    send_request
    sleep "$interval"
  done
}

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Spike Load Test                               ${NC}"
echo -e "${BLUE}  Target : ${GATEWAY_URL}                       ${NC}"
echo -e "${BLUE}  Cycles : ${CYCLES}                            ${NC}"
echo -e "${BLUE}  Pattern: ${QUIET_RPS} req/s → ${BURST_RPS} req/s (repeat)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

start_time=$(date +%s)

for i in $(seq 1 "$CYCLES"); do
  echo ""
  echo -e "${CYAN}Cycle ${i}/${CYCLES}${NC}"
  run_phase "QUIET " "$QUIET_RPS"  "$QUIET_DURATION"  "$GREEN"
  run_phase "BURST " "$BURST_RPS"  "$BURST_DURATION"  "$YELLOW"
done

elapsed=$(( $(date +%s) - start_time ))
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Total    : ${total}"
echo -e "  ${GREEN}Success${NC}  : ${success}"
echo -e "  ${RED}Failures${NC} : ${failure}"
echo -e "  Duration : ${elapsed}s"
echo -e "  Avg rate : $(echo "scale=1; $total/$elapsed" | bc) req/s"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
