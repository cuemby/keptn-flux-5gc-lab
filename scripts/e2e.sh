#!/usr/bin/env bash
# End-to-end test of the lab on Kind, with no GitHub token.
#
# How it differs from `make bootstrap`:
#   - Flux reconciles this working tree instead of a GitHub fork. The tree is copied into a
#     scratch Git repository, packed with `flux push artifact` and pushed to a local registry on
#     the Kind network. The generated clusters/lab/flux-system/gotk-sync.yaml declares an
#     OCIRepository "flux-system" (instead of the GitRepository that flux bootstrap creates),
#     and the sourceRefs of the Flux Kustomizations in the copy are switched to it.
#   - Scenario changes are made with the lab's own scripts (bump-release.sh and inject-fault.sh
#     with NO_PUSH=1) in the scratch repository, then pushed as a new artifact.
#   - The Keptn tasks call a GitHub API mock in namespace e2e (the optional "api" key of the
#     github-dispatch Secret). The mock logs every workflow_dispatch and answers 204, so a
#     rollback or promotion is asserted as "requested"; the GitHub workflows themselves do not run.
#
# Usage: scripts/e2e.sh <step>...
#   up          create the Kind cluster "kfl-e2e" (light profile) and the local registry
#   flux        install Flux, push the tree, create the Secrets and the GitHub mock
#   wait        wait until every Flux Kustomization and HelmRelease is Ready
#   baseline    the first Keptn app version after the install succeeds (no rollback requested)
#               and Keptn manages only the four NFs (amf, smf, nssf, upf)
#   happy       scenario 1: bump RELEASE_ID; the app version succeeds, evaluation passes,
#               promotion dispatched
#   fault       scenario 2: faulty config (SMF DNN mismatch); kpi-guard fails and requests a
#               rollback, promotion skipped
#   diag [dir]  collect diagnostics (scripts/collect-diagnostics.sh)
#   memory      print the memory summary
#   down        delete the cluster and the registry
#   all         up flux wait baseline happy fault, then down (diagnostics on failure)
#
# Environment:
#   E2E_DIR             state directory (default ${TMPDIR:-/tmp}/kfl-e2e): scratch repo,
#                       kubeconfig, memory log, results
#   PROFILE             light (default) or full
#   REGISTRY_PORT       host port of the local registry (default 5001)
#   E2E_MIN_AVAIL_MIB   do not create the cluster below this much available memory (default 6144,
#                       the light-profile figure from scripts/bootstrap.sh); Linux only
#   E2E_MEM_FLOOR_MIB   stop the run when available memory falls below this (default 1024);
#                       `all` then deletes the cluster, single steps leave it for `down`; Linux only
#   E2E_KEEP=1          `all`: keep the cluster at the end
#   E2E_DIAG_DIR        `all`: where diagnostics go on failure (default $E2E_DIR/diagnostics)
#   READY_TIMEOUT       seconds for `wait` (default 1800)
#   VERSION_TIMEOUT     seconds for a Keptn app version to appear and finish (default 1800)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
E2E_DIR="${E2E_DIR:-${TMPDIR:-/tmp}/kfl-e2e}"
SRC="$E2E_DIR/src"
PROFILE="${PROFILE:-light}"
CLUSTER="kfl-e2e"
REGISTRY_NAME="kfl-e2e-registry"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"
REGISTRY_IMAGE="registry:3.1.1@sha256:325b4b29b041e82803abeb703e201655e4e23ab83264ec1a7c9ddb0a5b14a6e0"
MOCK_IMAGE="denoland/deno:2.9.8@sha256:a0d88a7fcbd44f062cba2748e19df67d30290ad12aa203c7c1e0b12462c483f0"
ARTIFACT="keptn-flux-5gc-lab"
FLUX_VERSION="${FLUX_VERSION:-2.10.0}"
E2E_MIN_AVAIL_MIB="${E2E_MIN_AVAIL_MIB:-6144}"
E2E_MEM_FLOOR_MIB="${E2E_MEM_FLOOR_MIB:-1024}"
READY_TIMEOUT="${READY_TIMEOUT:-1800}"
VERSION_TIMEOUT="${VERSION_TIMEOUT:-1800}"
NS=open5gs

export KUBECONFIG="$E2E_DIR/kubeconfig"

die() { echo "error: $*" >&2; exit 1; }
log() { printf '\n==> [%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
result() { # result PASS|FAIL|INFO <text>: record a scenario outcome
  local line="- **$1** $2"
  echo "$line" | tee -a "$E2E_DIR/results.md"
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "$line" >>"$GITHUB_STEP_SUMMARY"
  return 0
}
fail() { result FAIL "$*"; die "$*"; }

avail_mib() { awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo; }

# --- memory guard -------------------------------------------------------------------------
# Samples host available memory and the memory of the Kind node containers every 15 s into
# $E2E_DIR/memory.log, and stops the run (SIGTERM to the main process) below E2E_MEM_FLOOR_MIB.
kind_mem_mib() {
  docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' 2>/dev/null | awk -v c="$CLUSTER" '
    function mib(v) {
      if (v ~ /GiB$/) return v * 1024; if (v ~ /MiB$/) return v + 0
      if (v ~ /KiB$/) return v / 1024; return v / 1048576
    }
    index($1, c "-") == 1 { sum += mib($2) } END { printf "%d", sum }'
}

mem_guard() {
  local main=$1 a k
  while kill -0 "$main" 2>/dev/null; do
    k="$(kind_mem_mib)"
    if [[ -r /proc/meminfo ]]; then
      a="$(avail_mib)"
      echo "$(date -u +%FT%TZ) avail_mib=$a kind_mib=$k" >>"$E2E_DIR/memory.log"
      if (( a < E2E_MEM_FLOOR_MIB )); then
        echo "error: available memory ${a} MiB is below E2E_MEM_FLOOR_MIB=${E2E_MEM_FLOOR_MIB}; aborting" >&2
        echo "$(date -u +%FT%TZ) ABORT avail_mib=$a" >>"$E2E_DIR/memory.log"
        kill -TERM "$main" 2>/dev/null || true
        return
      fi
    else
      echo "$(date -u +%FT%TZ) kind_mib=$k" >>"$E2E_DIR/memory.log"
    fi
    sleep 15
  done
}

GUARD_PID=""
start_guard() {
  [[ -n "$GUARD_PID" ]] && return
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || return 0
  mem_guard $$ &
  GUARD_PID=$!
}
stop_guard() { [[ -n "$GUARD_PID" ]] && { kill "$GUARD_PID" 2>/dev/null || true; }; GUARD_PID=""; return 0; }

memory_summary() {
  [[ -s "$E2E_DIR/memory.log" ]] || { echo "no memory samples"; return 0; }
  awk '{ for (i = 2; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
         if (v["kind_mib"] > peak) peak = v["kind_mib"]
         if (v["avail_mib"] != "" && (min == "" || v["avail_mib"] < min)) min = v["avail_mib"] }
       END { printf "peak Kind node memory: %d MiB; lowest host available memory: %s MiB; samples: %d\n", peak, (min == "" ? "n/a" : min), NR }' \
    "$E2E_DIR/memory.log"
}

# --- steps --------------------------------------------------------------------------------
step_up() {
  for t in kind kubectl docker git; do command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"; done
  mkdir -p "$E2E_DIR"
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    die "Kind cluster $CLUSTER already exists; run 'scripts/e2e.sh down' first"
  fi
  local config=kind/cluster.yaml
  [[ "$PROFILE" == full ]] && config=kind/cluster-full.yaml
  [[ "$PROFILE" == light || "$PROFILE" == full ]] || die "PROFILE must be light or full"
  if [[ -r /proc/meminfo ]]; then
    local a; a="$(avail_mib)"
    (( a >= E2E_MIN_AVAIL_MIB )) || die "only ${a} MiB available, E2E_MIN_AVAIL_MIB=${E2E_MIN_AVAIL_MIB}"
    log "Host memory available: ${a} MiB"
  fi
  : >"$E2E_DIR/memory.log"
  : >"$E2E_DIR/results.md"

  log "Creating Kind cluster $CLUSTER from $config"
  kind create cluster --name "$CLUSTER" --config "$REPO_ROOT/$config" --kubeconfig "$KUBECONFIG" --wait 120s
  start_guard

  log "Starting local registry $REGISTRY_NAME on 127.0.0.1:$REGISTRY_PORT"
  docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$REGISTRY_NAME" --network kind -p "127.0.0.1:$REGISTRY_PORT:5000" "$REGISTRY_IMAGE" >/dev/null
}

registry_ip() {
  docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' "$REGISTRY_NAME"
}

# push_tree <message>: commit the scratch repo and push it as the flux-system artifact.
push_tree() {
  git -C "$SRC" add -A
  git -C "$SRC" diff --cached --quiet || git -C "$SRC" commit -qm "$1"
  local rev; rev="$(git -C "$SRC" rev-parse HEAD)"
  flux push artifact "oci://127.0.0.1:$REGISTRY_PORT/$ARTIFACT:e2e" --path="$SRC" \
    --source="e2e" --revision="e2e@sha1:$rev" --insecure-registry >/dev/null
  echo "pushed $rev ($1)"
}

# reconcile: make Flux pick up the last pushed artifact now instead of at the next interval.
reconcile() {
  flux reconcile source oci flux-system -n flux-system --timeout=2m
  flux reconcile kustomization flux-system -n flux-system --timeout=5m
  flux reconcile kustomization apps -n "$NS" --timeout=5m
}

step_flux() {
  command -v flux >/dev/null 2>&1 || die "missing tool: flux"
  start_guard
  local ip; ip="$(registry_ip)"
  [[ -n "$ip" ]] || die "registry $REGISTRY_NAME has no address on the kind network"

  log "Copying the working tree to $SRC"
  rm -rf "$SRC"
  mkdir -p "$SRC"
  # Tracked and untracked (not ignored) files as they are on disk, uncommitted edits included.
  (cd "$REPO_ROOT" && git ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' f; do [[ -e "$f" ]] && printf '%s\0' "$f"; done |
    tar --null -T - -cf -) | tar -xf - -C "$SRC"
  git -C "$SRC" init -q -b main
  git -C "$SRC" config user.name "kfl-e2e"
  git -C "$SRC" config user.email "kfl-e2e@localhost"

  log "Generating clusters/lab/flux-system (Flux v$FLUX_VERSION, OCI source $ip:5000)"
  flux install --version="v$FLUX_VERSION" --export >"$SRC/clusters/lab/flux-system/gotk-components.yaml"
  cat >"$SRC/clusters/lab/flux-system/gotk-sync.yaml" <<EOF
# Generated by scripts/e2e.sh: the e2e equivalent of what flux bootstrap writes.
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 1m
  url: oci://$ip:5000/$ARTIFACT
  ref:
    tag: e2e
  insecure: true
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 10m
  path: ./clusters/lab
  prune: true
  sourceRef:
    kind: OCIRepository
    name: flux-system
EOF
  # The lab's Flux Kustomizations (nested ones included) point at the GitRepository that
  # flux bootstrap creates; in the scratch copy they point at the OCIRepository instead.
  # shellcheck disable=SC2016  # ${1}/${2} are perl capture groups
  grep -rlZ --include='*.yaml' 'kind: GitRepository' "$SRC" | xargs -0 -r perl -0pi -e \
    's/(sourceRef:[ \t]*\n[ \t]*kind:[ \t]*)GitRepository([ \t]*\n[ \t]*name:[ \t]*flux-system\b)/${1}OCIRepository${2}/g'
  push_tree "e2e: working tree"

  log "Installing Flux from clusters/lab/flux-system"
  kubectl kustomize "$SRC/clusters/lab/flux-system" >"$E2E_DIR/flux-system.yaml"
  kubectl apply --server-side -f "$E2E_DIR/flux-system.yaml" >/dev/null 2>&1 || true
  kubectl wait --for=condition=Established crd --all --timeout=2m >/dev/null
  kubectl apply --server-side -f "$E2E_DIR/flux-system.yaml"
  kubectl -n flux-system rollout status deploy --timeout=5m
  kubectl get ns flux-system -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' | grep -qx baseline ||
    fail "flux-system namespace is missing the PSA enforce=baseline label"
  result PASS "Flux v$FLUX_VERSION controllers run in flux-system under PSA enforce=baseline"

  log "Waiting for the lab namespaces"
  # One name per call: with several names, kubectl 1.37 fails at once (NotFound) instead of waiting.
  for ns in open5gs observability; do kubectl wait --for=create "ns/$ns" --timeout=5m; done
  kubectl wait --for=jsonpath='{.status.phase}'=Active ns/open5gs ns/observability --timeout=5m

  log "Creating the runtime Secrets (no real token)"
  # Same shape as scripts/bootstrap.sh, plus "api": the Keptn tasks send their dispatches to the mock.
  printf '{"owner":"e2e","repo":"%s","token":"e2e-placeholder","api":"http://github-mock.e2e.svc:8080"}' "$ARTIFACT" |
    kubectl -n "$NS" create secret generic github-dispatch --from-file=SECURE_DATA=/dev/stdin \
      --dry-run=client -o yaml | kubectl apply -f -
  openssl rand -base64 18 | tr -d '\n' |
    kubectl -n observability create secret generic grafana-admin --from-literal=admin-user=admin \
      --from-file=admin-password=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -

  log "Deploying the GitHub API mock"
  deploy_mock
}

deploy_mock() {
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: e2e
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ConfigMap
metadata: { name: github-mock, namespace: e2e }
data:
  main.ts: |
    // Logs every request as one JSON line and accepts workflow_dispatch calls (HTTP 204).
    Deno.serve({ hostname: "0.0.0.0", port: 8080 }, async (req) => {
      const { pathname } = new URL(req.url);
      if (pathname === "/healthz") return new Response("ok");
      const m = pathname.match(/^\/repos\/[^/]+\/[^/]+\/actions\/workflows\/([^/]+)\/dispatches\$/);
      const text = await req.text();
      let payload = null;
      try { payload = JSON.parse(text); } catch { payload = text; }
      console.log(JSON.stringify({
        time: new Date().toISOString(), method: req.method, path: pathname,
        workflow: m ? m[1] : null, authorization: req.headers.has("authorization"), payload,
      }));
      if (req.method === "POST" && m) return new Response(null, { status: 204 });
      return new Response("not found", { status: 404 });
    });
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: github-mock, namespace: e2e }
spec:
  replicas: 1
  selector: { matchLabels: { e2e: github-mock } }
  template:
    metadata: { labels: { e2e: github-mock } }
    spec:
      automountServiceAccountToken: false
      enableServiceLinks: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1993
        runAsGroup: 1993
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: mock
          image: $MOCK_IMAGE
          command: [deno, run, --no-prompt, "--allow-net=0.0.0.0:8080", /app/main.ts]
          env:
            - { name: DENO_DIR, value: /deno-dir }
            - { name: DENO_NO_UPDATE_CHECK, value: "1" }
          ports: [{ name: http, containerPort: 8080 }]
          readinessProbe: { httpGet: { path: /healthz, port: http }, periodSeconds: 5 }
          volumeMounts:
            - { name: app, mountPath: /app, readOnly: true }
            - { name: deno-dir, mountPath: /deno-dir }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          resources:
            requests: { cpu: 5m, memory: 24Mi }
            limits: { memory: 64Mi }
      volumes:
        - { name: app, configMap: { name: github-mock } }
        - { name: deno-dir, emptyDir: { sizeLimit: 32Mi } }
---
apiVersion: v1
kind: Service
metadata: { name: github-mock, namespace: e2e }
spec:
  selector: { e2e: github-mock }
  ports: [{ name: http, port: 8080, targetPort: http }]
EOF
  kubectl -n e2e rollout status deploy/github-mock --timeout=3m
}

step_wait() {
  start_guard
  log "Waiting for Flux (timeout ${READY_TIMEOUT}s)"
  if ! "$REPO_ROOT/scripts/wait-ready.sh" "$READY_TIMEOUT"; then
    fail "Flux Kustomizations and HelmReleases not Ready within ${READY_TIMEOUT}s"
  fi
  kubectl -n "$NS" rollout status deploy --timeout=10m
  result PASS "all Flux Kustomizations and HelmReleases Ready; Open5GS and UERANSIM rolled out"
}

# --- Keptn helpers ----------------------------------------------------------------------------
release_id() { sed -nE 's/^[[:space:]]*RELEASE_ID:[[:space:]]*"([^"]+)".*/\1/p' "$SRC/clusters/lab/apps.yaml"; }

# appversion_for <release-id>: newest KeptnAppVersion of app open5gs in which the four tracked
# NFs (amf, smf, nssf, upf) carry that version.
appversion_for() {
  kubectl -n "$NS" get keptnappversions.lifecycle.keptn.sh -o json | jq -r --arg v "$1" '
    [.items[] | select(.spec.appName == "open5gs")
      | select([.spec.workloads[]? | select(.version == $v) | .name] as $n
               | ["amf", "smf", "nssf", "upf"] | all(. as $w | $n | index($w)))]
    | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty'
}

av_field() { kubectl -n "$NS" get keptnappversions.lifecycle.keptn.sh "$1" -o jsonpath="$2"; }

# wait_appversion <release-id>: wait for the app version to exist and to leave Pending/Progressing
# (promotion included); prints its name.
wait_appversion() {
  local rid=$1 deadline=$(( SECONDS + VERSION_TIMEOUT )) av="" st prom now last=""
  while (( SECONDS < deadline )); do
    [[ -z "$av" ]] && av="$(appversion_for "$rid")"
    if [[ -n "$av" ]]; then
      st="$(av_field "$av" '{.status.status}')"
      prom="$(av_field "$av" '{.status.promotionStatus}')"
      now="$st/$(av_field "$av" '{.status.currentPhase}')/post=$(av_field "$av" '{.status.postDeploymentStatus}')/eval=$(av_field "$av" '{.status.postDeploymentEvaluationStatus}')/promotion=$prom"
      [[ "$now" != "$last" ]] && { echo "  $av: $now" >&2; last="$now"; }
      case "$st" in
        Succeeded) [[ "$prom" == Pending || "$prom" == Progressing || -z "$prom" ]] || { echo "$av"; return 0; } ;;
        Failed | Deprecated | Warning | Cancelled) echo "$av"; return 0 ;;
      esac
    fi
    sleep 15
  done
  echo "$av"
  return 1
}

# task_for <app-version> <task-definition>: newest KeptnTask of that definition owned by the app version.
task_for() {
  kubectl -n "$NS" get keptntasks.lifecycle.keptn.sh -o json | jq -r --arg av "$1" --arg td "$2" '
    [.items[] | select(.spec.taskDefinition == $td and any(.metadata.ownerReferences[]?; .name == $av))]
    | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty'
}

wait_task() { # wait_task <task> [timeout-seconds]: wait for a KeptnTask to finish; prints its status
  local deadline=$(( SECONDS + ${2:-1200} )) st=""
  while (( SECONDS < deadline )); do
    st="$(kubectl -n "$NS" get keptntasks.lifecycle.keptn.sh "$1" -o jsonpath='{.status.status}')"
    [[ "$st" == Succeeded || "$st" == Failed ]] && break
    sleep 10
  done
  echo "$st"
}

task_logs() { # task_logs <task>: logs of the pods of the Job behind a KeptnTask
  local job pod
  job="$(kubectl -n "$NS" get keptntasks.lifecycle.keptn.sh "$1" -o jsonpath='{.status.jobName}')"
  [[ -n "$job" ]] || return 0
  for pod in $(kubectl -n "$NS" get pods -l "job-name=$job" -o name 2>/dev/null); do
    # The Job restarts a failed container in place; the first run's output is in --previous.
    kubectl -n "$NS" logs "$pod" --all-containers --previous --tail=200 2>/dev/null || true
    kubectl -n "$NS" logs "$pod" --all-containers --tail=200 2>/dev/null || true
  done
}

# mock_dispatches <workflow>: workflow_dispatch requests the GitHub mock has received, one JSON per line.
mock_dispatches() {
  kubectl -n e2e logs deploy/github-mock --tail=-1 2>/dev/null |
    jq -Rc --arg wf "$1" 'fromjson? | select(.workflow == $wf and .method == "POST")'
}

evaluations_of() { # evaluations_of <app-version>: "<name> <overallStatus>" per KeptnEvaluation it owns
  kubectl -n "$NS" get keptnevaluations.lifecycle.keptn.sh -o json | jq -r --arg av "$1" '
    .items[] | select(any(.metadata.ownerReferences[]?; .name == $av))
    | "\(.metadata.name) \(.status.overallStatus // "none")"'
}

summarize() { # summarize <app-version>: status line and per-task results
  local av=$1
  echo "  app version $av: status=$(av_field "$av" '{.status.status}') post=$(av_field "$av" '{.status.postDeploymentStatus}') evaluation=$(av_field "$av" '{.status.postDeploymentEvaluationStatus}') promotion=$(av_field "$av" '{.status.promotionStatus}')"
  kubectl -n "$NS" get keptnappversions.lifecycle.keptn.sh "$av" -o json | jq -r '
    [.status.postDeploymentTaskStatus[]?, .status.postDeploymentEvaluationTaskStatus[]?, .status.promotionTaskStatus[]?]
    | .[] | "    \(.definitionName): \(.status) (\(.name))"'
  evaluations_of "$av" | sed 's/^/    evaluation /'
}

# release <message> <command...>: run a lab script in the scratch repo, push, reconcile; prints RELEASE_ID.
release() {
  local msg=$1; shift
  (cd "$SRC" && NO_PUSH=1 "$@" >&2)
  push_tree "$msg" >&2
  reconcile >&2
  release_id
}

# --- scenarios ---------------------------------------------------------------------------------
step_baseline() {
  start_guard
  local rid av st task apps wls
  rid="$(release_id)"
  log "Baseline: first Keptn app version (RELEASE_ID $rid)"
  av="$(wait_appversion "$rid")" || fail "baseline: app version for $rid did not finish within ${VERSION_TIMEOUT}s (${av:-not created})"
  summarize "$av"
  st="$(av_field "$av" '{.status.status}')"
  task="$(task_for "$av" kpi-guard)"
  [[ -n "$task" ]] && task_logs "$task" | tail -n 5 | sed 's/^/    kpi-guard: /'
  # Keptn's pod webhook only selects pods labelled keptn.sh/workload: no auto-apps for MongoDB,
  # populate, the other NFs, UERANSIM or alert-relay, and no fifth workload in the open5gs app.
  apps="$(kubectl -n "$NS" get keptnapps.lifecycle.keptn.sh -o json | jq -r '[.items[].metadata.name] | sort | join(",")')"
  wls="$(kubectl -n "$NS" get keptnworkloads.lifecycle.keptn.sh -o json | jq -r '[.items[].metadata.name] | sort | join(",")')"
  echo "  Keptn apps: $apps; workloads: $wls"
  [[ "$apps" == open5gs ]] || fail "baseline: Keptn apps $apps (want only open5gs)"
  [[ "$wls" == open5gs-amf,open5gs-nssf,open5gs-smf,open5gs-upf ]] ||
    fail "baseline: Keptn workloads $wls (want the four NFs only)"
  (( $(mock_dispatches keptn-rollback.yaml | wc -l) == 0 )) || fail "baseline: a rollback was requested for the first release"
  [[ "$st" == Succeeded ]] || fail "baseline: first app version $av status=$st (want Succeeded)"
  result PASS "baseline: first app version $av for $rid Succeeded with no rollback request; Keptn manages only amf, smf, nssf, upf"
}

step_happy() {
  start_guard
  local before rid av st post ev prom n
  before="$(mock_dispatches keptn-promote.yaml | wc -l)"
  log "Scenario 1 (happy path): bump RELEASE_ID"
  rid="$(release "e2e: bump RELEASE_ID" bash -c 'scripts/bump-release.sh lab >/dev/null && git add -A && git commit -qm "Bump RELEASE_ID"')"
  echo "RELEASE_ID $rid"
  av="$(wait_appversion "$rid")" || fail "happy: app version for $rid did not finish within ${VERSION_TIMEOUT}s (${av:-not created})"
  summarize "$av"
  st="$(av_field "$av" '{.status.status}')"
  post="$(av_field "$av" '{.status.postDeploymentStatus}')"
  ev="$(av_field "$av" '{.status.postDeploymentEvaluationStatus}')"
  prom="$(av_field "$av" '{.status.promotionStatus}')"
  local task; task="$(task_for "$av" kpi-guard)"
  [[ -n "$task" ]] && task_logs "$task" | tail -n 5 | sed 's/^/    kpi-guard: /'
  [[ "$st" == Succeeded && "$post" == Succeeded && "$ev" == Succeeded ]] ||
    fail "happy: app version $av status=$st post=$post evaluation=$ev (want Succeeded)"
  evaluations_of "$av" | grep -qE ' (Pass|Succeeded)$' || fail "happy: no passing KeptnEvaluation for $av"
  [[ "$prom" == Succeeded ]] || fail "happy: promotion status $prom (want Succeeded)"
  n="$(mock_dispatches keptn-promote.yaml | wc -l)"
  (( n > before )) || fail "happy: promote task succeeded but the GitHub mock got no keptn-promote.yaml dispatch"
  mock_dispatches keptn-promote.yaml | tail -n 1 | sed 's/^/    mock: /'
  result PASS "scenario 1 (happy path): RELEASE_ID $rid -> app version $av Succeeded (tasks, evaluation open5gs-kpis), promotion dispatched (keptn-promote.yaml)"
}

step_fault() {
  start_guard
  local rb_before pr_before rid av st prom task logs
  rb_before="$(mock_dispatches keptn-rollback.yaml | wc -l)"
  pr_before="$(mock_dispatches keptn-promote.yaml | wc -l)"
  log "Scenario 2 (fault): switch Open5GS to values/open5gs-fault-slice.yaml"
  rid="$(release "e2e: inject fault" scripts/inject-fault.sh lab)"
  echo "RELEASE_ID $rid"
  av="$(wait_appversion "$rid")" || fail "fault: app version for $rid did not finish within ${VERSION_TIMEOUT}s (${av:-not created})"
  summarize "$av"
  st="$(av_field "$av" '{.status.status}')"
  prom="$(av_field "$av" '{.status.promotionStatus}')"
  task="$(task_for "$av" kpi-guard)"
  # The app version turns Failed as soon as any post-deployment task fails, possibly before
  # kpi-guard has finished; wait for kpi-guard itself.
  local tst=""
  [[ -n "$task" ]] && tst="$(wait_task "$task")"
  logs="$( [[ -n "$task" ]] && task_logs "$task" || true)"
  printf '%s\n' "$logs" | tail -n 8 | sed 's/^/    kpi-guard: /'

  [[ "$st" == Failed ]] || fail "fault: app version $av status=$st (want Failed)"
  [[ "$tst" == Failed ]] || fail "fault: kpi-guard task ${task:-missing} ended ${tst:-unknown} (want Failed)"
  grep -q 'rollback requested via Git' <<<"$logs" || fail "fault: kpi-guard did not report 'rollback requested via Git'"
  (( $(mock_dispatches keptn-rollback.yaml | wc -l) > rb_before )) || fail "fault: the GitHub mock got no keptn-rollback.yaml dispatch"
  local d; d="$(mock_dispatches keptn-rollback.yaml | tail -n 1)"
  echo "    mock: $d"
  jq -e '.payload.ref == "main" and .payload.inputs.stage == "lab" and .payload.inputs.source == "keptn" and .authorization' <<<"$d" >/dev/null ||
    fail "fault: rollback dispatch payload is not {ref: main, stage: lab, source: keptn} with a token"
  [[ "$prom" != Succeeded ]] || fail "fault: promotion ran for a failed release"
  (( $(mock_dispatches keptn-promote.yaml | wc -l) == pr_before )) || fail "fault: a keptn-promote.yaml dispatch was sent"
  local ev; ev="$(av_field "$av" '{.status.postDeploymentEvaluationStatus}')"
  [[ "$ev" != Succeeded ]] || fail "fault: post-deployment evaluation passed on the faulty release"
  result PASS "scenario 2 (fault): RELEASE_ID $rid -> app version $av Failed; kpi-guard breach, rollback dispatch requested (keptn-rollback.yaml, source keptn); evaluation $ev; promotion skipped"
}

step_diag() {
  "$REPO_ROOT/scripts/collect-diagnostics.sh" "${1:-${E2E_DIAG_DIR:-$E2E_DIR/diagnostics}}"
  cp "$E2E_DIR/memory.log" "$E2E_DIR/results.md" "${1:-${E2E_DIAG_DIR:-$E2E_DIR/diagnostics}}/" 2>/dev/null || true
}

step_down() {
  stop_guard
  log "Deleting Kind cluster $CLUSTER and registry $REGISTRY_NAME"
  kind delete cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" 2>/dev/null || true
  docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
}

step_memory() {
  local s; s="$(memory_summary)"
  echo "$s"
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "- $s" >>"$GITHUB_STEP_SUMMARY"
  return 0
}

step_all() {
  local rc=0
  trap 'rc=$?; stop_guard; if (( rc != 0 )); then step_diag || true; fi; step_memory; [[ "${E2E_KEEP:-0}" == 1 ]] || step_down; exit $rc' EXIT
  trap 'exit 143' TERM INT
  step_up
  step_flux
  step_wait
  step_baseline
  step_happy
  step_fault
}

(( $# )) || { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2; }
for t in kubectl jq; do command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"; done
mkdir -p "$E2E_DIR"
trap 'stop_guard' EXIT
while (( $# )); do
  case "$1" in
    up | flux | wait | baseline | happy | fault | down | memory | all) "step_$1" ;;
    diag) step_diag "${2:-}"; [[ $# -gt 1 ]] && shift ;;
    *) die "unknown step: $1" ;;
  esac
  shift
done
