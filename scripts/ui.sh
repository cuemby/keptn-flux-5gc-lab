#!/usr/bin/env bash
# Port-forward the lab UIs to localhost. Ctrl-C stops all forwards.
#   Grafana      http://127.0.0.1:3000
#   Prometheus   http://127.0.0.1:9090
#   Alertmanager http://127.0.0.1:9093
#   Jaeger       http://127.0.0.1:16686 (only when the optional tracing part is enabled)
# For anything beyond a local lab, expose these through Gateway API with authentication,
# never through Ingress NGINX (retired).
set -euo pipefail

NS="${NS:-observability}"
pids=()

cleanup() {
  if ((${#pids[@]})); then kill "${pids[@]}" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

# forward <service> <local-port> <service-port> <label>
forward() {
  local svc=$1 local_port=$2 svc_port=$3 label=$4
  if kubectl -n "$NS" get svc "$svc" >/dev/null 2>&1; then
    kubectl -n "$NS" port-forward --address 127.0.0.1 "svc/$svc" "$local_port:$svc_port" >/dev/null &
    pids+=("$!")
    printf '%-12s http://127.0.0.1:%s\n' "$label" "$local_port"
  else
    printf '%-12s skipped (service %s/%s not found)\n' "$label" "$NS" "$svc"
  fi
}

forward kube-prometheus-stack-grafana 3000 80 Grafana
forward kube-prometheus-stack-prometheus 9090 9090 Prometheus
forward kube-prometheus-stack-alertmanager 9093 9093 Alertmanager
forward jaeger 16686 16686 Jaeger

if ((${#pids[@]} == 0)); then
  echo "nothing to forward; is the lab reconciled? (flux get kustomizations -A)" >&2
  exit 1
fi

echo
echo "Grafana login: user 'admin', password from:"
echo "  kubectl -n $NS get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo"
echo "Press Ctrl-C to stop."
wait
