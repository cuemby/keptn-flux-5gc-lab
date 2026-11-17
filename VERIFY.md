# Verification

This file records how the lab was checked, what a live cluster has proven, what is still open,
and where the original design (the lab blueprint) turned out to be wrong. Status is as of
2026-11-17, at the commit that added this file.

## How to check a change

| Level | Command | Needs | Time |
|---|---|---|---|
| Offline | `make tools validate lint` | no cluster | minutes |
| Kind, no token | `scripts/e2e.sh all` (`PROFILE=full`, `CNI=cilium` for the variants) | about 6 GB free (12 GB full) | about 35 min up to scenario 2, about 60 min for `all` |
| Kind + GitHub | `scripts/live-github-check.sh` or `live-github-check.yaml` in a `*-sandbox` repository | both tokens, about 6 GB free | a few hours |

`make validate` builds every kustomization and checks it with
`kubeconform -strict -kubernetes-version 1.37.0`, using JSON schemas generated from the CRDs of the
pinned Flux 2.10.0, Keptn chart 0.11.0 and kube-prometheus-stack 93.3.0, and runs shellcheck on
every script. `make lint` runs actionlint, the SHA-pin check and gitleaks.

## Runs on record

| Where | Profile | Result | Peak memory (Kind nodes) |
|---|---|---|---|
| Laptop-class host (11 GB RAM), `scripts/e2e.sh`, 9 runs | light, kindnet | Run 9 green: Flux on PSA baseline, everything Ready in about 15 min, scenarios 1 and 2. Runs 2 to 8 each found a lab defect, fixed below. | 3.6 to 3.9 GB; lowest host MemAvailable 1.2 GB |
| GitHub runner, `e2e` `kind` job ([run](https://github.com/cuemby/keptn-flux-5gc-lab/actions/runs/44054147791)) | light, kindnet | Green: baseline, scenarios 6 (69/69), 1, 10 (5/5), 2, 10 during the fault (2/5, fails as expected), 11 | 4.7 GB |
| GitHub runner, `kind-extended` ([run](https://github.com/cuemby/keptn-flux-5gc-lab/actions/runs/44054154313)) | full (3 nodes), kindnet | Green: same scenarios | 5.7 GB |
| GitHub runner, `kind-extended` ([run](https://github.com/cuemby/keptn-flux-5gc-lab/actions/runs/44054160051)) | light, Cilium 1.20.4 | Green: same scenarios plus 7 (NetworkPolicies, SCTP: `enable-sctp`, NGAP on SCTP/38412, 2 UEs registered) | 6.2 GB |
| GitHub runner, `e2e` on the last merged pull request ([run](https://github.com/cuemby/keptn-flux-5gc-lab/actions/runs/44116320547)) | light, kindnet | Green | |
| Sandbox repository, `live-github-check.yaml` ([run](https://github.com/cuemby/keptn-flux-5gc-lab-sandbox/actions/runs/44098309729)) | light, kindnet, real tokens | Green: `flux bootstrap github`; promote on GitHub; scenario 2 with the real rollback commit; scenario 9 (alert fired 16 min after the UDM was scaled to 0, relay dispatch, rollback, drift reverted); scenario 3 (one rollback, then "Needs a human") | runner lowest available 11 GB |

The GitHub runner has 4 vCPUs and 16 GB. The first live sandbox run found one more defect (an
Alertmanager rollback reverted a newer, healthy release); the fix is listed below.

## Live-cluster checklist

Proven means a run above exercised it on Kind. Open means nothing has run it yet.

### Platform and Flux

- [x] Kind v0.33.0 with `kindest/node:v1.37.0` (pinned digest), light and full profiles, kindnet and Cilium 1.20.4 (`sctp.enabled`, `ipam.mode=kubernetes`, kube-proxy kept).
- [x] `flux bootstrap github` (Flux 2.10.0) keeps the committed `clusters/lab/flux-system/kustomization.yaml`; `flux-system` runs under PSA `enforce: baseline`.
- [x] The OCI chart pins (digests, `tar+gzip` layer media type) resolve in source-controller.
- [x] Reconcile order `infrastructure` → `observability` (with `observability-monitors`) → `tracing` → `platform` → `platform-config` → `apps`; the `apps` Kustomization applies as `flux-apps` across namespaces.
- [x] Keptn 0.11.0 (v2.5.0) on Kubernetes 1.37 with the digest-pinned operators and runtimes; the pod webhook only in `open5gs` and only for pods with `keptn.sh/workload`; promotion tasks run.
- [ ] Kubernetes 1.36 and 1.35 fallback node images (not needed so far).
- [ ] Renovate PRs for the pins (Renovate does not see image strings inside HelmRelease values; re-resolve them with every chart bump).

### 5G core and traffic

- [x] Open5GS 2.8.0 (chart 2.4.1) and UERANSIM 3.2.6 (chart 0.2.6): NG Setup, UE registration, PDU sessions and pings through `uesimtun0` to `10.45.0.1`, on kindnet and on Cilium (NGAP over SCTP).
- [x] Deployment names `open5gs-amf|smf|nssf|upf`, `ueransim-gnb`, `ueransim-gnb-ues`; UE label `app.kubernetes.io/component=ues`; `ping` in the UE image.
- [x] Metric names for the AMF, SMF and UPF scraped through the chart ServiceMonitors under Prometheus 3, except the N3 packet counter, which stays at 0.
- [x] The fault (SMF DNN `ims` vs UE DNN `internet`): registration stays healthy, PDU sessions fail, UPF sessions drop to 0.
- [x] Light-profile memory (3.6 to 3.9 GB measured on a laptop-class host).
- [ ] Full-profile memory on a laptop (measured only on a GitHub runner: 5.7 GB).
- [ ] UE data plane on macOS or Windows hosts (Docker Desktop VMs); the lab is tested on Linux only.

### Keptn lifecycle

- [x] Workload and app versions from the post-renderer annotations; exactly one KeptnApp (`open5gs`) with exactly the four NF workloads.
- [x] Post-deployment tasks run in parallel; task Jobs run as `keptn-traffic` and `keptn-task-runner` (no token).
- [x] The first release after a bootstrap succeeds with no rollback request.
- [x] Scenario 1: tasks, evaluation and promotion pass; promotion dispatched.
- [x] Scenario 2: `kpi-guard` breaches twice and requests a rollback; evaluation and promotion skipped.
- [x] Scenario 10: `open5gs-slo` 5/5 healthy and 2/5 during the fault.
- [x] Scenario 11: `kpi-guard-py` passes a healthy release and requests a rollback on the fault.
- [ ] Keptn traces in Jaeger: one trace per app version with spans for each task (the collector and Jaeger run, but no run has asserted the trace content).
- [ ] Keptn Grafana dashboards populated from `job="otel-collector"`.
- [ ] Scenario 4 (no traffic) on a cluster.

### Observability

- [x] kube-prometheus-stack 93.3.0 with CRDs `CreateReplace`, Grafana from the `grafana-admin` Secret, OTel Collector, Jaeger.
- [x] `UPFNoUserPlaneTraffic` loaded on the UPF session metric and inactive on a healthy lab.
- [x] `Open5GSDegradedAfterRelease` fires about 16 minutes after a real break and reaches `alert-relay` through Alertmanager and the NetworkPolicy.
- [ ] `FluxReconciliationFailing` firing from `gotk_resource_info` (scenario 5); the Flux dashboards populated.
- [ ] node-exporter with `hostRootFsMount` disabled on Kind (runs; not inspected).

### Security

- [x] Scenario 6: 59 RBAC matrix checks with impersonation plus a real `add-user.sh` certificate (Kind CSR signer, 7-day expiry, `auth whoami`, real allowed and forbidden requests).
- [x] Scenario 7: NetworkPolicies on Cilium; under kindnet the policies did not break scrapes, Keptn queries or task traffic.
- [x] The Deny admission policies and the RBAC matrix on a standalone Kubernetes 1.37 API server (28 denial cases).
- [ ] Scenario 7's deny checks on kindnet (the CI runs them only with Cilium).
- [ ] Scenario 8 (`busybox:latest` warning) and ValidatingAdmissionPolicy `status.typeChecking` on Kind.
- [ ] The persona experience end to end with a participant's kubeconfig (port-forward, Analysis creation, log access).

### GitHub

- [x] `keptn-rollback` on GitHub: `GITHUB_TOKEN` push to `main`, restore of the release inputs, the loop guard ("Needs a human"), the Alertmanager "predates the release" guard.
- [x] `keptn-promote` on GitHub (no-op with one stage).
- [ ] `keptn-promote` with a second stage on a real repository (exercised only in a local workflow harness).
- [ ] Rollback on a fork with branch protection on `main`.

## Scenarios that cannot run in the CI e2e

The `e2e` workflow runs without tokens: a GitHub API mock in namespace `e2e` records each
`workflow_dispatch` and answers 204, so it can only check that a rollback or promotion was
*requested*.

| Scenario | Why not in the `e2e` workflow | Where it runs instead |
|---|---|---|
| GitHub side of rollback and promotion (2, 1) | Needs the dispatch token and a repository the workflows can push to | `live-github-check` in the sandbox |
| 3, loop guard | Needs `keptn-rollback` to push real commits | `live-github-check` |
| 9, mission control | Needs a real token, a 15-minute degradation and the rollback workflow | `live-github-check` |
| 7 on kindnet, SCTP | The pull-request job uses kindnet; SCTP needs Cilium | nightly `kind-extended` (Cilium) |
| Full profile | Too slow for every pull request | nightly `kind-extended` |
| 4, 5, 8 | Not scripted | by hand |

## Assumptions that turned out wrong

Each entry: what the blueprint said, what is actually true, what the lab does.

### Versions and sources

- **Open5GS chart 2.2.9.** No such tag: `gradiantcharts/open5gs` holds 2.3.3 to 2.4.1 and
  `gradiant/open5gs` ends at 2.2.6. The lab pins `gradiantcharts/open5gs` 2.4.1 (Open5GS 2.8.0) by digest.
- **`ueransim-gnb` from `gradiant/`.** 0.2.6 exists under both `gradiant/` and `gradiantcharts/`
  with different content. The lab pins `gradiantcharts/ueransim-gnb` 0.2.6 by digest.
- **OCI layer media type `application/vnd.cncf.helm.chart.content.v1.tar.gz`.** The charts use
  `...content.v1.tar+gzip`. Fixed in `infrastructure/sources/oci.yaml`.
- **kube-prometheus-stack `semver: <major>`.** Pinned to 93.3.0 plus its digest.
- **Values file `5gSA-values.yaml` plus `bitnamilegacy/mongodb`.** Chart 2.4.1 ships
  `values-5g.yaml` (without PLMN, slice or subscriber settings) and bundles its own MongoDB on the
  official `mongo` image. The good values are the chart's 5G defaults plus the Gradiant tutorial's
  AMF, NSSF and subscriber settings; the Bitnami override was dropped.
- **The chart's MongoDB 8.0.34 runs anywhere.** It refuses to start on Linux kernels 6.19 to
  7.0.13 (SERVER-121912), including GitHub's ubuntu-latest. Pinned to `mongo` 7.0.48. A volume
  written by 8.0 cannot be opened by 7.0.
- **`alpine/k8s:<1.37.x>` and `denoland/deno:<2.x>`.** Pinned `alpine/k8s:1.37.2` and
  `denoland/deno:2.9.8` by digest; the Deno image's user is UID 1993, which the relay uses.
- **Keptn v2.5.0 means v2.5.0 components.** Chart 0.11.0 deploys lifecycle-operator v2.0.0,
  metrics-operator v2.1.0 and certificate-operator v3.0.0; the Deno and Python runtimes are
  `deno-runtime:v3.0.1` (Deno 2.0.5) and `python-runtime:v1.0.8` (Python 3.13). All pinned by digest
  in the platform values; task definitions cannot choose them.
- **`actions/checkout@<sha> # v4.x`.** The current release is v7.0.1; every action is pinned to a
  full SHA.
- **datreeio CRDs-catalog has the schemas.** It has no Keptn schemas. `make validate` builds them
  from the pinned Flux, Keptn and kube-prometheus-stack CRDs.
- **Renovate raises PRs for every pin.** Renovate does not see image strings inside HelmRelease
  values; re-resolve them with every chart bump.

### Flux

- **`platform/keptn` holds the HelmRelease and the KeptnConfig.** The KeptnConfig CRD comes from
  that HelmRelease, so Flux's dry-run fails and nothing is applied. KeptnConfig moved to
  `platform/keptn/config`, applied by `platform-config`.
- **PodMonitor and PrometheusRule next to kube-prometheus-stack.** Same dry-run problem. They live
  in `infrastructure/observability/monitors`, applied by the nested `observability-monitors`.
- **`flux bootstrap` creates `flux-system/kustomization.yaml`.** Flux 2.10.0 keeps an existing one;
  the PSA patch is committed there, with empty `gotk-*.yaml` placeholders.
- **`flux-apps` (namespace admin) can apply a Role and its RoleBinding in one Kustomization.** The
  RBAC escalation check looks up the Role during the dry-run. `flux-apps` gets `bind` on that Role.
- **`kubectl wait --for=create ns/a ns/b`.** kubectl 1.37.2 fails at once with NotFound when given
  two names; `bootstrap.sh` waits for each namespace separately.
- **Tokens via `--from-literal` and a final blocking `flux get --watch`.** Tokens showed up in the
  process list. Secrets are piped through stdin; the Grafana password is not rotated on a rerun.

### Keptn

- **KeptnTaskDefinition `serviceAccount` and `automountServiceAccountToken` may be missing.** Both
  are in the 0.11.0 CRD and applied to the Job; no fallback needed.
- **`promotionTasksEnabled` path unknown.** `lifecycleOperator.promotionTasksEnabled`, default
  `false`; the lab sets `true`.
- **Task order unknown.** Tasks in a phase run in parallel.
- **The env var is `SECRET_DATA`** (CRD description). The code uses `SECURE_DATA`.
- **Keptn only manages the annotated NFs.** Keptn v2 adopts every pod in an enabled namespace with
  `app.kubernetes.io/name`: MongoDB, populate, the other NFs, UERANSIM and the relay became
  auto-apps, populate joined the `open5gs` app, and the two UERANSIM Deployments collided into one
  workload that gated the gNB pod. The webhook now selects only pods with the `keptn.sh/workload`
  label, which the post-renderer sets on the four NFs.
- **Keptn's pod webhook is harmless elsewhere.** It covered every namespace with
  `failurePolicy: Fail`. Limited with `allowedNamespaces: [open5gs]`.
- **`retries: 0` runs a task once.** The Job restarts a failed container in place, so a breach can
  run the soak again; `kpi-guard`'s second request is treated as a duplicate.
- **Analysis `timeframe.recent` covers the last minutes.** The Prometheus provider keeps the first
  point of a range query, so `recent: 10m` with a 5m window describes the window that ended about
  10 minutes earlier. Create an Analysis at least 15 minutes after the change you want to judge.
- **`install/upgrade.crds: CreateReplace` manages the Keptn CRDs.** They are regular templates in
  the subcharts; the setting is kept and harmless.

### KPIs and the release check

- **`fivegs_ep_n3_gtp_indatapktn3upf` measures user-plane traffic.** Open5GS 2.8.0 exports it but
  never increments it. `kpi-guard`, the evaluation, `UPFNoUserPlaneTraffic`, the Analysis and the
  dashboard use `fivegs_upffunction_upf_sessionnbr` instead; the N3 KeptnMetric was removed.
- **Fault = the AMF serves SST 2 while UEs ask for SST 1.** Open5GS then rejects NG Setup, so
  there is no traffic and no breach. The next attempt, an NSSF-only slice change, had no effect (the
  AMF never asked the NSSF). The fault now gives the SMF DNN `ims` while the UEs use `internet`.
- **A `RELEASE_ID` bump keeps UERANSIM attached.** Every release rolls the AMF, and UERANSIM 3.2.6
  never redoes NG Setup. The traffic jobs restart the gNB before the UEs.
- **`kpi-guard` can judge the release as soon as the NFs roll.** The 2m windows still hold the old
  pods' series, a fresh SMF's counter reads 0, and SMF-UPF PFCP needs 20 to 60 s. `kpi-guard` now
  waits for traffic (up to 780 s), warms up 180 s, then soaks 300 s, and only counts the PDU ratio
  when the SMF saw requests.
- **Success ratios over a few requests are meaningful.** With 2 UEs, `traffic-pulse`'s restarts
  abort one or two registrations, which read 0.57 to 0.75. Every ratio gate (kpi-guard, the
  KeptnMetrics, the Analysis templates, the three ratio alerts) needs at least 3 failed requests.
- **The first release on a fresh lab can pass as designed.** It always failed: `traffic-burst`
  ran before UERANSIM existed. It now waits up to 6 minutes for UERANSIM, and the first release
  passes.
- **`traffic-burst` attaches the UEs once.** Right after a release the SMF can lack a UPF, and a UE
  whose PDU session fails does not retry; the task retries up to 3 times.
- **populate's `wait-for-mongodb` fits in 128Mi.** `mongosh` peaks at about 205 MiB; limit 320Mi.
- **The traffic Role needs `get`, `watch`, `patch`.** `kubectl rollout status` also lists; and
  `HOME=/tmp` with an emptyDir is needed for kubectl on a read-only root filesystem.

### Observability

- **The Flux alert uses `gotk_reconcile_condition`.** Flux no longer exports it;
  kube-state-metrics builds `gotk_resource_info` from the Flux objects.
- **Keptn metrics arrive over OTLP.** Keptn v2.5.0 exposes them in Prometheus format on port
  2222; the collector scrapes them as `job="otel-collector"`, which Keptn's dashboards query.
- **Collector names `otlp/jaeger` and `k8sattributes`.** Chart 0.178.3 / collector 0.163.2 use
  `otlp_grpc` and `k8s_attributes`.
- **Jaeger all-in-one listens on its ports.** Its built-in config binds to localhost; an explicit
  config binds 0.0.0.0.
- **Keptn dashboards import as-is.** They reference hard-coded data source UIDs, mapped to
  `prometheus` and `jaeger`.
- **Prometheus 2 days, Jaeger 1Gi.** Laptop profile: Prometheus 1 day / 1 GB, Jaeger 512Mi; Kind's
  localhost-only control-plane scrapes are disabled.

### Security

- **Kindnet does not enforce NetworkPolicies.** Kind v0.24 and later ship kube-network-policies,
  so the default lab enforces them.
- **RBAC alone keeps authors from changing the core outside Git.** Operators run task Jobs and
  queries on the author's behalf. Three Deny admission policies limit task identities, Secrets and
  privileges, and Secret references in metrics providers and scrape configs.
- **The §9.7 matrix line `kubectl auth can-i create pods/exec`.** kubectl reads `exec` as a pod
  name; subresources need `--subresource=exec`.
- **LimitRange content.** A CPU maximum would reject the containers without CPU limits; memory only.
- **RBAC and admission manifests "unchanged from v3".** The v3 text was not available; they were
  written from the blueprint's tables.

### Mission control and workflows

- **Rollback = `git revert` of the last release commit.** That commit can carry unrelated files.
  The workflow restores only the release inputs from the commit before it and never deletes files.
- **A rollback always changes something.** If restoring changes no release input, the workflow
  fails with "Nothing to roll back".
- **Any request within 15 minutes of a rollback is a duplicate.** The rollback's own release fails
  within minutes, so "Needs a human" never triggered. A Keptn request for a different app version
  now stops the loop.
- **An Alertmanager rollback request is always about the latest release.** A fault Keptn already
  rolled back keeps the alert's window failing; the alert then reverted a newer, healthy release.
  Requests less than 15 minutes after a release commit are now ignored.
- **"With protection on main, rollback switches to PR mode."** There is no PR mode; the rollback
  pushes to `main`.
- **The relay code as written.** It crashed on invalid JSON, dispatched to `repos/undefined`
  without a Secret, had no timeout and logged failures as success. It now answers 400, 503 and 502
  in those cases, has a 10 s timeout, and the Secret is optional so a lab without a token stays
  healthy.
- **Commit identity `keptn-bot@users.noreply.github.com`.** That address belongs to an unrelated
  account; the workflows use `github-actions[bot]`.
- **Workflows can run from any ref.** Both run only from `main`.

### Documentation

- **`make bump` commits and pushes.** The Makefile help text claimed this, but
  `scripts/bump-release.sh` only writes the new `RELEASE_ID`; commit and push it yourself. The help
  text was corrected. `make fault` and `make heal` do commit and push.
- **Reference list.** The hackathon list's PodTatoHead and metrics-operator links were wrong
  (replaced). The ControlPlane Flux overview moved to `/blog/`. The keptn.sh guides named only by
  their navigation title now have direct links. All links were checked on 2026-11-17.
