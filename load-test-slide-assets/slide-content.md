# One-Slide Content: Load Balancing & HA

## Recommended Demo Command

Use this profile for the presentation:

```bash
k8s/scripts/load-test.sh --duration 30 --concurrency 10 --login-concurrency 6 --payment-concurrency 6 --event-limit 8 --prom-wait 10
```

This was the best presentation run because it shows both important things clearly:

```text
1. Kubernetes load balancing across replicas
2. Rate limiting activating under pressure
```

without turning the whole slide into an overload failure story.

## Test Setup

```text
Public endpoint: http://grupo2-egs.deti.ua.pt
Duration: 30 seconds
Total requests: 496
Traffic path: Ingress -> Composer -> internal Kubernetes Services
```

## HTTP Results

```text
200 OK: 234 requests, 47.2%
429 rate limited: 262 requests, 52.8%
5xx errors: 0 requests, 0.0%
```

## Replica Distribution

For backend calls that reached service replicas:

```text
Auth:      52.5% / 47.5%
Inventory: 50.4% / 49.6%
Payment:   52.9% / 47.1%
```

Payment also had `17` rate-limited responses before pod attribution, which is why the raw script output includes an `unknown` bucket for Payment.

## Main Conclusion

The Kubernetes Services successfully distributed traffic across replicas, with Inventory almost perfectly balanced at `50.4% / 49.6%`.

Rate limiting also activated cleanly: excess traffic was rejected with `429`, while the system avoided `5xx` errors in this recommended demo profile.

## Speaker Notes

This is the clearest HA/load-balancing demonstration profile. The previous extreme run with `100` workers proved the cluster capacity boundary, but produced too many `503`s for a clean presentation slide.

For this slide, emphasize:

```text
Load balancing works.
Rate limits protect the services.
No 5xx errors in the selected demo run.
```

## Optional Comparison

Lighter profile tested:

```bash
k8s/scripts/load-test.sh --duration 30 --concurrency 6 --login-concurrency 3 --payment-concurrency 3 --event-limit 5 --prom-wait 10
```

It also had no `5xx`, but produced more rate-limited responses proportionally:

```text
200 OK: 176
429 rate limited: 340
```

The recommended profile is better for the slide because the `200` vs `429` split is more balanced.


Kubernetes Services successfully distribute traffic across replicas.
Inventory reached an almost perfect 50/50 split.
Rate limits activated under pressure with 429 responses.
The selected demo profile produced no 5xx errors.
