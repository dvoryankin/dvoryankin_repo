#!/usr/bin/env bash
set -euo pipefail

NS=${NS:-cicd}
SA=${SA:-gh-actions-deployer}
SECRET=${SECRET:-gh-actions-deployer-token}

SERVER=${SERVER:-$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')}
CA=$(kubectl -n kube-system get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -w0 || kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
TOKEN=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.token}' | base64 -d)

cat > kubeconfig.ci <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA}
    server: ${SERVER}
  name: yandex
contexts:
- context:
    cluster: yandex
    user: ci
    namespace: default
  name: ci
current-context: ci
users:
- name: ci
  user:
    token: ${TOKEN}
EOF

( base64 -w0 kubeconfig.ci 2>/dev/null || base64 < kubeconfig.ci | tr -d '\n' ) > kubeconfig.ci.b64
echo "[✓] kubeconfig.ci и kubeconfig.ci.b64 готовы"
