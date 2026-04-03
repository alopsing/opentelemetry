#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Production traffic simulator
#
# Runs named scenarios that mimic real traffic patterns.
# Each scenario controls: request mix, concurrency, rate,
# duration, and expected outcome distribution.
#
# Usage:
#   ./scripts/simulate.sh <scenario> [options]
#
# Scenarios:
#   normal      Steady mixed traffic. ~85% success, ~12% 409, ~3% 4xx.
#   degraded    Elevated error rate. ~40% success, ~30% 409, ~30% 4xx/5xx.
#   spike       Traffic spike: ramp up → sustain → ramp down.
#   soak        Long-running low-rate test to surface memory leaks / drift.
#   recovery    Sends bad traffic then good traffic to show recovery in dashboards.
#   chaos       Randomised mix of all failure modes simultaneously.
#
# Options:
#   --url   <url>      Gateway URL (default: http://localhost:8080)
#   --rate  <n>        Requests per second (overrides scenario default)
#   --dur   <s>        Duration in seconds (overrides scenario default)
#   --conc  <n>        Concurrent workers (overrides scenario default)
#
# Examples:
#   ./scripts/simulate.sh normal
#   ./scripts/simulate.sh spike --url http://localhost:8080
#   ./scripts/simulate.sh degraded --rate 20 --dur 120
#   ./scripts/simulate.sh soak --dur 3600
# ─────────────────────────────────────────────────────────────
set -euo pipefail

# ── colours ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

# ── shared state (written by workers, read by reporter) ──────
TMPDIR_SIM=$(mktemp -d)
STATS_FILE="${TMPDIR_SIM}/stats"
echo "0 0 0 0 0" > "$STATS_FILE"   # total 2xx 4xx 5xx timeout
LOCK="${TMPDIR_SIM}/lock"

increment() {
  local field="$1"   # 1=total 2=2xx 3=4xx 4=5xx 5=timeout
  (
    flock 9
    read -r t s c e to < "$STATS_FILE"
    case $field in
      1) t=$((t+1)) ;;
      2) t=$((t+1)); s=$((s+1)) ;;
      3) t=$((t+1)); c=$((c+1)) ;;
      4) t=$((t+1)); e=$((e+1)) ;;
      5) t=$((t+1)); to=$((to+1)) ;;
    esac
    echo "$t $s $c $e $to" > "$STATS_FILE"
  ) 9>"$LOCK"
}

read_stats() { cat "$STATS_FILE"; }

cleanup() {
  echo ""
  echo -e "${BLUE}Stopping...${NC}"
  kill 0 2>/dev/null || true
  rm -rf "$TMPDIR_SIM"
}
trap cleanup SIGINT SIGTERM

# ── request catalogue ─────────────────────────────────────────
# Each function sends one request and records the result.

USERS=("alice" "bob" "charlie" "diana" "eve" "frank" "grace" "henry")
IN_STOCK_ITEMS=("item-001" "item-003" "item-004")
OUT_OF_STOCK="item-002"
UNKNOWN_ITEM="item-999"

req_happy_path() {
  local item="${IN_STOCK_ITEMS[$((RANDOM % ${#IN_STOCK_ITEMS[@]}))]}"
  local user="user-${USERS[$((RANDOM % ${#USERS[@]}))]}"
  local code
  code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 \
    -X POST "${GATEWAY_URL}/order" \
    -H "Content-Type: application/json" \
    -d "{\"userId\":\"${user}\",\"itemId\":\"${item}\"}" 2>/dev/null || echo "000")
  log_result "$code" "happy-path" "${user}→${item}"
}

req_out_of_stock() {
  # 409 Conflict — item-002 has quantity=0
  local code
  code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 \
    -X POST "${GATEWAY_URL}/order" \
    -H "Content-Type: application/json" \
    -d "{\"userId\":\"user-buyer\",\"itemId\":\"${OUT_OF_STOCK}\"}" 2>/dev/null || echo "000")
  log_result "$code" "out-of-stock" "item-002→409"
}

req_unknown_item() {
  # 404 — item not in inventory map
  local code
  code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 \
    -X POST "${GATEWAY_URL}/order" \
    -H "Content-Type: application/json" \
    -d "{\"userId\":\"user-lost\",\"itemId\":\"${UNKNOWN_ITEM}\"}" 2>/dev/null || echo "000")
  log_result "$code" "unknown-item" "item-999→404"
}

req_missing_field() {
  # 400 — no orderId propagated, order-service rejects
  local code
  code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 \
    -X POST "${GATEWAY_URL}/order" \
    -H "Content-Type: application/json" \
    -d '{"userId":"user-incomplete"}' 2>/dev/null || echo "000")
  log_result "$code" "missing-field" "no itemId"
}

req_bad_json() {
  # 400 — express JSON parser rejects malformed body
  local code
  code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 \
    -X POST "${GATEWAY_URL}/order" \
    -H "Content-Type: application/json" \
    -d 'this-is-not-json' 2>/dev/null || echo "000")
  log_result "$code" "bad-json" "malformed body→400"
}

req_wrong_method() {
  # 404 — GET on /order endpoint (only POST supported)
  local code
  code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 \
    -X GET "${GATEWAY_URL}/order" 2>/dev/null || echo "000")
  log_result "$code" "wrong-method" "GET /order→404"
}

req_large_payload() {
  # Oversized payload — tests request body limits / slow processing
  local big
  big=$(python3 -c "import json; print(json.dumps({'userId':'user-big','itemId':'item-001','notes':'x'*10000}))" 2>/dev/null \
    || printf '{"userId":"user-big","itemId":"item-001","notes":"%0.s#" {1..500}}')
  local code
  code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 \
    -X POST "${GATEWAY_URL}/order" \
    -H "Content-Type: application/json" \
    -d "$big" 2>/dev/null || echo "000")
  log_result "$code" "large-payload" "10k body"
}

req_concurrent_burst() {
  # Fire 10 requests in parallel (simulates a brief thundering herd)
  local pids=()
  for _ in {1..10}; do
    req_happy_path &
    pids+=($!)
  done
  wait "${pids[@]}" 2>/dev/null || true
}

log_result() {
  local code="$1" label="$2" detail="$3"
  local ts; ts=$(date +%H:%M:%S)
  case "${code:0:1}" in
    2) increment 2; echo -e "[${ts}] ${GREEN}${code}${NC}  ${label}  ${detail}" ;;
    4) increment 3; echo -e "[${ts}] ${YELLOW}${code}${NC}  ${label}  ${detail}" ;;
    5) increment 4; echo -e "[${ts}] ${RED}${code}${NC}  ${label}  ${detail}" ;;
    0) increment 5; echo -e "[${ts}] ${RED}TMO${NC}  ${label}  ${detail} (timeout/conn refused)" ;;
    *) increment 4; echo -e "[${ts}] ${RED}${code}${NC}  ${label}  ${detail}" ;;
  esac
}

print_summary() {
  read -r total s2xx s4xx s5xx stmo < <(read_stats)
  local elapsed=$(( $(date +%s) - START_TIME ))
  [[ $elapsed -eq 0 ]] && elapsed=1
  local rate; rate=$(echo "scale=1; $total/$elapsed" | bc 2>/dev/null || echo "?")
  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  printf "  %-12s %s\n" "Total" "$total"
  printf "  ${GREEN}%-12s${NC} %s\n" "2xx success" "$s2xx"
  printf "  ${YELLOW}%-12s${NC} %s\n" "4xx client" "$s4xx"
  printf "  ${RED}%-12s${NC} %s\n" "5xx server" "$s5xx"
  printf "  ${RED}%-12s${NC} %s\n" "timeout/err" "$stmo"
  printf "  %-12s %ss\n" "Duration" "$elapsed"
  printf "  %-12s %s req/s\n" "Avg rate" "$rate"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ── weighted request dispatcher ───────────────────────────────
# Weights are 0-99; ranges are cumulative.
dispatch() {
  local roll=$((RANDOM % 100))
  local w2xx="$1" w409="$2" w4xx="$3" w_misc="$4"
  # w_misc covers wrong-method, large-payload, bad-json
  local t409=$((w2xx))
  local t4xx=$((w2xx + w409))
  local tmisc=$((w2xx + w409 + w4xx))

  if   [[ $roll -lt $w2xx  ]]; then req_happy_path
  elif [[ $roll -lt $t409  ]]; then req_out_of_stock
  elif [[ $roll -lt $t4xx  ]]; then
    # rotate through different 4xx types
    case $((RANDOM % 3)) in
      0) req_missing_field ;;
      1) req_unknown_item  ;;
      2) req_bad_json      ;;
    esac
  elif [[ $roll -lt $tmisc ]]; then
    case $((RANDOM % 2)) in
      0) req_wrong_method  ;;
      1) req_large_payload ;;
    esac
  else
    req_happy_path  # remaining probability → happy path
  fi
}

# ── worker loop ───────────────────────────────────────────────
worker_loop() {
  local id="$1" interval="$2" end_time="$3"
  local w2xx="$4" w409="$5" w4xx="$6" w_misc="$7"
  while [[ $(date +%s) -lt $end_time ]]; do
    dispatch "$w2xx" "$w409" "$w4xx" "$w_misc"
    sleep "$interval"
  done
}

start_workers() {
  local conc="$1" rate="$2" dur="$3"
  local w2xx="$4" w409="$5" w4xx="$6" w_misc="$7"
  local interval; interval=$(echo "scale=4; $conc/$rate" | bc)
  local end_time=$(( $(date +%s) + dur ))
  local pids=()
  for i in $(seq 1 "$conc"); do
    worker_loop "$i" "$interval" "$end_time" "$w2xx" "$w409" "$w4xx" "$w_misc" &
    pids+=($!)
    sleep 0.05
  done
  wait "${pids[@]}" 2>/dev/null || true
}

banner() {
  local name="$1" desc="$2" rate="$3" conc="$4" dur="$5" mix="$6"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}  Scenario : ${CYAN}${name}${NC}"
  echo -e "${BLUE}  ${desc}${NC}"
  echo -e "${BLUE}  URL      : ${GATEWAY_URL}${NC}"
  echo -e "${BLUE}  Rate     : ${rate} req/s  Workers: ${conc}  Duration: ${dur}s${NC}"
  echo -e "${BLUE}  Mix      : ${mix}${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ── scenarios ─────────────────────────────────────────────────

scenario_normal() {
  # Realistic production baseline:
  # ~85% happy path, ~10% out-of-stock (409), ~5% client errors (4xx)
  local rate="${OPT_RATE:-10}" conc="${OPT_CONC:-3}" dur="${OPT_DUR:-120}"
  banner "normal" "Steady production-like traffic" "$rate" "$conc" "${dur}" \
    "85% 2xx  |  10% 409  |  5% 4xx"
  start_workers "$conc" "$rate" "$dur" 85 10 5 0
}

scenario_degraded() {
  # Elevated errors — models a bad deploy or upstream dependency issue.
  # Triggers HighErrorRate alert after ~5 minutes.
  local rate="${OPT_RATE:-15}" conc="${OPT_CONC:-4}" dur="${OPT_DUR:-180}"
  banner "degraded" "Elevated error rate (bad deploy / upstream issue)" "$rate" "$conc" "${dur}" \
    "40% 2xx  |  30% 409  |  20% 4xx  |  10% misc"
  start_workers "$conc" "$rate" "$dur" 40 30 20 10
}

scenario_spike() {
  # Traffic spike: quiet → ramp → peak → ramp → quiet
  # Shows autoscaling kicking in, latency increase, then recovery.
  local base_rate="${OPT_RATE:-5}" peak_rate=40 conc="${OPT_CONC:-3}"
  local quiet_dur=30 ramp_dur=20 peak_dur="${OPT_DUR:-60}" down_dur=20 tail_dur=30

  banner "spike" "Traffic spike: quiet→ramp→peak→ramp→quiet" "$peak_rate" "$conc" \
    "$((quiet_dur + ramp_dur + peak_dur + down_dur + tail_dur))" \
    "90% 2xx  |  8% 409  |  2% 4xx"

  echo -e "${GREEN}━━━ QUIET phase (${base_rate} req/s for ${quiet_dur}s) ━━━${NC}"
  start_workers "$conc" "$base_rate" "$quiet_dur" 90 8 2 0

  echo -e "${YELLOW}━━━ RAMP UP phase (${ramp_dur}s) ━━━${NC}"
  for r in 10 20 30 "$peak_rate"; do
    start_workers "$conc" "$r" 5 90 8 2 0
  done

  echo -e "${RED}━━━ PEAK phase (${peak_rate} req/s for ${peak_dur}s) ━━━${NC}"
  start_workers "$conc" "$peak_rate" "$peak_dur" 90 8 2 0

  echo -e "${YELLOW}━━━ RAMP DOWN phase (${down_dur}s) ━━━${NC}"
  for r in 30 20 10 "$base_rate"; do
    start_workers "$conc" "$r" 5 90 8 2 0
  done

  echo -e "${GREEN}━━━ TAIL / RECOVERY phase (${tail_dur}s) ━━━${NC}"
  start_workers "$conc" "$base_rate" "$tail_dur" 90 8 2 0
}

scenario_soak() {
  # Long-running low-rate test. Surfaces memory leaks, connection pool
  # exhaustion, metric cardinality growth, and Prometheus disk growth.
  local rate="${OPT_RATE:-3}" conc="${OPT_CONC:-2}" dur="${OPT_DUR:-1800}"
  banner "soak" "Long-running soak test (watch for memory drift)" "$rate" "$conc" "${dur}" \
    "90% 2xx  |  8% 409  |  2% 4xx"
  echo -e "${YELLOW}Running for $((dur/60)) minutes. Check 'kubectl top pods -n otel-poc' periodically.${NC}"
  start_workers "$conc" "$rate" "$dur" 90 8 2 0
}

scenario_recovery() {
  # Bad traffic → good traffic.
  # Useful for watching error rate alerts fire then resolve in Grafana.
  local rate="${OPT_RATE:-10}" conc="${OPT_CONC:-3}" bad_dur=90 good_dur=90

  banner "recovery" "Bad traffic then good — watch alerts fire and resolve" "$rate" "$conc" \
    "$((bad_dur + good_dur))" "Phase 1: degraded  |  Phase 2: normal"

  echo -e "${RED}━━━ BAD PHASE — high error rate for ${bad_dur}s (alerts should fire) ━━━${NC}"
  start_workers "$conc" "$rate" "$bad_dur" 30 30 25 15

  echo -e "${GREEN}━━━ GOOD PHASE — normal traffic for ${good_dur}s (alerts should resolve) ━━━${NC}"
  start_workers "$conc" "$rate" "$good_dur" 90 8 2 0
}

scenario_chaos() {
  # All failure modes simultaneously, random concurrency per worker.
  # Models multiple issues happening at once.
  local rate="${OPT_RATE:-20}" conc="${OPT_CONC:-5}" dur="${OPT_DUR:-120}"
  banner "chaos" "All failure modes simultaneously" "$rate" "$conc" "${dur}" \
    "35% 2xx  |  25% 409  |  20% 4xx  |  20% misc errors"

  local interval; interval=$(echo "scale=4; $conc/$rate" | bc)
  local end_time=$(( $(date +%s) + dur ))
  local pids=()

  for i in $(seq 1 "$conc"); do
    (
      while [[ $(date +%s) -lt $end_time ]]; do
        # Each worker independently picks a random failure mode
        roll=$((RANDOM % 100))
        if   [[ $roll -lt 35 ]]; then req_happy_path
        elif [[ $roll -lt 60 ]]; then req_out_of_stock
        elif [[ $roll -lt 70 ]]; then req_unknown_item
        elif [[ $roll -lt 78 ]]; then req_missing_field
        elif [[ $roll -lt 84 ]]; then req_bad_json
        elif [[ $roll -lt 90 ]]; then req_wrong_method
        elif [[ $roll -lt 95 ]]; then req_large_payload
        else req_concurrent_burst      # thundering herd mini-burst
        fi
        sleep "$interval"
      done
    ) &
    pids+=($!)
    sleep 0.05
  done
  wait "${pids[@]}" 2>/dev/null || true
}

# ── argument parsing ──────────────────────────────────────────
SCENARIO="${1:-}"
shift || true

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
OPT_RATE="" OPT_DUR="" OPT_CONC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)  GATEWAY_URL="$2"; shift 2 ;;
    --rate) OPT_RATE="$2";    shift 2 ;;
    --dur)  OPT_DUR="$2";     shift 2 ;;
    --conc) OPT_CONC="$2";    shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

START_TIME=$(date +%s)

case "$SCENARIO" in
  normal)    scenario_normal    ;;
  degraded)  scenario_degraded  ;;
  spike)     scenario_spike     ;;
  soak)      scenario_soak      ;;
  recovery)  scenario_recovery  ;;
  chaos)     scenario_chaos     ;;
  "")
    echo -e "${BLUE}Usage: $0 <scenario> [--url URL] [--rate N] [--dur S] [--conc N]${NC}"
    echo ""
    echo "Scenarios:"
    echo -e "  ${CYAN}normal${NC}     Steady baseline: ~85% 2xx, ~10% 409, ~5% 4xx"
    echo -e "  ${CYAN}degraded${NC}   Elevated errors: ~40% 2xx, ~30% 409, ~30% errors"
    echo -e "  ${CYAN}spike${NC}      Traffic spike: quiet → ramp → peak → ramp → quiet"
    echo -e "  ${CYAN}soak${NC}       Long-running (default 30min) low-rate test"
    echo -e "  ${CYAN}recovery${NC}   Bad traffic then good — watch alerts fire then resolve"
    echo -e "  ${CYAN}chaos${NC}      All failure modes simultaneously"
    rm -rf "$TMPDIR_SIM"
    exit 0
    ;;
  *)
    echo "Unknown scenario: ${SCENARIO}"
    echo "Run without arguments to see available scenarios."
    rm -rf "$TMPDIR_SIM"
    exit 1
    ;;
esac

print_summary
rm -rf "$TMPDIR_SIM"
