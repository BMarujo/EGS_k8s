#!/usr/bin/env sh
# ──────────────────────────────────────────────────────────────
# Vault init script — populates dev-mode Vault with all secrets
# Runs once at compose-up via the vault-init service.
# ──────────────────────────────────────────────────────────────
set -e

export VAULT_ADDR="http://vault:8200"
export VAULT_TOKEN="${VAULT_DEV_ROOT_TOKEN_ID:-dev-root-token}"

echo "⏳ Waiting for Vault to be ready..."
until vault status >/dev/null 2>&1; do
  sleep 1
done
echo "✅ Vault is ready"

# ── Enable KV v2 secrets engine (already enabled in dev mode at secret/) ──

# ── Auth Service secrets ──────────────────────────────────────
vault kv put secret/auth \
  database_url="postgresql://user:password@auth-postgres:5432/auth_db" \
  redis_url="redis://auth-redis:6379/0" \
  secret_key="super-secret-jwt-key-for-dev-2024" \
  internal_service_key="${INTERNAL_SERVICE_KEY:-internal-dev-key-2024}"

echo "✅ Auth secrets written"

# ── Inventory Service secrets ─────────────────────────────────
vault kv put secret/inventory \
  database_url="postgresql+asyncpg://inventory_user:inventory_pass@inv-postgres:5432/inventory_db_fresh" \
  redis_url="redis://inv-redis:6379/0" \
  api_key="sk_test_inventory_dev_key"

echo "✅ Inventory secrets written"

# ── Payment Service secrets ───────────────────────────────────
vault kv put secret/payment \
  database_url="postgresql+asyncpg://payment_user:payment_pass@pay-postgres:5432/payment_db" \
  redis_url="redis://pay-redis:6379/0" \
  admin_api_key="${PAYMENT_ADMIN_API_KEY:-admin-dev-key-2024}" \
  stripe_secret_key="${STRIPE_SECRET_KEY:-sk_test_placeholder}" \
  stripe_webhook_secret="${STRIPE_WEBHOOK_SECRET:-whsec_placeholder}" \
  internal_service_key="${INTERNAL_SERVICE_KEY:-internal-dev-key-2024}"

echo "✅ Payment secrets written"

# ── Composer secrets ──────────────────────────────────────────
vault kv put secret/composer \
  inventory_api_key="sk_test_inventory_dev_key" \
  payment_api_key="${PAYMENT_API_KEY:-admin-dev-key-2024}" \
  internal_service_key="${INTERNAL_SERVICE_KEY:-internal-dev-key-2024}"

echo "✅ Composer secrets written"

echo "🎉 All secrets populated in Vault"
