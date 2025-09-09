#!/usr/bin/env bash
set -euo pipefail

CLUSTER="${CLUSTER:-shopup}"
NS="${NS:-shopup-dev}"
CHART="${CHART:-deploy/charts/shopup}"
USE_LOCAL="${USE_LOCAL:-0}"  # 0=GHCR, 1=local
GHCR_REPO="${GHCR_REPO:-ghcr.io/nullneo/shopup-api}"
GHCR_TAG="${GHCR_TAG:-}"     # обязателен, если USE_LOCAL=0
PIN_BY_DIGEST="${PIN_BY_DIGEST:-0}"
LOCAL_IMAGE="${LOCAL_IMAGE:-shopup-api}"
LOCAL_TAG="${LOCAL_TAG:-dev}"
HOST="${HOST:-api.shopup.localhost}"

log(){ echo -e "\033[1;36m[shopup]\033[0m $*"; }

# Docker/k3d + Zscaler CA
open -ga Docker || true
k3d cluster start "$CLUSTER" 2>/dev/null || k3d cluster create "$CLUSTER" \
  --agents 2 \
  -p "80:80@loadbalancer" -p "443:443@loadbalancer" \
  --registry-config ./registries.yaml \
  --volume "$PWD/zscaler_root.crt:/etc/ssl/certs/zscaler_root.crt@all"

kubectl config use-context "k3d-$CLUSTER" >/dev/null
kubectl get ns cert-manager >/dev/null 2>&1 || kubectl create ns cert-manager
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

# cert-manager: CRDs -> чарт
if ! kubectl get crd certificaterequests.cert-manager.io >/dev/null 2>&1; then
  log "Apply cert-manager CRDs"
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.crds.yaml
fi
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade -i cert-manager jetstack/cert-manager -n cert-manager

# TLS (Issuer/Certificate) из infra/
kubectl apply -f infra/cluster-ca.yaml
kubectl -n "$NS" apply -f infra/api-cert.yaml

# Helm deps
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm dependency update "$CHART" >/dev/null

# Образ
if [ "$PIN_BY_DIGEST" = "1" ]; then
  : "${GHCR_TAG:?Set GHCR_TAG=<commit-sha> (to resolve digest)}"
  docker manifest inspect "$GHCR_REPO:$GHCR_TAG" >/dev/null 2>&1 \
    || { echo "❌ tag $GHCR_REPO:$GHCR_TAG not found in registry"; exit 1; }
  if [ -z "${DIGEST:-}" ]; then
    if command -v jq >/dev/null 2>&1; then
      DIGEST=$(docker manifest inspect "$GHCR_REPO:$GHCR_TAG" \
        | jq -r '.manifests[] | select(.platform.os=="linux" and .platform.architecture=="amd64") | .digest' \
        | head -1)
    else
      DIGEST=$(docker manifest inspect "$GHCR_REPO:$GHCR_TAG" \
        | grep -m1 -o 'sha256:[0-9a-f]\{64\}')
    fi
  fi
  [ -n "$DIGEST" ] || { echo "❌ cannot resolve digest"; exit 1; }
  EXTRA="--set api.image.repository=$GHCR_REPO --set api.image.tag= --set-string api.image.digest=$DIGEST"
fi

# Деплой
log "Deploy umbrella"
helm upgrade -i shopup "$CHART" -n "$NS" \
  -f "$CHART/values.yaml" \
  -f <(sops -d deploy/environments/dev/values.secrets.enc.yaml) \
  $EXTRA \
  --wait --atomic --timeout 5m

# Проверки
kubectl -n "$NS" rollout status deploy/shopup-api
log "Smoke:"
curl -ks "https://$HOST/healthz" && echo
curl -ks "https://$HOST/healthz/db" && echo
