#!/usr/bin/env bash
set -euo pipefail

# ---------- Параметры ----------
CLUSTER="${CLUSTER:-shopup}"
NS="${NS:-shopup-dev}"

CHART="${CHART:-deploy/charts/shopup}"

# Откуда берём образ приложения
USE_LOCAL="${USE_LOCAL:-0}"          # 0 = из GHCR, 1 = локальный образ
GHCR_REPO="${GHCR_REPO:-ghcr.io/nullneo/shopup-api}"
GHCR_TAG="${GHCR_TAG:-}"             # обязателен, если USE_LOCAL=0 и PIN_BY_DIGEST=0
PIN_BY_DIGEST="${PIN_BY_DIGEST:-0}"  # 1 = закрепить digest вместо tag
LOCAL_IMAGE="${LOCAL_IMAGE:-shopup-api}"
LOCAL_TAG="${LOCAL_TAG:-dev}"

# Хост для smoke-теста
HOST="${HOST:-api.shopup.localhost}"

# Мониторинг
MON_NS="${MON_NS:-monitoring}"
INSTALL_MONITORING="${INSTALL_MONITORING:-1}"   # 1 = ставить/обновлять Loki/Promtail/kps
LOKI_VALUES="${LOKI_VALUES:-ops/monitoring/loki-values.yaml}"
KPS_VALUES="${KPS_VALUES:-ops/monitoring/kps-values.yaml}"

log(){ echo -e "\033[1;36m[shopup]\033[0m $*"; }

ensure_ns() {
  local ns="$1"
  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns"
}

# ---------- Docker/k3d + Zscaler CA ----------
open -ga Docker 2>/dev/null || true
k3d cluster start "$CLUSTER" 2>/dev/null || k3d cluster create "$CLUSTER" \
  --agents 2 \
  -p "80:80@loadbalancer" -p "443:443@loadbalancer" \
  --registry-config ./registries.yaml \
  --volume "$PWD/zscaler_root.crt:/etc/ssl/certs/zscaler_root.crt@all"

kubectl config use-context "k3d-$CLUSTER" >/dev/null

# ---------- Namespaces ----------
ensure_ns cert-manager
ensure_ns "$NS"
ensure_ns "$MON_NS"

# ---------- Monitoring (Loki + Promtail + kube-prometheus-stack) ----------
if [[ "$INSTALL_MONITORING" = "1" ]]; then
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null

  # Loki (single-binary по значениям из файла)
  helm upgrade -i loki grafana/loki -n "$MON_NS" \
    -f "$LOKI_VALUES" \
    --wait --timeout 5m
  kubectl -n "$MON_NS" wait --for=condition=Ready pod -l app.kubernetes.io/name=loki --timeout=180s

  # Promtail (дефолтного конфига хватает; он уже пушит в loki.cluster.svc:3100)
  helm upgrade -i promtail grafana/promtail -n "$MON_NS" \
    --wait --timeout 5m
  kubectl -n "$MON_NS" rollout status ds/promtail --timeout=180s

  # kube-prometheus-stack (Grafana/Prometheus/Alertmanager)
  if [[ -f "$KPS_VALUES" ]]; then
    helm upgrade -i kps prometheus-community/kube-prometheus-stack -n "$MON_NS" \
      -f "$KPS_VALUES" \
      --wait --timeout 10m
  else
    helm upgrade -i kps prometheus-community/kube-prometheus-stack -n "$MON_NS" \
      --wait --timeout 10m
  fi
  kubectl -n "$MON_NS" rollout status deploy/kps-grafana --timeout=300s

  # Быстрая проверка Loki /ready через pf
  (
    kubectl -n "$MON_NS" port-forward svc/loki 3100:3100 >/dev/null 2>&1 &
    PF=$!
    sleep 1
    if curl -sf http://127.0.0.1:3100/ready >/dev/null; then
      log "Loki is ready"
    else
      log "WARN: Loki /ready is not answering (но pod в Ready)."
    fi
    kill $PF >/dev/null 2>&1 || true
    wait $PF 2>/dev/null || true
  )
fi

# ---------- cert-manager: CRDs -> chart ----------
if ! kubectl get crd certificaterequests.cert-manager.io >/dev/null 2>&1; then
  log "Apply cert-manager CRDs"
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.crds.yaml
fi

helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade -i cert-manager jetstack/cert-manager -n cert-manager --wait --timeout 5m

# ---------- TLS из infra/ ----------
kubectl apply -f infra/cluster-ca.yaml
kubectl -n "$NS" apply -f infra/api-cert.yaml

# ---------- Helm deps для приложения ----------
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm dependency update "$CHART" >/dev/null

# ---------- Образ приложения (надёжное прокидывание) ----------
HELM_OVERRIDES=()

if [[ "$USE_LOCAL" = "1" ]]; then
  # Локальный образ
  HELM_OVERRIDES+=(--set "api.image.repository=${LOCAL_IMAGE}")
  HELM_OVERRIDES+=(--set "api.image.tag=${LOCAL_TAG}")
  HELM_OVERRIDES+=(--set-string "api.image.digest=")
else
  # Образ из GHCR
  if [[ "$PIN_BY_DIGEST" = "1" ]]; then
    : "${GHCR_TAG:?Set GHCR_TAG=<tag> to resolve digest}"
    docker manifest inspect "$GHCR_REPO:$GHCR_TAG" >/dev/null 2>&1 || {
      echo "❌ tag $GHCR_REPO:$GHCR_TAG not found in registry"; exit 1; }
    DIGEST="${DIGEST:-$(docker manifest inspect "$GHCR_REPO:$GHCR_TAG" \
      | grep -m1 -o 'sha256:[0-9a-f]\{64\}')}"
    [[ -n "$DIGEST" ]] || { echo "❌ cannot resolve digest"; exit 1; }

    HELM_OVERRIDES+=(--set "api.image.repository=${GHCR_REPO}")
    HELM_OVERRIDES+=(--set "api.image.tag=")
    HELM_OVERRIDES+=(--set-string "api.image.digest=${DIGEST}")
  else
    : "${GHCR_TAG:?Set GHCR_TAG=<tag> (PIN_BY_DIGEST=0)}"
    HELM_OVERRIDES+=(--set "api.image.repository=${GHCR_REPO}")
    HELM_OVERRIDES+=(--set "api.image.tag=${GHCR_TAG}")
    HELM_OVERRIDES+=(--set-string "api.image.digest=")
  fi
fi

# ---------- Деплой приложения ----------
log "Deploy umbrella"
helm upgrade -i shopup "$CHART" -n "$NS" \
  -f "$CHART/values.yaml" \
  -f <(sops -d deploy/environments/dev/values.secrets.enc.yaml) \
  "${HELM_OVERRIDES[@]}" \
  --wait --atomic --timeout 5m

# ---------- Проверки / Smoke ----------
kubectl -n "$NS" rollout status deploy/shopup-api --timeout=300s || true

log "Smoke:"
# HTTPs путь — у тебя cert-manager + локальный CA; для простоты без -k тоже может сработать,
# но оставим -k, чтобы не ломаться, если корень не доверен в системе.
curl -ks "https://$HOST/healthz" && echo || true
curl -ks "https://$HOST/healthz/db" && echo || true

if [[ "$INSTALL_MONITORING" = "1" ]]; then
  log "Grafana: http://localhost:3000 (admin / см. секрет)"
  echo "Пароль: $(kubectl -n "$MON_NS" get secret kps-grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)"
fi
