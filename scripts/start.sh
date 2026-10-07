#!/usr/bin/env bash
# Run from Ubuntu/WSL2: bash scripts/start.sh
set -Eeuo pipefail

usage() {
  cat <<'HELP'
Usage: bash scripts/start.sh [--no-forward]

Starts the webappsec Minikube profile and deploys Elastic, Filebeat, and Keycloak.
Prompts for the Keycloak admin password only if its Secret does not exist.
By default, keeps Kibana (5601) and Keycloak (8080) port forwards running.
Ctrl+C stops these forwards; the cluster and its data keep running.
--no-forward  Deploy and wait for readiness, then exit.
HELP
}
forward=true
case "${1:-}" in
  '') ;;
  --no-forward) forward=false ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for tool in minikube kubectl docker curl base64 mktemp grep; do
  command -v "$tool" >/dev/null || {
    printf 'Missing tool: %s. Follow the WSL2 setup in START.MD.\n' "$tool" >&2
    exit 1
  }
done
docker info >/dev/null 2>&1 || {
  echo 'Docker is unavailable. Start Docker Desktop and enable Ubuntu WSL integration.' >&2
  exit 1
}

work_dir=$(mktemp -d)
forward_pids=()
cleanup() {
  local pid
  for pid in "${forward_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -f -- "$work_dir/crds.yaml" "$work_dir/operator.yaml" "$work_dir/kibana.log" "$work_dir/keycloak.log"
  rmdir -- "$work_dir" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'printf "Startup failed at line %s. See START.MD troubleshooting.\n" "$LINENO" >&2' ERR

# Every kubectl call targets this project's profile, regardless of current context.
kube() { kubectl --context=webappsec "$@"; }

echo 'Starting the webappsec Minikube profile (4 CPUs, 8 GiB RAM)...'
minikube start --profile webappsec --driver=docker --cpus=4 --memory=8192

echo 'Installing/updating ECK 3.5.0...'
curl --fail --silent --show-error --location --retry 3 \
  https://download.elastic.co/downloads/eck/3.5.0/crds.yaml -o "$work_dir/crds.yaml"
curl --fail --silent --show-error --location --retry 3 \
  https://download.elastic.co/downloads/eck/3.5.0/operator.yaml -o "$work_dir/operator.yaml"
# Server-side apply avoids the annotation-size limit on large CRDs and is repeatable.
kube apply --server-side --field-manager=webappsec-start -f "$work_dir/crds.yaml"
for crd in elasticsearches.elasticsearch.k8s.elastic.co kibanas.kibana.k8s.elastic.co \
  apmservers.apm.k8s.elastic.co beats.beat.k8s.elastic.co; do
  kube wait --for=condition=Established "crd/$crd" --timeout=120s
done
kube apply -f "$work_dir/operator.yaml"
kube -n elastic-system rollout status statefulset/elastic-operator --timeout=300s

kube apply -f "$project_dir/k8s/observability/namespace.yaml"
kube apply -f "$project_dir/k8s/keycloak/namespace.yaml"

# --ignore-not-found distinguishes a missing Secret from connection/RBAC errors.
existing_secret=$(kube -n webappsec get secret keycloak-admin --ignore-not-found -o name)
if [[ -z "$existing_secret" ]]; then
  if [[ ! -t 0 ]]; then
    echo 'First startup needs an interactive terminal to enter the Keycloak admin password.' >&2
    exit 1
  fi
  admin_password=''
  read -r -s -p 'Create Keycloak admin password: ' admin_password
  printf '\n'
  [[ -n "$admin_password" ]] || { echo 'Password must not be empty.' >&2; exit 1; }
  printf '%s' "$admin_password" | kube -n webappsec create secret generic keycloak-admin \
    --from-literal=username=admin --from-file=password=/dev/stdin
  unset admin_password
else
  echo 'Reusing the existing Keycloak admin Secret and database.'
fi

echo 'Deploying Elasticsearch, Kibana, APM, Keycloak, and Filebeat...'
kube apply -f "$project_dir/k8s/observability/stack.yaml"
kube apply -f "$project_dir/k8s/observability/keycloak-logs.yaml"
kube apply -f "$project_dir/k8s/keycloak/keycloak.yaml"

# ECK creates these workloads asynchronously; wait for creation before rollout.
ready() {
  local namespace=$1 workload=$2
  kube -n "$namespace" wait --for=create "$workload" --timeout=600s
  kube -n "$namespace" rollout status "$workload" --timeout=600s
}
# ECK controls Elasticsearch updates with OnDelete, which rollout status rejects.
kube -n observability wait --for=create pod/elastic-es-default-0 --timeout=600s
kube -n observability wait --for=condition=Ready pod/elastic-es-default-0 --timeout=600s
ready observability deployment/elastic-kb
ready observability deployment/elastic-apm-server
ready observability daemonset/keycloak-logs-beat-filebeat
ready webappsec deployment/keycloak

echo 'All workloads are ready. Kibana username: elastic; Keycloak username: admin.'
echo 'Retrieve the Kibana password in another Ubuntu terminal:'
echo "kubectl --context=webappsec -n observability get secret elastic-es-elastic-user -o jsonpath='{.data.elastic}' | base64 --decode; printf '\\n'"

if [[ "$forward" == false ]]; then
  echo 'Deployment finished. See START.MD for manual port-forward commands.'
  exit 0
fi

start_forward() {
  local namespace=$1 service=$2 ports=$3 label=$4 pid attempt
  kubectl --context=webappsec -n "$namespace" port-forward --address=127.0.0.1 "service/$service" "$ports" >"$work_dir/$label.log" 2>&1 &
  pid=$!
  forward_pids+=("$pid")
  for ((attempt=0; attempt<30; attempt++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      cat "$work_dir/$label.log" >&2
      echo "Could not start $label port forwarding. Check for an occupied local port." >&2
      return 1
    fi
    if grep -q 'Forwarding from 127.0.0.1:' "$work_dir/$label.log"; then
      return 0
    fi
    sleep 1
  done
  cat "$work_dir/$label.log" >&2
  echo "Timed out starting $label port forwarding." >&2
  return 1
}
start_forward observability elastic-kb-http 5601:5601 kibana
start_forward webappsec keycloak 8080:8080 keycloak
printf '\nKibana:  https://localhost:5601 (local self-signed certificate)\nKeycloak: http://localhost:8080/admin/\n'
echo 'Leave this terminal open. Ctrl+C stops the forwards and keeps cluster data.'
# If either connection dies, close the other instead of leaving an orphaned forward.
if wait -n "${forward_pids[@]}"; then
  echo 'A port-forward connection closed. Run the startup script again to reconnect.' >&2
else
  echo 'A port-forward connection failed. Run the startup script again to reconnect.' >&2
fi
cat "$work_dir/kibana.log" "$work_dir/keycloak.log" >&2
exit 1
