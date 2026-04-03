#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Error scenario load test — deliberately sends bad requests
# to populate error traces, error logs, and error rate metrics.
#
# Scenarios:
#   - out-of-stock items (item-002 has quantity=0 → 409)
#   - missing fields (no itemId → 400 from order-service)
#   - invalid JSON (→ 400 from express)
#   - valid requests mixed in to keep baseline
#
# Usage: ./scripts/load-test-errors.sh [duration_seconds]
# ─────────────────────────────────────────────────────────────
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
DURATION="${1:-60}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

total=0; success=0; client_err=0; server_err=0

send() {
  local label="$1"; shift
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" "$@" --max-time 5 2>/dev/null || echo "000")
  total=$((total + 1))

  case "$http_code" in
    2*) success=$((success + 1));    echo -e "  ${GREEN}✓ ${http_code}${NC} ${label}" ;;
    4*) client_err=$((client_err+1)); echo -e "  ${YELLOW}⚠ ${http_code}${NC} ${label}" ;;
    *)  server_err=$((server_err+1)); echo -e "  ${RED}✗ ${http_code}${NC} ${label}" ;;
  esac
}

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Error Scenario Load Test                      ${NC}"
echo -e "${BLUE}  Target   : ${GATEWAY_URL}                     ${NC}"
echo -e "${BLUE}  Duration : ${DURATION}s                       ${NC}"
echo -e "${BLUE}  Mix: 40% success, 30% out-of-stock, 30% bad  ${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

start_time=$(date +%s)
end_time=$((start_time + DURATION))

while [[ $(date +%s) -lt $end_time ]]; do
  roll=$((RANDOM % 10))

  if [[ $roll -lt 4 ]]; then
    # 40% — valid request (item-001 or item-003 are in stock)
    item="item-00$((( RANDOM % 2 ) * 2 + 1))"  # item-001 or item-003
    send "valid order → ${item}" \
      -X POST "${GATEWAY_URL}/order" \
      -H "Content-Type: application/json" \
      -d "{\"userId\":\"user-$((RANDOM % 5 + 1))\",\"itemId\":\"${item}\"}"

  elif [[ $roll -lt 7 ]]; then
    # 30% — out-of-stock (item-002 has quantity=0 → 409)
    send "out-of-stock → item-002" \
      -X POST "${GATEWAY_URL}/order" \
      -H "Content-Type: application/json" \
      -d '{"userId":"user-test","itemId":"item-002"}'

  elif [[ $roll -lt 9 ]]; then
    # 20% — missing required field (no orderId forwarded, order-service returns 400)
    send "missing itemId" \
      -X POST "${GATEWAY_URL}/order" \
      -H "Content-Type: application/json" \
      -d '{"userId":"user-bad"}'

  else
    # 10% — malformed JSON
    send "malformed JSON" \
      -X POST "${GATEWAY_URL}/order" \
      -H "Content-Type: application/json" \
      -d 'not-json-at-all'
  fi

  sleep 0.3
done

elapsed=$(( $(date +%s) - start_time ))
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Total      : ${total}"
echo -e "  ${GREEN}2xx Success${NC} : ${success}"
echo -e "  ${YELLOW}4xx Client ${NC} : ${client_err}"
echo -e "  ${RED}5xx Server ${NC} : ${server_err}"
echo -e "  Duration   : ${elapsed}s"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
