# FlashSale Kubernetes Deployment

This directory contains the Kubernetes deployment for the FlashSale microservice
project. It deploys the full application stack into the namespace
`tenant-grupo2-egs-deti-ua-pt` using Kustomize.

The goal of this deployment is to run every service inside the cluster, keep
inter-service traffic private, expose only the public HTTP entrypoints through
Traefik Ingress, persist data for stateful components, and provide observability
for the whole platform.

## High-Level Decisions

### Kustomize As The Deployment Entry Point

The cluster is deployed with:

```bash
kubectl apply -k k8s
```

Kustomize is used because it lets the deployment keep a clean split between:

- base manifests: `00-secrets.yaml` to `05-ingress.yaml`
- generated ConfigMaps from local files, such as Grafana dashboards and
  Prometheus configuration
- image name/tag replacement in `kustomization.yaml`
- namespace injection for every object

All manifests are applied to:

```yaml
namespace: tenant-grupo2-egs-deti-ua-pt
```

### Separate Auth Instances For Composer And Payment

Two Auth service instances are deployed from the same Auth image:

- `auth-service`
- `auth-postgres`
- `auth-redis`
- `auth-frontend`
- `payment-auth-service`
- `payment-auth-postgres`
- `payment-auth-redis`

Composer uses `auth-service`. Payment uses its own `payment-auth-service`.
This keeps the Payment wallet identity store and token issuer separate from the
main Composer identity store, while still reusing the same Auth application
code. The two instances use different Postgres/Redis state and different token
secret keys.

### Private Services, Public Ingress

All Kubernetes `Service` objects are `ClusterIP`.

There is no `NodePort` service in this deployment. Public access is handled by
the cluster ingress controller, Traefik, through one `Ingress` object:

```yaml
kind: Ingress
metadata:
  name: egs-hosts
spec:
  ingressClassName: traefik
```

The cluster has a single public entry IP. The DNS-style names are mapped to that
IP locally using `/etc/hosts`, or by real DNS if available.

## File Layout

```text
k8s/
├── 00-secrets.yaml
├── 01-config.yaml
├── 02-data.yaml
├── 03-apps.yaml
├── 04-observability.yaml
├── 05-ingress.yaml
├── kustomization.yaml
├── config/
│   ├── auth-frontend/
│   ├── observability/
│   └── vault/
└── scripts/
    ├── build-and-push.sh
    ├── smoke-test.sh
    └── update-hosts.sh
```

## Resources Created

### Secrets

File: `00-secrets.yaml`

Object:

- `Secret/egs-secrets`

This stores values that should not live in a normal ConfigMap:

- JWT signing keys for Composer Auth and Payment Auth
- internal service key shared by trusted services
- Inventory API key
- Payment admin/API key
- database usernames/passwords/URLs
- Stripe placeholder secrets
- Grafana admin credentials
- Vault dev token

The services consume these values through `env.valueFrom.secretKeyRef`.

Note: this deployment also runs Vault, but the apps currently get their runtime
secrets from Kubernetes Secrets. Vault is initialized with the same dev secrets
for visibility/testing, but it is not the runtime source of truth unless a Vault
operator or application-side Vault client is added.

### ConfigMap

File: `01-config.yaml`

Object:

- `ConfigMap/egs-config`

This stores non-secret configuration:

- public URLs, such as `http://composer.flashsale`
- internal service URLs, such as `http://auth-service:8000`
- Payment Auth internal URL, `http://payment-auth-service:8000`
- CORS origins
- Auth cookie settings
- password reset email settings
- rate limit settings
- OpenTelemetry endpoint
- Vault address

These values are injected into pods through `env.valueFrom.configMapKeyRef`.

### Data Services

File: `02-data.yaml`

These are deployed as `StatefulSet` objects because they own persistent data and
need stable storage.

Auth data:

- `StatefulSet/auth-postgres`
- `Service/auth-postgres`
- `StatefulSet/auth-redis`
- `Service/auth-redis`

Payment Auth data:

- `StatefulSet/payment-auth-postgres`
- `Service/payment-auth-postgres`
- `StatefulSet/payment-auth-redis`
- `Service/payment-auth-redis`

Inventory data:

- `StatefulSet/inv-postgres`
- `Service/inv-postgres`
- `StatefulSet/inv-redis`
- `Service/inv-redis`

Payment data:

- `StatefulSet/pay-postgres`
- `Service/pay-postgres`
- `Service/postgres`
- `StatefulSet/pay-redis`
- `Service/pay-redis`

The extra `Service/postgres` points to `pay-postgres`. It exists because part of
the Payment service configuration/migrations expect a hostname named
`postgres`.

All Postgres and Redis StatefulSets use Longhorn PVCs:

```yaml
storageClassName: longhorn
```

Postgres PVCs are `1Gi`; Redis PVCs are `256Mi`.

`PGDATA=/var/lib/postgresql/data/pgdata` is set for Postgres containers so the
database writes inside a subdirectory of the mounted volume. This avoids common
Postgres initialization problems when the volume root contains storage-system
metadata.

### Application Services

File: `03-apps.yaml`

Composer:

- `Deployment/composer`
- `Service/composer`

Composer is the API gateway and orchestration layer. It proxies and coordinates:

- Auth
- Inventory
- Payment

It also exposes:

- the main frontend
- `/health`
- `/metrics`
- `/api/kpi/dashboard`

Auth:

- `Deployment/auth-service`
- `Service/auth-service`
- `Deployment/auth-frontend`
- `Service/auth-frontend`

`auth-service` is the Composer identity provider. `auth-frontend` is an Nginx
container that serves the static Composer auth pages for login, registration,
forgot password, and reset password.

Payment Auth:

- `Deployment/payment-auth-service`
- `Service/payment-auth-service`

`payment-auth-service` is a second instance of the same Auth application, but it
uses `payment-auth-postgres`, `payment-auth-redis`, `PAYMENT_AUTH_SECRET_KEY`,
and the public host `payment-auth.flashsale`. Payment wallet login/register
pages call this service directly.

Inventory:

- `Deployment/inventory-service`
- `Service/inventory-service`

Inventory owns events, tickets, reservations, ticket status transitions, and
inventory KPI endpoints.

Payment:

- `Deployment/payment-service`
- `Service/payment-service`

Payment owns customers, checkout sessions, payments, refunds, receipts, and the
wallet/checkout UI. It validates user Bearer tokens by calling:

```text
http://payment-auth-service:8000/api/v1/auth/verify
```

All application deployments use:

- `readinessProbe`
- `livenessProbe`
- `startupProbe` where startup can take longer
- conservative CPU/memory requests and limits

### Observability, Email, And Vault

File: `04-observability.yaml`

OpenTelemetry:

- `Deployment/otel-collector`
- `Service/otel-collector`

The OpenTelemetry Collector receives traces/metrics over OTLP and exports traces
to Jaeger and metrics to its Prometheus exporter.

Jaeger:

- `Deployment/jaeger`
- `Service/jaeger`

Jaeger provides trace inspection at `http://jaeger.flashsale`.

Prometheus:

- `StatefulSet/prometheus`
- `Service/prometheus`

Prometheus is stateful because it stores time series data. Its config is
generated from:

```text
k8s/config/observability/prometheus.yml
```

Prometheus scrapes:

- `composer:8000/metrics` for platform KPIs
- `otel-collector:8889` for OpenTelemetry-exported metrics

Composer is the main KPI aggregation point. It collects health and KPIs from
Auth, Inventory, and Payment, then exposes Prometheus-format metrics such as:

- `flashsale_service_up`
- `flashsale_auth_users_total`
- `flashsale_inventory_tickets_total`
- `flashsale_payment_payments_total`

Grafana:

- `StatefulSet/grafana`
- `Service/grafana`

Grafana is stateful because it keeps local dashboard/user state. Datasources and
dashboards are provisioned from ConfigMaps generated by Kustomize:

- `grafana-datasources`
- `grafana-dashboard-provider`
- `grafana-dashboards`

The platform dashboard is:

```text
FlashSale Platform KPIs
http://grafana.flashsale/d/flashsale-platform-kpis/flashsale-platform-kpis
```

MailHog:

- `Deployment/mailhog`
- `Service/mailhog`

MailHog is used as a cluster-local SMTP catcher for forgot-password emails.
Auth sends email to:

```text
mailhog:1025
```

The MailHog UI/API is exposed at:

```text
http://mail.flashsale
```

This was chosen because the project needs password-reset email to work without
requiring real external SMTP credentials.

Vault:

- `StatefulSet/vault`
- `Service/vault`
- `Job/vault-init`

Vault runs in dev mode:

```text
vault server -dev
```

The `vault-init` Job writes dev secrets into paths such as:

- `secret/auth`
- `secret/payment-auth`
- `secret/inventory`
- `secret/payment`
- `secret/composer`

This is useful for demonstration and inspection, but not production-grade Vault
usage. Runtime pods still read their secret values from `Secret/egs-secrets`.

## Generated ConfigMaps

File: `kustomization.yaml`

Kustomize generates ConfigMaps from local config files:

- `auth-frontend-templates`
- `auth-frontend-static-css`
- `otel-collector-config`
- `prometheus-config`
- `grafana-datasources`
- `grafana-dashboard-provider`
- `grafana-dashboards`
- `vault-init-script`

`generatorOptions.disableNameSuffixHash: true` is enabled so mounted ConfigMap
names are stable and easier to reference in manifests. Because of that, pods
that mount changed ConfigMaps may need a restart to pick up updates.

## Image Management

The app image names in manifests are logical placeholders:

- `egs-composer`
- `egs-auth-service`
- `egs-inventory-service`
- `egs-payment-service`

Kustomize replaces them with Docker Hub images:

```yaml
images:
  - name: egs-composer
    newName: bmarujo/egs-composer
    newTag: k8s-20260510215836
```

Build and push a new tag with:

```bash
k8s/scripts/build-and-push.sh <tag>
```

Then update `k8s/kustomization.yaml` with that tag and apply again.

## External Exposure

File: `05-ingress.yaml`

External HTTP access is provided by Traefik Ingress.

The Kubernetes services themselves are private `ClusterIP` services. Traefik is
the component that receives traffic from outside the cluster and routes it to
the correct internal service by `Host` header.

Ingress hosts:

| Host | Internal backend | Purpose |
| --- | --- | --- |
| `composer.flashsale` | `composer:8000` | Main app and Composer API |
| `grupo2-egs.deti.ua.pt` | `composer:8000` | Public cluster DNS entry |
| `auth.flashsale` | `auth-service:8000` and `auth-frontend:80` | Auth API and static Auth pages |
| `payment-auth.flashsale` | `payment-auth-service:8000` | Payment wallet Auth API |
| `inventory.flashsale` | `inventory-service:8000` | Inventory API |
| `payment.flashsale` | `payment-service:8000` | Payment API, wallet, checkout UI |
| `grafana.flashsale` | `grafana:3000` | Grafana UI |
| `jaeger.flashsale` | `jaeger:16686` | Jaeger UI |
| `prometheus.flashsale` | `prometheus:9090` | Prometheus UI/API |
| `vault.flashsale` | `vault:8200` | Vault UI/API |
| `mail.flashsale` | `mailhog:8025` | MailHog UI/API |

For `auth.flashsale`, path-based routing is used:

- `/templates` -> `auth-frontend`
- `/static` -> `auth-frontend`
- `/` -> `auth-service`

Everything else is host-based routing.

## Local DNS

The cluster is reached through one public IP. To use the local hostnames from a
browser or curl, add them to `/etc/hosts`.

Use:

```bash
sudo k8s/scripts/update-hosts.sh 193.136.82.35
```

This maps:

- `grupo2-egs.deti.ua.pt`
- `composer.flashsale`
- `auth.flashsale`
- `payment-auth.flashsale`
- `inventory.flashsale`
- `payment.flashsale`
- `grafana.flashsale`
- `jaeger.flashsale`
- `prometheus.flashsale`
- `vault.flashsale`
- `mail.flashsale`

to the cluster public IP.

If real DNS records exist for these hosts, the `/etc/hosts` step is not needed.

## Important URLs

Main app:

```text
http://composer.flashsale
```

Composer API docs:

```text
http://composer.flashsale/docs
```

Payment wallet:

```text
http://payment.flashsale/wallet/login
```

Payment Auth API:

```text
http://payment-auth.flashsale
```

Grafana:

```text
http://grafana.flashsale
```

Default credentials:

```text
admin / admin
```

Platform KPI dashboard:

```text
http://grafana.flashsale/d/flashsale-platform-kpis/flashsale-platform-kpis
```

Prometheus:

```text
http://prometheus.flashsale
```

Jaeger:

```text
http://jaeger.flashsale
```

Vault:

```text
http://vault.flashsale
```

MailHog:

```text
http://mail.flashsale
```

## Deploy

Apply everything:

```bash
kubectl apply -k k8s
```

Wait for core workloads:

```bash
kubectl rollout status deploy/composer
kubectl rollout status deploy/auth-service
kubectl rollout status deploy/payment-auth-service
kubectl rollout status deploy/inventory-service
kubectl rollout status deploy/payment-service
kubectl rollout status deploy/mailhog
kubectl rollout status statefulset/payment-auth-postgres
kubectl rollout status statefulset/payment-auth-redis
kubectl rollout status statefulset/prometheus
kubectl rollout status statefulset/grafana
```

Inspect:

```bash
kubectl get pods,svc,ingress,pvc
```

## Test

Run the smoke test:

```bash
k8s/scripts/smoke-test.sh 193.136.82.35
```

The smoke test verifies:

- Composer health
- registering and logging in through the Composer Auth service
- registering and logging in through Payment Auth for hosted checkout
- forgot-password email delivery into MailHog
- KPI dashboard JSON
- event and ticket creation through Composer -> Inventory
- payment account setup through Composer -> Payment
- checkout creation and authorization
- Composer `/metrics`
- Prometheus samples
- Grafana dashboard provisioning
- Grafana, Jaeger, and MailHog ingress access

Useful direct checks:

```bash
curl http://composer.flashsale/health | python3 -m json.tool
curl http://composer.flashsale/metrics | grep flashsale_
curl --get http://prometheus.flashsale/api/v1/query \
  --data-urlencode 'query=flashsale_service_up'
curl -u admin:admin \
  http://grafana.flashsale/api/dashboards/uid/flashsale-platform-kpis
curl http://mail.flashsale/api/v2/messages | python3 -m json.tool
```

## Operational Notes

### Restart After ConfigMap Changes

Because ConfigMap name hashing is disabled, a changed mounted file may require a
pod restart. Common examples:

```bash
kubectl rollout restart statefulset/prometheus
kubectl rollout restart statefulset/grafana
kubectl rollout restart deploy/auth-service
kubectl rollout restart deploy/payment-auth-service
kubectl rollout restart deploy/composer
```

### Payment Auth PVCs

`payment-auth-postgres` and `payment-auth-redis` use their own Longhorn PVCs.
Those volumes are intentionally separate from the Composer Auth volumes, because
Payment Auth owns its own users, sessions, and token state.

### Security Caveats

This deployment is suitable for coursework/demo use, not production as-is.
Before production:

- replace all placeholder secrets
- do not use Vault dev mode
- use real DNS/TLS
- use a real SMTP provider instead of MailHog
- restrict public access to Prometheus, Vault, and possibly MailHog
- avoid default Grafana credentials
- consider a Vault or External Secrets operator if Vault should be the secret
  source of truth
