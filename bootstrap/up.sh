#!/usr/bin/env bash
# Create the kind cluster, install Argo CD, and hand everything else to Git.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGOCD_VERSION="v2.13.1"

kind create cluster --config "$SCRIPT_DIR/kind-config.yaml"

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# Server-side apply: the ApplicationSet CRD is too large for client-side apply's annotation.
kubectl apply --server-side -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

kubectl -n argocd patch configmap argocd-cm --type merge --patch-file "$SCRIPT_DIR/argocd-cm-patch.yaml"
kubectl -n argocd rollout restart deployment argocd-server
kubectl -n argocd rollout status statefulset argocd-application-controller --timeout=300s

kubectl apply -f "$SCRIPT_DIR/../argocd/root.yaml"

echo
echo "Argo CD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
echo
echo "UI: kubectl -n argocd port-forward svc/argocd-server 8080:443  ->  https://localhost:8080"
echo "App: http://podinfo-dev.localtest.me  (after the services wave syncs)"
