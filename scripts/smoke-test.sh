#!/usr/bin/env bash
set -euo pipefail

EDGE_IP="${1:-193.136.82.35}"
BASE="http://composer.flashsale"
PAYMENT_BASE="http://payment.flashsale"

curl_resolve=(
  --resolve "composer.flashsale:80:${EDGE_IP}"
  --resolve "auth.flashsale:80:${EDGE_IP}"
  --resolve "inventory.flashsale:80:${EDGE_IP}"
  --resolve "payment.flashsale:80:${EDGE_IP}"
  --resolve "grafana.flashsale:80:${EDGE_IP}"
  --resolve "jaeger.flashsale:80:${EDGE_IP}"
  --resolve "prometheus.flashsale:80:${EDGE_IP}"
  --resolve "mail.flashsale:80:${EDGE_IP}"
)

json_get() {
  local key="$1"
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$key',''))" 2>/dev/null
}

echo "1. Composer health"
curl -fsS "${curl_resolve[@]}" "${BASE}/health" | python3 -m json.tool

EMAIL="k8s-smoke-$(date +%s)@prom.pt"
PASSWORD="Teste1234!"

echo "2. Register/login promoter through Composer"
curl -fsS "${curl_resolve[@]}" -X POST "${BASE}/api/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\",\"full_name\":\"K8s Smoke\"}" >/dev/null
LOGIN_JSON="$(curl -fsS "${curl_resolve[@]}" -X POST "${BASE}/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}")"
TOKEN="$(printf "%s" "$LOGIN_JSON" | json_get access_token)"
test -n "$TOKEN"

echo "3. KPI dashboard payload"
curl -fsS "${curl_resolve[@]}" "${BASE}/api/kpi/dashboard" \
  -H "Authorization: Bearer ${TOKEN}" | python3 -m json.tool >/tmp/egs-kpi.json
python3 - <<'PY'
import json
data = json.load(open("/tmp/egs-kpi.json"))
print("overall_status:", data.get("overall_status"))
print("services:", ", ".join(f"{s.get('name')}={s.get('status')}" for s in data.get("services", [])))
PY

echo "4. Forgot-password email through Auth -> MailHog"
curl -fsS "${curl_resolve[@]}" -X POST "${BASE}/api/auth/forgot-password" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${EMAIL}\"}" | python3 -m json.tool
sleep 2
curl -fsS "${curl_resolve[@]}" "http://mail.flashsale/api/v2/messages?limit=50" >/tmp/egs-mailhog.json
python3 - "$EMAIL" <<'PY'
import json, sys
email = sys.argv[1].lower()
data = json.load(open("/tmp/egs-mailhog.json"))
items = data.get("items", [])
matches = [item for item in items if email in json.dumps(item).lower()]
assert matches, f"no reset email found for {email}"
print("mailhog_reset_emails:", len(matches))
PY

echo "5. Create event and tickets through Composer -> Inventory"
EVENT_JSON="$(curl -fsS "${curl_resolve[@]}" -X POST "${BASE}/api/events" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{"name":"K8s Smoke Event","venue":"Lisboa","date":"2026-12-01T18:00:00Z"}')"
EVENT_ID="$(printf "%s" "$EVENT_JSON" | json_get id)"
test -n "$EVENT_ID"
curl -fsS "${curl_resolve[@]}" -X POST "${BASE}/api/events/${EVENT_ID}/tickets" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{"category":"General Admission","price":25.00,"currency":"EUR","quantity":3}' >/dev/null
curl -fsS "${curl_resolve[@]}" -X PUT "${BASE}/api/events/${EVENT_ID}" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{"status":"published"}' >/dev/null

echo "6. Payment account and checkout through Composer -> Payment"
curl -fsS "${curl_resolve[@]}" -X POST "${BASE}/api/payment-account/setup" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{}' >/dev/null
CHECKOUT_JSON="$(curl -fsS "${curl_resolve[@]}" -X POST "${BASE}/api/checkout" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d "{\"event_id\":\"${EVENT_ID}\",\"quantity\":1,\"success_url\":\"${BASE}/?status=success\",\"cancel_url\":\"${BASE}/?status=cancel\",\"amount_cents\":1500}")"
SESSION_ID="$(printf "%s" "$CHECKOUT_JSON" | json_get session_id)"
CHECKOUT_URL="$(printf "%s" "$CHECKOUT_JSON" | json_get checkout_url)"
test -n "$SESSION_ID"
echo "checkout_url=${CHECKOUT_URL}"

echo "7. Authorize hosted checkout directly on Payment"
curl -fsS "${curl_resolve[@]}" -X POST "${PAYMENT_BASE}/api/v1/checkout/${SESSION_ID}/authorize" \
  -H "Authorization: Bearer ${TOKEN}" | python3 -m json.tool

echo "8. Composer metrics and Prometheus/Grafana KPI checks"
curl -fsS "${curl_resolve[@]}" "${BASE}/metrics" >/tmp/egs-metrics.prom
grep -q "flashsale_auth_users_total" /tmp/egs-metrics.prom
grep -q "flashsale_inventory_tickets_total" /tmp/egs-metrics.prom
grep -q "flashsale_payment_payments_total" /tmp/egs-metrics.prom
sleep 8
curl -fsS "${curl_resolve[@]}" --get "http://prometheus.flashsale/api/v1/query" \
  --data-urlencode 'query=flashsale_payment_payments_total' >/tmp/egs-prometheus-query.json
python3 - <<'PY'
import json
data = json.load(open("/tmp/egs-prometheus-query.json"))
assert data.get("status") == "success", data
assert data.get("data", {}).get("result"), data
print("prometheus_samples:", len(data["data"]["result"]))
PY
curl -fsS -u admin:admin "${curl_resolve[@]}" \
  "http://grafana.flashsale/api/dashboards/uid/flashsale-platform-kpis" >/tmp/egs-grafana-dashboard.json
python3 - <<'PY'
import json
data = json.load(open("/tmp/egs-grafana-dashboard.json"))
title = data.get("dashboard", {}).get("title")
assert title == "FlashSale Platform KPIs", title
print("grafana_dashboard:", title)
PY

echo "9. Grafana, Jaeger, and MailHog ingress checks"
curl -fsS -I "${curl_resolve[@]}" "http://grafana.flashsale/login" | head -n 1
curl -fsS -I "${curl_resolve[@]}" "http://jaeger.flashsale/" | head -n 1
curl -fsS "${curl_resolve[@]}" "http://mail.flashsale/api/v2/messages?limit=1" >/dev/null
echo "HTTP/1.1 200 OK (MailHog API)"

echo "Smoke test passed"
