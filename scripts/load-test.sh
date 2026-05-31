#!/usr/bin/env bash
set -euo pipefail

EDGE_IP="193.136.82.35"
BASE="http://grupo2-egs.deti.ua.pt"
DURATION_SECONDS=45
CONCURRENCY=24
LOGIN_CONCURRENCY=8
PAYMENT_CONCURRENCY=8
EVENT_LIMIT=3
PROMETHEUS_WAIT_SECONDS=10
OUTPUT_DIR=""

usage() {
  cat <<'EOF'
Usage: k8s/scripts/load-test.sh [options]

Aggressive public-DNS load test for the FlashSale Kubernetes deployment.
The script sends concurrent traffic through Composer, which then calls Auth,
Inventory, and Payment by Kubernetes internal DNS. It prints HTTP status totals,
latency percentiles, and downstream pod load-balancing percentages.

Options:
  --edge-ip IP             Edge IP used by curl --resolve. Default: 193.136.82.35
  --base URL              Public base URL. Default: http://grupo2-egs.deti.ua.pt
  --duration SECONDS      Load duration. Default: 45
  --concurrency N         Mixed Composer API workers. Default: 24
  --login-concurrency N   Extra login workers to trigger Auth rate limits. Default: 8
  --payment-concurrency N Extra payment read workers. Default: 8
  --event-limit N         Event list page size used by load calls. Default: 3
  --prom-wait SECONDS     Wait before querying Prometheus. Default: 10
  --output-dir DIR        Keep result files in DIR. Default: /tmp/egs-load-test-...
  -h, --help              Show this help.

Examples:
  k8s/scripts/load-test.sh
  k8s/scripts/load-test.sh --duration 90 --concurrency 50 --login-concurrency 20
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --edge-ip) EDGE_IP="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --duration) DURATION_SECONDS="$2"; shift 2 ;;
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    --login-concurrency) LOGIN_CONCURRENCY="$2"; shift 2 ;;
    --payment-concurrency) PAYMENT_CONCURRENCY="$2"; shift 2 ;;
    --event-limit) EVENT_LIMIT="$2"; shift 2 ;;
    --prom-wait) PROMETHEUS_WAIT_SECONDS="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "${OUTPUT_DIR}" ]]; then
  OUTPUT_DIR="/tmp/egs-load-test-$(date +%Y%m%d%H%M%S)"
fi

mkdir -p "${OUTPUT_DIR}"
RESULTS_FILE="${OUTPUT_DIR}/requests.tsv"
METRICS_BEFORE="${OUTPUT_DIR}/metrics-before.prom"
METRICS_AFTER="${OUTPUT_DIR}/metrics-after.prom"
PROMETHEUS_JSON="${OUTPUT_DIR}/prometheus-upstream.json"

: >"${RESULTS_FILE}"

curl_resolve=(
  --resolve "grupo2-egs.deti.ua.pt:80:${EDGE_IP}"
)

json_get() {
  local key="$1"
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$key',''))" 2>/dev/null
}

request() {
  local route="$1"
  local method="$2"
  local url="$3"
  shift 3

  local started status elapsed
  started="$(date +%s%3N)"
  status="$(
    curl -sS "${curl_resolve[@]}" \
      -o /dev/null \
      -w "%{http_code}" \
      -X "${method}" \
      "$@" \
      "${url}" 2>/dev/null || printf "000"
  )"
  elapsed=$(( $(date +%s%3N) - started ))
  printf "%s\t%s\t%s\n" "${route}" "${status}" "${elapsed}" >>"${RESULTS_FILE}"
}

snapshot_metrics() {
  local target="$1"
  curl -fsS "${curl_resolve[@]}" "${BASE}/metrics" >"${target}"
}

summarize_requests() {
  python3 - "${RESULTS_FILE}" <<'PY'
import collections
import statistics
import sys

path = sys.argv[1]
rows = []
with open(path, encoding="utf-8") as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 3:
            continue
        route, status, elapsed = parts
        try:
            elapsed = int(elapsed)
        except ValueError:
            elapsed = 0
        rows.append((route, status, elapsed))

print("\nHTTP result summary")
print("===================")
print(f"total_requests: {len(rows)}")

by_status = collections.Counter(status for _, status, _ in rows)
print("status_counts:")
for status, count in sorted(by_status.items()):
    print(f"  {status}: {count}")

print("\nroute_counts:")
for (route, status), count in sorted(collections.Counter((r, s) for r, s, _ in rows).items()):
    print(f"  {route:24s} {status}: {count}")

latencies = [elapsed for _, status, elapsed in rows if status != "000"]
if latencies:
    latencies.sort()
    def pct(p):
        idx = min(len(latencies) - 1, int(round((p / 100) * (len(latencies) - 1))))
        return latencies[idx]
    print("\nlatency_ms:")
    print(f"  min: {latencies[0]}")
    print(f"  p50: {pct(50)}")
    print(f"  p90: {pct(90)}")
    print(f"  p95: {pct(95)}")
    print(f"  p99: {pct(99)}")
    print(f"  max: {latencies[-1]}")
PY
}

summarize_metric_delta() {
  python3 - "${METRICS_BEFORE}" "${METRICS_AFTER}" <<'PY'
import collections
import re
import sys

metric = "flashsale_composer_upstream_api_calls_total"
line_re = re.compile(rf"^{metric}\{{([^}}]*)\}}\s+([0-9.eE+-]+)")

def labels_to_dict(raw):
    labels = {}
    for match in re.finditer(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"', raw):
        labels[match.group(1)] = match.group(2).replace('\\"', '"')
    return labels

def load(path):
    data = collections.Counter()
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            match = line_re.match(line.strip())
            if not match:
                continue
            labels = labels_to_dict(match.group(1))
            key = (
                labels.get("service", "unknown"),
                labels.get("upstream_pod", "unknown"),
                labels.get("method", "unknown"),
                labels.get("path", "unknown"),
                labels.get("status_class", "unknown"),
            )
            data[key] += float(match.group(2))
    return data

before = load(sys.argv[1])
after = load(sys.argv[2])
delta = collections.Counter()
for key, value in after.items():
    diff = value - before.get(key, 0.0)
    if diff > 0:
        delta[key] += diff

print("\nImmediate downstream load-balancing delta from /metrics")
print("=======================================================")
if not delta:
    print("No upstream metric delta found. Composer may not have scraped downstream calls yet.")
    raise SystemExit

by_service_pod = collections.Counter()
by_service_total = collections.Counter()
by_status = collections.Counter()

for (service, pod, method, path, status_class), count in delta.items():
    by_service_pod[(service, pod)] += count
    by_service_total[service] += count
    by_status[(service, status_class)] += count

for service in sorted(by_service_total):
    total = by_service_total[service]
    print(f"\n{service}: total={int(total)}")
    pods = [
        (pod, count)
        for (svc, pod), count in by_service_pod.items()
        if svc == service
    ]
    for pod, count in sorted(pods, key=lambda item: (-item[1], item[0])):
        pct = (count / total * 100.0) if total else 0.0
        print(f"  {pod:42s} {int(count):6d} calls  {pct:6.2f}%")
    status_bits = [
        f"{status_class}={int(count)}"
        for (svc, status_class), count in sorted(by_status.items())
        if svc == service
    ]
    print("  status_classes:", ", ".join(status_bits))
PY
}

query_prometheus() {
  local window_seconds=$(( DURATION_SECONDS + PROMETHEUS_WAIT_SECONDS + 60 ))
  local query="sum by (service, upstream_pod, status_class) (increase(flashsale_composer_upstream_api_calls_total[${window_seconds}s]))"

  curl -fsS "${curl_resolve[@]}" --get "${BASE}/prometheus/api/v1/query" \
    --data-urlencode "query=${query}" >"${PROMETHEUS_JSON}" || return 0

  python3 - "${PROMETHEUS_JSON}" <<'PY'
import collections
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
print("\nPrometheus downstream load-balancing increase")
print("=============================================")
if payload.get("status") != "success":
    print(payload)
    raise SystemExit

series = payload.get("data", {}).get("result", [])
if not series:
    print("No Prometheus series yet. Wait for another scrape or increase --prom-wait.")
    raise SystemExit

by_service_pod = collections.Counter()
by_service_total = collections.Counter()
by_service_status = collections.Counter()
for item in series:
    metric = item.get("metric", {})
    value = float(item.get("value", [0, 0])[1])
    if value <= 0:
        continue
    service = metric.get("service", "unknown")
    pod = metric.get("upstream_pod", "unknown")
    status_class = metric.get("status_class", "unknown")
    by_service_pod[(service, pod)] += value
    by_service_total[service] += value
    by_service_status[(service, status_class)] += value

for service in sorted(by_service_total):
    total = by_service_total[service]
    print(f"\n{service}: total={total:.1f}")
    pods = [
        (pod, count)
        for (svc, pod), count in by_service_pod.items()
        if svc == service
    ]
    for pod, count in sorted(pods, key=lambda item: (-item[1], item[0])):
        pct = (count / total * 100.0) if total else 0.0
        print(f"  {pod:42s} {count:8.1f} calls  {pct:6.2f}%")
    status_bits = [
        f"{status_class}={count:.1f}"
        for (svc, status_class), count in sorted(by_service_status.items())
        if svc == service
    ]
    print("  status_classes:", ", ".join(status_bits))
PY
}

echo "Load test configuration"
echo "======================="
echo "base: ${BASE}"
echo "edge_ip: ${EDGE_IP}"
echo "duration_seconds: ${DURATION_SECONDS}"
echo "mixed_concurrency: ${CONCURRENCY}"
echo "login_concurrency: ${LOGIN_CONCURRENCY}"
echo "payment_concurrency: ${PAYMENT_CONCURRENCY}"
echo "output_dir: ${OUTPUT_DIR}"

echo
echo "1. Checking Composer health"
curl -fsS "${curl_resolve[@]}" "${BASE}/health" | python3 -m json.tool

EMAIL="k8s-load-$(date +%s)@prom.pt"
PASSWORD="Teste1234!"
TOKEN=""
EVENT_ID=""
CREATED_EVENT_ID=""

cleanup() {
  if [[ -n "${CREATED_EVENT_ID}" && -n "${TOKEN}" ]]; then
    curl -fsS "${curl_resolve[@]}" -X DELETE "${BASE}/api/events/${CREATED_EVENT_ID}" \
      -H "Authorization: Bearer ${TOKEN}" >/dev/null || true
  fi
}
trap cleanup EXIT

echo
echo "2. Creating a test user and payment account"
curl -fsS "${curl_resolve[@]}" -X POST "${BASE}/api/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\",\"full_name\":\"K8s Load Test\"}" >/dev/null
LOGIN_JSON="$(curl -fsS "${curl_resolve[@]}" -X POST "${BASE}/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}")"
TOKEN="$(printf "%s" "${LOGIN_JSON}" | json_get access_token)"
test -n "${TOKEN}"
curl -fsS "${curl_resolve[@]}" -X POST "${BASE}/api/payment-account/setup" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{}' >/dev/null || true

echo
echo "3. Finding or creating one published event for ticket-read traffic"
EVENTS_JSON="$(curl -fsS "${curl_resolve[@]}" --get "${BASE}/api/events" --data-urlencode "limit=1")"
EVENT_ID="$(printf "%s" "${EVENTS_JSON}" | python3 -c 'import sys,json; d=json.load(sys.stdin); items=d.get("data") or []; print(items[0].get("id","") if items else "")')"
if [[ -z "${EVENT_ID}" ]]; then
  EVENT_JSON="$(curl -fsS "${curl_resolve[@]}" -X POST "${BASE}/api/events" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TOKEN}" \
    -d '{"name":"K8s Load Test Event","venue":"Lisboa","date":"2026-12-03T21:00:00Z"}')"
  EVENT_ID="$(printf "%s" "${EVENT_JSON}" | json_get id)"
  CREATED_EVENT_ID="${EVENT_ID}"
  curl -fsS "${curl_resolve[@]}" -X POST "${BASE}/api/events/${EVENT_ID}/tickets" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TOKEN}" \
    -d '{"category":"Load Test","price":10.00,"currency":"EUR","quantity":100}' >/dev/null
  curl -fsS "${curl_resolve[@]}" -X PUT "${BASE}/api/events/${EVENT_ID}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TOKEN}" \
    -d '{"status":"published"}' >/dev/null
fi
echo "event_id: ${EVENT_ID}"

echo
echo "4. Capturing pre-test Composer metrics"
snapshot_metrics "${METRICS_BEFORE}"

END_AT=$(( $(date +%s) + DURATION_SECONDS ))
PIDS=()

mixed_worker() {
  local worker_id="$1"
  while [[ "$(date +%s)" -lt "${END_AT}" ]]; do
    case $(( worker_id % 4 )) in
      0)
        request "inventory.events" "GET" "${BASE}/api/events?limit=${EVENT_LIMIT}"
        ;;
      1)
        request "inventory.tickets" "GET" "${BASE}/api/events/${EVENT_ID}/tickets?status=available&limit=10"
        ;;
      2)
        request "auth.me" "GET" "${BASE}/api/auth/me" -H "Authorization: Bearer ${TOKEN}"
        ;;
      *)
        request "payment.account" "GET" "${BASE}/api/payment-account" -H "Authorization: Bearer ${TOKEN}"
        ;;
    esac
  done
}

login_worker() {
  while [[ "$(date +%s)" -lt "${END_AT}" ]]; do
    request "auth.login" "POST" "${BASE}/api/auth/login" \
      -H "Content-Type: application/json" \
      -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}"
  done
}

payment_worker() {
  while [[ "$(date +%s)" -lt "${END_AT}" ]]; do
    request "payment.list" "GET" "${BASE}/api/payments?limit=5" -H "Authorization: Bearer ${TOKEN}"
  done
}

echo
echo "5. Starting load"
for i in $(seq 1 "${CONCURRENCY}"); do
  mixed_worker "${i}" &
  PIDS+=("$!")
done
for _ in $(seq 1 "${LOGIN_CONCURRENCY}"); do
  login_worker &
  PIDS+=("$!")
done
for _ in $(seq 1 "${PAYMENT_CONCURRENCY}"); do
  payment_worker &
  PIDS+=("$!")
done

for pid in "${PIDS[@]}"; do
  wait "${pid}"
done

echo
echo "6. Capturing post-test Composer metrics"
snapshot_metrics "${METRICS_AFTER}"

summarize_requests
summarize_metric_delta

echo
echo "Waiting ${PROMETHEUS_WAIT_SECONDS}s for Prometheus to scrape..."
sleep "${PROMETHEUS_WAIT_SECONDS}"
query_prometheus

echo
echo "Results saved in: ${OUTPUT_DIR}"
echo "Expected under aggressive load: some 429, 5xx, or timeout status codes may appear once service rate limits are exceeded."
