#!/bin/sh
# Build the mongosync config from the environment (manual URIs, or discovered
# in-cluster via the ServiceAccount) and exec mongosync.
set -eu
CONF=/etc/mongosync/conf.json
mkdir -p /etc/mongosync

SA_DIR=/var/run/secrets/kubernetes.io/serviceaccount
if [ -n "${KUBERNETES_SERVICE_HOST:-}" ] && [ -d "$SA_DIR" ] && [ -z "${KUBECONFIG:-}" ]; then
  KUBECONFIG=/tmp/.kube/config
  export KUBECONFIG
  mkdir -p /tmp/.kube
  kubectl config set-cluster in-cluster \
    --server="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS:-443}" \
    --certificate-authority="$SA_DIR/ca.crt" >/dev/null
  kubectl config set-credentials sa --token="$(cat "$SA_DIR/token")" >/dev/null
  kubectl config set-context in-cluster --cluster=in-cluster --user=sa >/dev/null
  kubectl config use-context in-cluster >/dev/null
fi

export KBMS_API_URL="http://127.0.0.1:${KBMS_PORT:-27180}"
kb-mongosync render-conf > "$CONF"
exec mongosync --config "$CONF" --acceptDisclaimer
