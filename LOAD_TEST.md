# FlashSale Load Test Script

This document explains how to use `k8s/scripts/load-test.sh` to stress the deployed Kubernetes services, check rate-limit behavior, and show how traffic is distributed across service replicas.

The script sends traffic through the public DNS:

```text
http://grupo2-egs.deti.ua.pt
```

The requests enter through Traefik/Ingress, reach Composer, and Composer calls the internal Kubernetes services:

```text
load-test.sh
  -> grupo2-egs.deti.ua.pt
  -> composer
  -> auth-service
  -> inventory-service
  -> payment-service
```

## Run It

Default aggressive run:

```bash
k8s/scripts/load-test.sh
```

Short sanity run:

```bash
k8s/scripts/load-test.sh --duration 10 --concurrency 5 --login-concurrency 2 --payment-concurrency 2
```

More aggressive run:

```bash
k8s/scripts/load-test.sh --duration 90 --concurrency 50 --login-concurrency 20 --payment-concurrency 20
```

Very aggressive run:

```bash
k8s/scripts/load-test.sh --duration 180 --concurrency 100 --login-concurrency 40 --payment-concurrency 40
```

## Options

```text
--edge-ip IP
```

Edge IP used by `curl --resolve`.

Default:

```text
193.136.82.35
```

Use this if DNS is not resolving correctly from your machine.

```text
--base URL
```

Public base URL of the app.

Default:

```text
http://grupo2-egs.deti.ua.pt
```

```text
--duration SECONDS
```

How long the load phase runs.

Default:

```text
45
```

```text
--concurrency N
```

Number of mixed workers. These call:

```text
/api/events
/api/events/{event_id}/tickets
/api/auth/me
/api/payment-account
```

Default:

```text
24
```

```text
--login-concurrency N
```

Number of extra workers repeatedly calling:

```text
POST /api/auth/login
```

This is useful for showing Auth rate limits.

Default:

```text
8
```

```text
--payment-concurrency N
```

Number of extra workers repeatedly calling:

```text
GET /api/payments
```

This is useful for showing Payment Service load and rate-limit behavior.

Default:

```text
8
```

```text
--event-limit N
```

Page size used by event-list traffic.

Default:

```text
3
```

Small values avoid turning every `/api/events` call into too many downstream Inventory calls.

```text
--prom-wait SECONDS
```

How long the script waits after the load phase before querying Prometheus.

Default:

```text
10
```

Increase this if Prometheus does not show fresh samples immediately.

```text
--output-dir DIR
```

Directory where raw output files are saved.

Default:

```text
/tmp/egs-load-test-YYYYMMDDHHMMSS
```

## What The Script Does

1. Checks Composer health.
2. Creates a temporary test user.
3. Creates/uses a payment account for that user.
4. Finds an existing published event, or creates a temporary one if none exists.
5. Captures Composer metrics before the load.
6. Starts concurrent workers.
7. Captures Composer metrics after the load.
8. Prints HTTP status totals and latency percentiles.
9. Prints immediate load-balancer distribution from Composer `/metrics`.
10. Queries Prometheus for replica distribution over the test window.
11. Deletes the temporary event if the script created one.

## Reading The Results

### HTTP Status Counts

Example:

```text
HTTP result summary
===================
total_requests: 1200
status_counts:
  200: 1040
  429: 130
  503: 20
  000: 10
```

Meaning:

```text
200
```

Successful requests.

```text
429
```

Rate limit triggered. This is expected during aggressive runs.

```text
5xx
```

Service-side errors. A few may appear under heavy stress, but many indicate instability.

```text
000
```

Curl could not complete the request, usually because of timeout, connection failure, or interruption.

### Route Counts

Example:

```text
route_counts:
  auth.login               200: 300
  auth.login               429: 120
  inventory.tickets        200: 450
  payment.list             200: 330
```

This tells you which logical part of the system is receiving errors or rate limits.

### Latency

Example:

```text
latency_ms:
  min: 32
  p50: 120
  p90: 800
  p95: 1200
  p99: 2400
  max: 4000
```

Useful interpretation:

```text
p50
```

Typical request latency.

```text
p95 / p99
```

Tail latency. These values usually grow first when the cluster is under pressure.

## Load-Balancer Distribution

The script reads this Composer metric:

```text
flashsale_composer_upstream_api_calls_total
```

Composer records which downstream pod answered each proxied request using the `X-Pod-Name` response header.

Example output:

```text
Inventory Service: total=500
  inventory-service-85d578c97c-9q79w      260 calls   52.00%
  inventory-service-85d578c97c-bqlq6      240 calls   48.00%
```

This means Kubernetes Service load balancing is distributing Composer traffic across both Inventory replicas.

A perfectly even split is not guaranteed, especially for short tests. For longer tests, two replicas should normally move closer to a balanced percentage.

## Prometheus Queries

Open Prometheus:

```text
http://grupo2-egs.deti.ua.pt/prometheus
```

### Calls Per Replica

```promql
sum by (service, upstream_pod) (
  increase(flashsale_composer_upstream_api_calls_total[5m])
)
```

### Percentage Per Replica

```promql
100 *
sum by (service, upstream_pod) (
  increase(flashsale_composer_upstream_api_calls_total[5m])
)
/
on(service) group_left
sum by (service) (
  increase(flashsale_composer_upstream_api_calls_total[5m])
)
```

### Status Class By Service

```promql
sum by (service, status_class) (
  increase(flashsale_composer_upstream_api_calls_total[5m])
)
```

This helps show whether high load is producing `2xx`, `4xx`, or `5xx` downstream responses.

## Grafana

Open Grafana:

```text
http://grupo2-egs.deti.ua.pt/grafana
```

Login:

```text
admin / admin
```

Use the existing FlashSale dashboard for the general KPIs. For ad-hoc load-balancer analysis, create a panel using the PromQL queries above.

Recommended panel types:

```text
Calls Per Replica
```

Use a time series or bar chart with:

```promql
sum by (service, upstream_pod) (
  increase(flashsale_composer_upstream_api_calls_total[5m])
)
```

```text
Replica Percentage
```

Use a bar gauge with:

```promql
100 *
sum by (service, upstream_pod) (
  increase(flashsale_composer_upstream_api_calls_total[5m])
)
/
on(service) group_left
sum by (service) (
  increase(flashsale_composer_upstream_api_calls_total[5m])
)
```

```text
Rate Limits / Errors
```

Use a time series with:

```promql
sum by (service, status_class) (
  increase(flashsale_composer_upstream_api_calls_total[5m])
)
```

## Output Files

Each run saves raw files in:

```text
/tmp/egs-load-test-YYYYMMDDHHMMSS
```

Important files:

```text
requests.tsv
```

Every request made by the script:

```text
route    status    latency_ms
```

```text
metrics-before.prom
```

Composer metrics before the load phase.

```text
metrics-after.prom
```

Composer metrics after the load phase.

```text
prometheus-upstream.json
```

Raw Prometheus API response for the load-balancing query.

To keep output in a specific folder:

```bash
k8s/scripts/load-test.sh --output-dir /tmp/my-load-test
```

## Suggested Test Progression

Start small:

```bash
k8s/scripts/load-test.sh --duration 10 --concurrency 5 --login-concurrency 2 --payment-concurrency 2
```

Then moderate:

```bash
k8s/scripts/load-test.sh --duration 60 --concurrency 30 --login-concurrency 10 --payment-concurrency 10
```

Then aggressive:

```bash
k8s/scripts/load-test.sh --duration 120 --concurrency 80 --login-concurrency 30 --payment-concurrency 30
```

Watch for:

```text
429
```

Rate limits are working.

```text
p95 / p99 latency increasing
```

Services are getting slower under pressure.

```text
Replica percentages
```

Traffic should be spread across replicas for services with multiple pods.

```text
5xx or 000 increasing heavily
```

The system is overloaded or an internal service is failing under pressure.

## Notes

This is not a full benchmarking tool like k6, Locust, or JMeter. It is a practical cluster demonstration script for:

```text
rate limits
replica traffic distribution
basic latency behavior
service resilience under concurrent traffic
```

For formal performance testing, use a dedicated load-testing tool and define fixed scenarios, thresholds, and reports.
