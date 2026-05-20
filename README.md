# FlashSale Kubernetes Deployment

This directory is the deployment entry point for the FlashSale microservice
stack in the `tenant-grupo2-egs-deti-ua-pt` namespace.

Apply it with:

```bash
kubectl apply -k k8s
```

## Public Routing

The cluster uses one public host:

```text
http://grupo2-egs.deti.ua.pt
```

All Kubernetes services are private `ClusterIP` services. There are no NodePort
services in this deployment. External traffic enters through Traefik Ingress and
is routed by path:

| Public path | Backend service | Purpose |
| --- | --- | --- |
| `/` | `composer:8000` | Main Composer frontend and Composer API |
| `/auth/templates` | `auth-frontend:80` | Composer Auth static pages |
| `/auth/static` | `auth-frontend:80` | Composer Auth static assets |
| `/auth` | `auth-service:8000` | Composer Auth API |
| `/payment-auth` | `payment-auth-service:8000` | Payment wallet Auth API |
| `/inventory` | `inventory-service:8000` | Inventory API |
| `/payment` | `payment-service:8000` | Payment API, wallet UI, checkout UI |
| `/grafana` | `grafana:3000` | Grafana UI |
| `/prometheus` | `prometheus:9090` | Prometheus UI/API |
| `/jaeger` | `jaeger:16686` | Jaeger UI |
| `/mail` | `mailhog:8025` | MailHog UI/API |

Only this host should be needed in `/etc/hosts`:

```bash
k8s/scripts/update-hosts.sh 193.136.82.35
```

## Internal Service Calls

Inside the cluster, services call each other through Kubernetes DNS:

| Caller | Internal target |
| --- | --- |
| Composer -> Auth | `http://auth-service:8000` |
| Composer -> Inventory | `http://inventory-service:8000` |
| Composer -> Payment | `http://payment-service:8000` |
| Payment -> Payment Auth | `http://payment-auth-service:8000` |
| Apps -> Vault | `http://vault:8200` |
| Apps -> OTEL collector | `http://otel-collector:4317` |

The public paths are for browsers and external tests. Service-to-service traffic
does not go through the public DNS name.

## Static Pages

There are two different static-page deployment patterns because the upstream
projects are structured differently.

### Composer Auth Pages

The Composer Auth service repository does not package the browser pages in its
API image. To keep the Auth API image simple, Kubernetes runs a small
`nginx:1.27-alpine` deployment named `auth-frontend`.

The files live in:

```text
k8s/config/auth-frontend/templates/
k8s/config/auth-frontend/static/css/
```

Kustomize turns those files into ConfigMaps:

- `auth-frontend-templates`
- `auth-frontend-static-css`

The Nginx pod mounts them at both:

- `/usr/share/nginx/html/templates`
- `/usr/share/nginx/html/auth/templates`
- `/usr/share/nginx/html/static/css`
- `/usr/share/nginx/html/auth/static/css`

That lets the same pages work under the current public path
`/auth/templates/...` and keeps compatibility with older `/templates/...` paths.
Composer also redirects stale `/templates/...` requests to `/auth/templates/...`.

### Payment Pages

Payment already serves its wallet and checkout pages from its own FastAPI image:

```text
Payment_service/app/static/
```

Those pages are baked into `bmarujo/egs-payment-service` and served by the
payment app at:

- `/payment/wallet/login`
- `/payment/wallet/register`
- `/payment/wallet/dashboard`
- `/payment/checkout/{session_id}`

There is no separate Nginx or ConfigMap for Payment pages because the Payment
app already owns and serves them.

## Workloads

Stateless app deployments:

- `composer`: 1 replica
- `auth-service`: 2 replicas
- `auth-frontend`: 2 replicas
- `payment-auth-service`: 2 replicas
- `inventory-service`: 2 replicas
- `payment-service`: 2 replicas

Composer intentionally stays at 1 replica because its browser login handoff
cache is currently in memory. Scaling Composer safely would require moving that
handoff state to Redis or another shared store.

Stateful workloads stay at 1 replica:

- Auth, Payment Auth, Inventory, and Payment Postgres
- Auth, Payment Auth, Inventory, and Payment Redis
- Prometheus
- Grafana
- Vault

These use StatefulSets and persistent volumes where appropriate. They should not
be scaled like stateless deployments without adding the matching clustering or
replication configuration.

## Secrets And Vault

Runtime secrets are stored in `Secret/egs-secrets` and injected into pods with
`secretKeyRef`.

Vault is also deployed and initialized by `vault-init`, but it is used as a
demonstration/inspection service in this setup. Runtime pods are not reading
their secrets from Vault directly. Moving runtime secret loading to Vault would
require a Vault agent, External Secrets operator, or application-side Vault
client integration.

Vault is intentionally not exposed through public Ingress now. It is reachable
inside the cluster as:

```text
http://vault:8200
```

## Observability

Prometheus scrapes Composer at `composer:8000/metrics`. Composer aggregates KPI
data from Auth, Inventory, and Payment and exposes it as Prometheus metrics.

Grafana is provisioned with:

- datasource: `http://prometheus:9090/prometheus`
- dashboard: `FlashSale Platform KPIs`

Replica traffic distribution is exposed through:

```promql
sum by (service, upstream_pod) (
  flashsale_composer_upstream_api_calls_total{upstream_pod!="unknown"}
)
```

In Grafana, open:

```text
http://grupo2-egs.deti.ua.pt/grafana/d/flashsale-platform-kpis/flashsale-platform-kpis
```

Look for the panel named `Downstream Calls By Replica`.

## Images

Current image pins are in `k8s/kustomization.yaml`:

- `bmarujo/egs-composer`
- `bmarujo/egs-auth-service`
- `bmarujo/egs-inventory-service`
- `bmarujo/egs-payment-service`

Build all app images with:

```bash
k8s/scripts/build-and-push.sh
```

Then update the tags in `k8s/kustomization.yaml` and apply again.

## Useful URLs

```text
Main app:     http://grupo2-egs.deti.ua.pt/
Auth UI:      http://grupo2-egs.deti.ua.pt/auth/templates/login.html
Payment UI:   http://grupo2-egs.deti.ua.pt/payment/wallet/login
Grafana:      http://grupo2-egs.deti.ua.pt/grafana
Prometheus:   http://grupo2-egs.deti.ua.pt/prometheus
Jaeger:       http://grupo2-egs.deti.ua.pt/jaeger
MailHog:      http://grupo2-egs.deti.ua.pt/mail
```

Grafana credentials in this demo deployment:

```text
admin / admin
```

## Verification

Run the full smoke test:

```bash
k8s/scripts/smoke-test.sh 193.136.82.35
```

Useful direct checks:

```bash
curl http://grupo2-egs.deti.ua.pt/health | python3 -m json.tool
curl http://grupo2-egs.deti.ua.pt/api/events | python3 -m json.tool
curl http://grupo2-egs.deti.ua.pt/auth/templates/login.html
curl http://grupo2-egs.deti.ua.pt/payment/wallet/login
curl --get http://grupo2-egs.deti.ua.pt/prometheus/api/v1/query \
  --data-urlencode 'query=sum(flashsale_service_up)'
curl -u admin:admin \
  http://grupo2-egs.deti.ua.pt/grafana/api/dashboards/uid/flashsale-platform-kpis
```

If browser behavior looks stale after a frontend image update, hard-refresh the
page. Composer serves its `index.html` with `Cache-Control: no-store` to avoid
stale bundle references, but a browser tab opened before that change may still
hold the old JavaScript until refreshed.

## Tenant Permission Notes

This tenant service account cannot create RBAC objects, Traefik Middleware CRDs,
or PodDisruptionBudgets. The manifests therefore avoid those object kinds.

Path routing is done with standard Kubernetes Ingress paths plus app-level
subpath support, not Traefik rewrite middleware.
