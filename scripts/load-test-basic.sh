#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Basic load test — steady stream of mixed order requests
# Usage: ./scripts/load-test-basic.sh [requests_per_second] [duration_seconds]
# ─────────────────────────────────────────────────────────────
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
RPS="${1:-5}"
DURATION="${2:-60}"

USERS=("user-alice" "user-bob" "user-charlie" "user-diana" "user-eve")
ITEMS=("item-001" "item-002" "item-003" "item-004")

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

success=0
failure=0
total=0
start_time=$(date +%s)
end_time=$((start_time + DURATION))
interval=$(echo "scale=3; 1/$RPS" | bc)

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Basic Load Test                               ${NC}"
echo -e "${BLUE}  Target : ${GATEWAY_URL}                       ${NC}"
echo -e "${BLUE}  Rate   : ${RPS} req/s for ${DURATION}s        ${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

while [[ $(date +%s) -lt $end_time ]]; do
  user="${USERS[$((RANDOM % ${#USERS[@]}))]}"
  item="${ITEMS[$((RANDOM % ${#ITEMS[@]}))]}"

  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${GATEWAY_URL}/order" \
    -H "Content-Type: application/json" \
    -d "{\"userId\":\"${user}\",\"itemId\":\"${item}\"}" \
    --max-time 5)

  total=$((total + 1))
  if [[ "$http_code" == "200" ]]; then
    success=$((success + 1))
    echo -e "${GREEN}[OK  $http_code]${NC} ${user} → ${item}  (total: ${total})"
  else
    failure=$((failure + 1))
    echo -e "${RED}[ERR $http_code]${NC} ${user} → ${item}  (total: ${total})"
  fi

  sleep "$interval"
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
