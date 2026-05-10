#!/usr/bin/env bash
set -euo pipefail

EDGE_IP="${1:-193.136.82.35}"
MARKER="# egs-k8s"
HOSTS=(
  grupo2-egs.deti.ua.pt
  composer.flashsale
  auth.flashsale
  payment-auth.flashsale
  inventory.flashsale
  payment.flashsale
  grafana.flashsale
  jaeger.flashsale
  prometheus.flashsale
  vault.flashsale
)

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

sudo cp /etc/hosts "/etc/hosts.backup.$(date +%Y%m%d%H%M%S)"
grep -vF "$MARKER" /etc/hosts > "$tmp_file"
printf "%s %s %s\n" "$EDGE_IP" "${HOSTS[*]}" "$MARKER" >> "$tmp_file"
sudo cp "$tmp_file" /etc/hosts

echo "Mapped ${HOSTS[*]} to $EDGE_IP"
