# keptn-flux-5gc-lab

A GitOps lab for a 5G core: **Flux** reconciles everything from Git, **Keptn v2.5.0** wraps each
5G core rollout with test traffic, KPI checks and an SLO gate, **Open5GS** is the 5G core and
**UERANSIM** generates gNB, UE and user-plane traffic. Prometheus, Alertmanager, Grafana, the
OpenTelemetry Collector and Jaeger v2 provide the observability. Fork it, point Flux at the fork,
and run it on a laptop with Kind or on any conformant Kubernetes cluster.

The lab is preparation material for the Sylva hackathon project "Enhancing GitOps with Keptn for
Autonomous Operations".

Documentation: [learning goals](docs/learning-goals.md), [architecture](docs/architecture.md),
[Keptn primer](docs/keptn-primer.md), [scenarios](docs/scenarios.md),
[observability](docs/observability.md), [security](docs/security.md),
[troubleshooting](docs/troubleshooting.md), [references](docs/references.md), and
[VERIFY.md](VERIFY.md) for what has been tested and what turned out different from the design.

## 1. What this is

Every change is a Git commit, including rollbacks:

```
  git commit ──► Flux ──► Open5GS / UERANSIM ──► Keptn post-deployment tasks
      ▲                                           (traffic-burst, kpi-guard, evaluation)
      │                                                     │ KPIs from Prometheus
      │                                        pass ─► promote │ fail
      │                                                     ▼
      └──── GitHub Actions rollback commit ◄──── workflow_dispatch (keptn-rollback)
                       ▲
                       └──── Alertmanager (after the release window) via alert-relay
```

| Phase | Analogy | Owner in this lab |
|---|---|---|
| Release checks: traffic, KPIs, SLO gate, rollback request | Launch control | Keptn tasks and evaluations |
| Watching the running system after the release window | Mission control | Prometheus rules and Alertmanager, through `alert-relay` |
| Applying any change, including a rollback | Ground systems | Flux, from Git |

## 2. Learning goals

The lab is organised around the hackathon's nine questions, from "what triggers Keptn to execute
a lifecycle action?" to "what would be required to integrate Keptn into a real delivery
pipeline?". [docs/learning-goals.md](docs/learning-goals.md) maps each question to a file and a
scenario, and maps hackathon Use-Case One onto the lab.

## 3. Prerequisites

- Docker or Podman on a cgroup v2 host. A Linux host or Linux VM is needed for the full UE data
  plane (the UPF and UEs use `/dev/net/tun`); the lab is tested on Linux only.
- [Kind](https://kind.sigs.k8s.io/) v0.33.0 or later, kubectl v1.37, the
  [Flux CLI](https://fluxcd.io/flux/installation/) 2.x (tested pins below), Helm 3 or 4, `openssl`.
  With [mise](https://mise.jdx.dev/), `mise install` in the repository root installs the exact
  versions pinned in `mise.toml` (Kind 0.33.0, Flux 2.10.0, kubectl, Helm, kustomize, kubeconform,
  yq, jq, shellcheck, actionlint, gitleaks); the e2e workflow uses the same file. Otherwise install
  them by hand from the links above.
- Two fine-grained GitHub tokens scoped to your fork (see [Quick start](#4-quick-start)).

### Profiles

| Profile | Kind nodes | Optional parts | Free memory for the cluster | CPUs | Disk |
|---|---|---|---|---|---|
| `light` (default) | 1 control-plane + 1 worker (`kind/cluster.yaml`) | tracing on, can be turned off | about 6 GB (an 8 GB laptop with little else running) | 4 | 20 GB |
| `full` | 1 control-plane + 2 workers (`kind/cluster-full.yaml`) | all on | about 12 GB (a 16 GB machine) | 6 | 30 GB |

`scripts/bootstrap.sh` refuses to create a new cluster on Linux when less memory than this is
available (override with `SKIP_MEMORY_CHECK=1`); an existing cluster is reused without the
check. Measured with `scripts/e2e.sh` on the light profile (whole lab with tracing, Open5GS,
UERANSIM and the Keptn tasks running): the two Kind node containers peaked at about 3.9 GB, so
6 GB free leaves room for image pulls and the host. The full profile has not been measured on a
laptop; the nightly `kind-extended` e2e job runs it on a GitHub-hosted runner (4 vCPUs, 16 GB),
where its three Kind nodes peaked at about 5.7 GB (light with Cilium: about 6.2 GB).

Select a profile and CNI with `PROFILE=light|full` and `CNI=kindnet|cilium`. Both enforce the lab's
NetworkPolicies (kindnet does since Kind v0.24); Cilium is needed for SCTP tests
(`kind/cluster-cilium.yaml`, `kind/cluster-full-cilium.yaml`).

Optional parts are separate Flux Kustomizations listed in `clusters/lab/kustomization.yaml`.
To drop Jaeger tracing, remove `tracing.yaml` from that list and commit; Flux prunes it.

## 4. Quick start

1. Fork this repository.
2. Create two fine-grained tokens limited to your fork:
   - `GITHUB_TOKEN` for `flux bootstrap`: Administration (write) and Contents (write). Revoke it
     after bootstrap.
   - `KEPTN_DISPATCH_TOKEN` for Keptn tasks and the alert relay: Actions (write) only.
3. Bootstrap:

   ```bash
   export GITHUB_USER=<your-login>        # GITHUB_OWNER=<org> if the fork lives in an organization
   export GITHUB_TOKEN=<bootstrap token>
   export KEPTN_DISPATCH_TOKEN=<dispatch token>
   make bootstrap                         # PROFILE=full or CNI=cilium to change the defaults
   flux get kustomizations -A --watch     # infrastructure -> observability -> platform -> apps
   make ui                                # Grafana :3000, Prometheus :9090, Alertmanager :9093, Jaeger :16686
   ```

4. Run the happy path once everything is Ready (about 15 minutes after bootstrap; the first Keptn
   app version should already have succeeded):

   ```bash
   kubectl get keptnappversions -n open5gs
   make bump && git commit -am "chore: bump RELEASE_ID" && git push   # scenario 1
   make fault                                                          # scenario 2 (commits and pushes)
   ```

`make up` creates only the Kind cluster; `make down` deletes it.

What the bootstrap does:

- Creates the Kind cluster for the chosen profile (and installs Cilium when `CNI=cilium`).
- Runs `flux bootstrap github --version=v$FLUX_VERSION --path=clusters/lab` (`FLUX_VERSION`
  defaults to 2.10.0), so the controllers match the CRD schemas `make validate` checks. Flux writes
  `clusters/lab/flux-system/gotk-components.yaml` and `gotk-sync.yaml` to your fork (the copies in
  this repository are empty placeholders) and keeps `clusters/lab/flux-system/kustomization.yaml`,
  which adds the Pod Security labels to the `flux-system` namespace.
- Creates the runtime Secrets `open5gs/github-dispatch` and `observability/grafana-admin`
  (random password). Nothing secret is ever committed.

## 5. Scenarios

| # | Scenario | Run in the CI e2e |
|---|---|---|
| 1 | Happy path: `make bump`, commit, push | yes |
| 2 | Bad config, Keptn rollback: `make fault` | yes (rollback request at a mock) |
| 3 | Loop guard | no: live sandbox check |
| 4 | No traffic | no: by hand |
| 5 | Flux failure | no: by hand |
| 6 | RBAC matrix and `add-user.sh` | yes |
| 7 | NetworkPolicy (and SCTP with Cilium) | nightly Cilium job |
| 8 | Admission warning on `busybox:latest` | no: by hand |
| 9 | Mission control: Alertmanager requests the rollback | no: live sandbox check (needs the token and a 15-minute degradation) |
| 10 | SLO analysis | yes |
| 11 | Python task runtime | yes |

Steps, expected results and the learning goals each one answers are in
[docs/scenarios.md](docs/scenarios.md).

## 6. Personas and adding users

`lab:viewers`, `lab:keptn-authors`, `lab:5gc-operators` and `lab:platform-admins`, with
`scripts/add-user.sh <name> <group>` issuing 7-day client certificates. Keptn authors can write
Keptn objects and read metrics and logs but cannot change the 5G core outside Git; three Deny-mode
admission policies stop task definitions and scrape configs from borrowing privileged identities or
Secrets. See [docs/security.md](docs/security.md).

`scripts/rbac-check.sh` runs the check matrix (scenario 6): `kubectl auth can-i` for each persona
group and for the workload identities (`keptn-traffic`, `keptn-task-runner`, `alert-relay`,
`flux-apps`), compared with the expected answers. `scripts/rbac-check.sh add-user` also issues a
real certificate for a test user in `lab:keptn-authors` with `add-user.sh`, checks it with
`kubectl auth whoami`, `can-i` and real requests, and deletes the test user's key and kubeconfig.

## 7. Other clusters

The manifests run on any conformant Kubernetes cluster (tested on 1.37; Keptn needs 1.27 or later
and the admission policies need `admissionregistration.k8s.io/v1`, 1.30 or later).
`scripts/bootstrap.sh` always uses Kind, so on another cluster run `flux bootstrap github
--version=v2.10.0 --path=clusters/lab` yourself and create the `open5gs/github-dispatch` and
`observability/grafana-admin` Secrets the way step 3 of `scripts/bootstrap.sh` does (values
through stdin). Then change:

- **Users:** map your OIDC groups claim to the four `lab:*` groups in
  `infrastructure/rbac/bindings.yaml` instead of issuing client certificates.
- **Faster reconciles:** add a Flux [Receiver](https://fluxcd.io/flux/components/notification/receivers/)
  so a push triggers reconciliation at once instead of the 1-minute `apps` poll.
- **Exposure:** publish Grafana, Prometheus, Alertmanager and Jaeger through
  [Gateway API](https://gateway-api.sigs.k8s.io/) with authentication, never Ingress NGINX
  (retired) and never without authentication.
- **Pod Security:** the UPF and UEs need `NET_ADMIN` and `/dev/net/tun`, so `open5gs` stays
  `privileged`; on a shared cluster give it dedicated nodes.
- **Branch protection:** `keptn-rollback` and `keptn-promote` push to `main` with
  `GITHUB_TOKEN`; allow `github-actions[bot]` to push.
- The lab-only defaults below.

## 8. Swapping the 5G core

Keptn only needs the pod template labels and annotations, a traffic generator and KPIs in
Prometheus. To use another 5G core (for example a commercial one in the hackathon sandbox), change:

| What | File |
|---|---|
| Which Deployments are Keptn workloads (`keptn.sh/workload` label and `keptn.sh/app`, `workload`, `version` annotations) | the `postRenderers` in `apps/open5gs/helmrelease-open5gs.yaml` |
| The PromQL of the KPIs | `apps/open5gs/keptn/metrics.yaml`, `apps/open5gs/keptn/analysis/value-templates.yaml`, the `REQ`/`REG`/`PDU`/`SESS` queries in `task-kpi-guard*.yaml`, `infrastructure/observability/monitors/alert-rules.yaml`, the Open5GS dashboard |
| How traffic is generated | `apps/open5gs/keptn/task-traffic-burst.yaml` and `apps/open5gs/traffic/traffic-pulse.yaml` (and the `keptn-traffic` Role) |
| The release inputs the rollback restores | the values files and `configMapGenerator` in `apps/open5gs/kustomization.yaml`; `.github/workflows/keptn-rollback.yaml` and `validate.yaml` list the same paths |
| The repository Flux watches | `flux bootstrap` (`GITHUB_OWNER`, `REPO`, `BRANCH`) |

Keep the small-count rule (a success ratio counts as low only with at least 3 failed requests) if
your traffic generator produces only a few requests per window; see
[docs/observability.md](docs/observability.md#the-small-count-rule).

## 9. Lab-only defaults to change for shared clusters

- OTLP is sent in plain text inside the cluster.
- Jaeger keeps traces in memory.
- The `open5gs` namespace enforces the `privileged` Pod Security level (UPF and UEs need
  `NET_ADMIN` and `/dev/net/tun`).
- The traffic job uses `pods/exec` on the UE pods.
- The image-pinning and Keptn-version ValidatingAdmissionPolicies run in `Warn` and `Audit` mode
  (the Keptn task-identity and operator Secret-reference policies deny).
- NetworkPolicies isolate ingress only; egress stays open.
- `alert-relay` accepts unauthenticated requests from inside the `open5gs` namespace.
- Users get client certificates, which cannot be revoked before they expire.

See [docs/security.md](docs/security.md#lab-only-defaults-to-change-for-shared-clusters).

## 10. Version pins

Every pin was checked against its registry or release page. Renovate (`renovate.json`) opens
pull requests for updates.

| Component | Pin | File |
|---|---|---|
| Kind | v0.33.0 | prerequisite |
| Kind node | `kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5` | `kind/*.yaml` |
| Flux | CLI and CRDs v2.10.0; APIs `source/v1`, `helm/v2`, `kustomize/v1` | `Makefile`, `scripts/bootstrap.sh`, all Flux objects |
| Keptn | chart `0.11.0` (Keptn v2.5.0) from `https://charts.lifecycle.keptn.sh` | `platform/keptn/helmrelease.yaml` |
| kube-prometheus-stack | `oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack:93.3.0@sha256:12b96b769049bbac5021d1bf544476ed3b1f42df7216d8eb7a70e98007a655a1` | `infrastructure/sources/oci.yaml` |
| opentelemetry-collector | chart `0.178.3` from `https://open-telemetry.github.io/opentelemetry-helm-charts` | `infrastructure/observability/otel-collector.yaml` |
| Jaeger | `cr.jaegertracing.io/jaegertracing/jaeger:2.20.0` | `infrastructure/observability/tracing/` |
| Open5GS chart | `oci://registry-1.docker.io/gradiantcharts/open5gs:2.4.1@sha256:b1feba2cbfa1c53bd1324c2a1b03ef52efc5a4e85401c8053972b17f1af62301` | `infrastructure/sources/oci.yaml` |
| ueransim-gnb chart | `oci://registry-1.docker.io/gradiantcharts/ueransim-gnb:0.2.6@sha256:0c8d4a51f91d80227c2cc84004ea094bc35ce3663c9ce74d9f037fd8549e8029` | `infrastructure/sources/oci.yaml` |
| kubectl + shell (traffic) | `alpine/k8s` 1.37.x, exact tag pinned in the file | `apps/open5gs/traffic/`, `apps/open5gs/keptn/task-traffic-burst.yaml` |
| Deno (alert-relay) | `denoland/deno` 2.x, exact tag pinned in the file | `apps/open5gs/mission-control/alert-relay.yaml` |
| Cilium (optional) | chart `1.20.4` from `https://helm.cilium.io` | `scripts/bootstrap.sh` |
| Validation tools | kustomize 5.8.3, kubeconform 0.8.0, yq 4.54.3, actionlint 1.7.12, gitleaks 8.30.1 | `Makefile` |

## 11. Checks

```bash
make tools      # pinned tools into .tools/bin, verified against the release checksums
make validate   # kustomize build + kubeconform -strict (Kubernetes 1.37.0 + CRD schemas) + shellcheck
make lint       # actionlint, SHA-pinned actions, gitleaks
```

`make validate` builds JSON schemas from the CRDs of the pinned Flux, Keptn and
kube-prometheus-stack versions, so misspelled fields in custom resources fail too. The
`validate` workflow runs the same targets on every pull request, plus a check that changes to
the Open5GS release inputs (`apps/open5gs/values/`, `apps/open5gs/helmrelease-*.yaml`,
`apps/open5gs/kustomization.yaml` and the `open5gs` and `ueransim-gnb` chart sources in
`infrastructure/sources/oci.yaml`) come with a `RELEASE_ID` bump in `clusters/lab/apps.yaml`.

### End-to-end test

```bash
scripts/e2e.sh all   # Kind (light profile) + Flux + scenarios 1, 2, 6, 10 and 11, then deletes the cluster
CNI=cilium scripts/e2e.sh all   # the same on Cilium, plus scenario 7 (NetworkPolicies, SCTP)
```

`scripts/e2e.sh` needs no GitHub token. It copies the working tree into a scratch Git repository,
pushes it as an OCI artifact to a local registry on the Kind network, and installs Flux with an
`OCIRepository` named `flux-system` in place of the `GitRepository` that `flux bootstrap`
creates. Scenario changes are made with the lab's own scripts (`bump-release.sh` and
`inject-fault.sh` with `NO_PUSH=1`) and pushed as new artifacts. The Keptn tasks send
their `workflow_dispatch` calls to a GitHub API mock in namespace `e2e` (the optional `api` key
of the `github-dispatch` Secret), so a rollback or promotion is checked as *requested*; the
`keptn-rollback` and `keptn-promote` workflows do not run. Steps can run one at a time
(`up`, `flux`, `wait`, `baseline`, `rbac`, `netpol`, `happy`, `fault`, `slo`, `python`, `diag`,
`down`); see the header of the script. `PROFILE=full` uses the three-node cluster and
`CNI=cilium` installs Cilium with SCTP enabled, as `scripts/bootstrap.sh` does. It records host
and Kind node memory every 15 s and stops the run when available memory falls below
`E2E_MEM_FLOOR_MIB` (default 1024); `scripts/e2e.sh all` (and the CI workflow's always-run `down`
step) then deletes the cluster, while single steps leave it for `scripts/e2e.sh down`. Up to the
fault (scenario 2), a run took about 35 minutes on a laptop-class host (about 15 of them until
everything is Ready); the scenario 11 step adds two more releases. The first Keptn
app version after a fresh install must succeed too: its traffic task waits for UERANSIM, which
Flux installs only after Open5GS is Ready, and `kpi-guard` starts its warm-up and soak only once
UERANSIM's registration traffic reaches the AMF. After the happy path it also checks the UPF KPIs:
PDU sessions on the UPF, the `UPFNoUserPlaneTraffic` alert not firing, and a one-shot
`open5gs-slo` Analysis (`examples/analysis-run.yaml`) passing, overall and on its `upf-sessions`
objective.

Scenarios beyond the happy path and the fault:

- 6 (`rbac`): `scripts/rbac-check.sh`, the persona and workload-identity matrix plus a real
  `add-user.sh` certificate.
- 7 (`netpol`): from namespace `default`, the AMF metrics port, the alert relay and Prometheus are
  blocked; from `open5gs` the AMF and Prometheus answer; Alertmanager reaches the alert relay (a
  request from an ephemeral container in the Alertmanager pod); Prometheus targets in `open5gs` are
  up and the KeptnMetrics update. With `CNI=cilium` it also checks SCTP: Cilium's `enable-sctp`, the
  AMF's NGAP Service on SCTP/38412 and registered UEs, which need NG Setup over that association.
  `all` runs it only with Cilium.
- 10 (`happy`, then `slo` after the fault): the `open5gs-slo` Analysis passes on the healthy lab
  and fails during the fault, with the `smf-pdu-success` and `upf-sessions` objectives failing.
- 11 (`python`): `kpi-guard` is swapped for `kpi-guard-py` in the app context together with
  `heal.sh`; that release passes under `kpi-guard-py`, then `inject-fault.sh` repeats scenario 2
  and `kpi-guard-py` requests the rollback.

The `e2e` workflow runs these steps on every pull request on a GitHub-hosted runner (light
profile, kindnet) and uploads diagnostics (`scripts/collect-diagnostics.sh`)
when a step fails. Its `kind-extended` job runs nightly and on `workflow_dispatch` (input
`variant`: `full`, `cilium` or `all`): the full profile with kindnet, and the light profile with
Cilium, where scenario 7 runs too.

### Live check against GitHub

The GitHub side of a rollback or promotion, the loop guard (scenario 3) and mission control
(scenario 9) need a real repository and the two tokens. `scripts/live-github-check.sh` runs them
end to end against a throwaway repository (default `cuemby/keptn-flux-5gc-lab-sandbox`; only names
ending in `-sandbox` unless `LIVE_ALLOW_ANY_REPO=1`).

The easiest way is to run it on a GitHub-hosted runner inside the sandbox itself, with
`.github/workflows/live-github-check.yaml` (workflow_dispatch; it does nothing in other repositories):

1. Copy the lab tree to the sandbox's `main`, workflows included, without `e2e.yaml` and
   `validate.yaml`. Use your own credentials: the bootstrap token cannot change workflow files.
2. Add the tokens to the sandbox only, without echoing them:
   `gh secret set LIVE_BOOTSTRAP_TOKEN -R <owner>/<repo>-sandbox` (Administration and Contents
   write) and `gh secret set LIVE_DISPATCH_TOKEN -R <owner>/<repo>-sandbox` (Actions write); each
   reads the value from stdin.
3. `gh workflow run live-github-check.yaml -R <owner>/<repo>-sandbox`. The job summary and the
   `live-github-check` artifact hold the results (and diagnostics on failure).

Or run it from a checkout, on a host with at least 6 GB available:

```bash
scripts/live-github-check.sh --creds ./creds.env [owner/repo]   # GITHUB_TOKEN, KEPTN_DISPATCH_TOKEN
```

It pushes the lab tree of the current `HEAD` commit to the repository's `main` (without the e2e
and validate workflows; the repository's `.github` must already match, or it stops before
pushing), bootstraps the light profile against it with `scripts/bootstrap.sh`, then:

- promote: the first release passes and `keptn-promote.yaml` runs on GitHub;
- rollback (scenario 2): a faulty release; `kpi-guard` dispatches `keptn-rollback.yaml`, its
  rollback commit lands, Flux applies it and the next release passes;
- mission (scenario 9): a release with a config change passes, the UDM is scaled to 0 with
  `kubectl`; after 15 minutes `Open5GSDegradedAfterRelease` fires, `alert-relay` dispatches the
  rollback, Flux applies it and the UDM's replicas are restored;
- loop-guard (scenario 3): the good config is made bad too and a fault is released; one rollback,
  then `keptn-rollback.yaml` stops in "Needs a human".

Each scenario first waits until the previous one's rollback alerts have cleared. A short fault keeps
`Open5GSDegradedAfterRelease` true for about 15 minutes after Keptn has already rolled it back, so
`keptn-rollback.yaml` ignores an Alertmanager request when the last release commit is younger than
15 minutes: that degradation began before the release.

It refuses to start while any Kind cluster exists or with less than 6 GB available, stops below
1 GB, and on exit deletes the cluster, puts the starting lab tree back on `main`, and deletes the
Flux deploy key and the credentials file, whatever the outcome. Tokens never reach process arguments or output. A run lasts a few hours (several
releases and a 15-minute degradation); results and workflow run URLs are written to
`$LIVE_DIR/results.md`.

## 12. References

Keptn v2, Flux, Open5GS, UERANSIM, Prometheus, OpenTelemetry, Jaeger and Kubernetes documentation:
[docs/references.md](docs/references.md). Most Keptn material online covers Keptn v1; this lab
uses Keptn v2.5.0.

## 13. Credits and license

Built with Augie Jagau's hackathon environment and use cases, by Cuemby, for Sylva WG-06.

Licensed under the Apache License 2.0; see [LICENSE](LICENSE).
