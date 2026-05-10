#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-k8s-20260510182212}"
REGISTRY_PREFIX="${REGISTRY_PREFIX:-bmarujo}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

build_and_push() {
  local image="$1"
  local context="$2"
  docker build --network=host -t "${REGISTRY_PREFIX}/${image}:${TAG}" "${ROOT_DIR}/${context}"
  docker push "${REGISTRY_PREFIX}/${image}:${TAG}"
}

build_and_push egs-auth-service EGS/auth-service
build_and_push egs-inventory-service inventory-service-egs
build_and_push egs-payment-service Payment_service
build_and_push egs-composer composer-egs

echo "Pushed images with tag ${TAG}"
echo "Update k8s/kustomization.yaml if you use a different tag or registry prefix."
