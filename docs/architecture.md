# Architecture

The lab mirrors the loop of the hackathon sandbox, which runs a commercial 5G core: Prometheus, then Keptn, then Git,
then Flux. Every change, including a rollback, is a Git commit that Flux applies. Keptn and
Alertmanager never call Flux or the cluster directly; they ask GitHub Actions to write a commit.

```
                      ┌──────────────────────── Git (your fork, main) ◄───────────────────────┐
                      │                                                                       │
                      ▼                                                                       │
                    Flux ── applies ──► Open5GS (AMF, SMF, NSSF, UPF, ...) + UERANSIM         │
                                               │ new keptn.sh/version on the NF pod templates │
                                               ▼                                              │
                     Keptn lifecycle operator: KeptnAppVersion "open5gs"                      │
                       post-deployment tasks:  traffic-burst ─┐                               │
                                               kpi-guard ─────┤── PromQL ──► Prometheus       │
                       post-deployment evaluation: open5gs-kpis                               │
                                    │ pass                       │ fail                       │
                                    ▼                            ▼                            │
                        promotion task "promote"     kpi-guard: workflow_dispatch             │
                        ── keptn-promote.yaml        ── keptn-rollback.yaml ── commit ────────┤
                                                                                              │
  Prometheus rules ── Open5GSDegradedAfterRelease ── Alertmanager ── alert-relay ── dispatch ─┘
  (mission control: 15 minutes of degradation after the release window)
```

## Who owns what

| Responsibility | Owner | Where |
|---|---|---|
| Desired state of every object, including a rollback | Git | your fork's `main` |
| Applying that state | Flux (source, kustomize and helm controllers) | `clusters/lab/` |
| Noticing a new release and running checks around it | Keptn lifecycle operator | `apps/open5gs/keptn/` |
| Test traffic after a rollout | Keptn container task `traffic-burst`; `traffic-pulse` CronJob between releases | `apps/open5gs/keptn/task-traffic-burst.yaml`, `apps/open5gs/traffic/` |
| Deciding pass or fail during the release window | Keptn tasks (`kpi-guard`) and evaluation (`open5gs-kpis`) | `apps/open5gs/keptn/` |
| Holding the KPIs | Prometheus | `infrastructure/observability/` |
| Watching after the release window | Prometheus rules and Alertmanager | `infrastructure/observability/monitors/alert-rules.yaml` |
| Turning a decision into a commit | GitHub Actions (`keptn-rollback`, `keptn-promote`) | `.github/workflows/` |
| Explaining what happened | Jaeger (one trace per app version), Grafana, Keptn events | `infrastructure/observability/` |

Keptn does not roll back. A failed post-deployment task or evaluation marks the
`KeptnAppVersion` failed and skips promotion; the new pods keep running until the rollback commit
reaches the cluster. This is the main point of learning goal 8.

## Flux layout and reconcile order

`flux bootstrap --path=clusters/lab` makes Flux reconcile `clusters/lab/kustomization.yaml`,
which lists the namespaces and one Flux `Kustomization` per layer:

| Flux Kustomization | Namespace | Path | Depends on | Notes |
|---|---|---|---|---|
| `flux-system` | flux-system | `clusters/lab` | | Created by `flux bootstrap`. `clusters/lab/flux-system/kustomization.yaml` adds the Pod Security labels to `flux-system` (enforce `baseline`). |
| `infrastructure` | flux-system | `infrastructure` | | Chart sources, RBAC, NetworkPolicies, admission policies, LimitRange. |
| `observability` | flux-system | `infrastructure/observability` | infrastructure | kube-prometheus-stack, OTel Collector, dashboards; `timeout: 15m`. |
| `observability-monitors` | flux-system | `infrastructure/observability/monitors` | (none, see notes) | PodMonitor and PrometheusRule. Applied only once the prometheus-operator CRDs exist; the parent's health check waits for it. |
| `tracing` | flux-system | `infrastructure/observability/tracing` | observability | Optional Jaeger. Remove `tracing.yaml` from `clusters/lab/kustomization.yaml` to drop it. |
| `platform` | flux-system | `platform/keptn` | observability | Keptn chart 0.11.0 (Keptn v2.5.0). |
| `platform-config` | flux-system | `platform/keptn/config` | platform | `KeptnConfig`, which needs the Keptn CRDs that `platform` installs. |
| `apps` | open5gs | `apps/open5gs` | platform | Open5GS, UERANSIM, traffic, Keptn objects, alert relay. Applied as the `flux-apps` ServiceAccount; `postBuild` substitutes `RELEASE_ID`. |

The two extra Kustomizations (`observability-monitors` and `platform-config`) exist because
Flux runs a server-side dry-run of the whole set before applying anything: a custom resource
whose CRD is installed by a HelmRelease in the same set fails that dry-run, and then nothing in
the set is applied. See [VERIFY.md](../VERIFY.md#assumptions-that-turned-out-wrong).

## Namespaces

| Namespace | Pod Security (enforce) | Contents |
|---|---|---|
| `flux-system` | baseline | Flux controllers |
| `keptn-system` | baseline | Keptn lifecycle, metrics and certificate operators |
| `observability` | privileged (node-exporter) | Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter, OTel Collector, Jaeger |
| `open5gs` | privileged (UPF and UEs need `NET_ADMIN` and `/dev/net/tun`) | Open5GS NFs, MongoDB, UERANSIM, traffic CronJob, Keptn objects and task Jobs, alert relay |

Every namespace warns and audits at the next stricter level (`baseline` or `restricted`).
`open5gs` carries `keptn.sh/lifecycle-toolkit: enabled`, the switch Keptn's pod webhook looks for.

## Release flow

1. `make bump` (`scripts/bump-release.sh lab`) writes a new UTC timestamp `RELEASE_ID`
   (`lab-YYYYMMDD-HHMMSS`) into `clusters/lab/apps.yaml`. It does not commit; commit and push yourself.
2. Flux substitutes `${RELEASE_ID}` into the `open5gs` HelmRelease. Its post-renderer writes
   `keptn.sh/app: open5gs`, `keptn.sh/version: <RELEASE_ID>` and `keptn.sh/workload: amf|smf|nssf|upf`
   on the four NF pod templates, and also sets `keptn.sh/workload` as a pod label. The changed
   HelmRelease spec makes helm-controller upgrade at once, and the four Deployments roll.
3. Keptn's pod webhook only sees pods that carry the `keptn.sh/workload` label (the Keptn
   HelmRelease post-renders the webhook's `objectSelector`). It creates one `KeptnWorkloadVersion`
   per NF and one `KeptnAppVersion` of the auto-discovered `KeptnApp` `open5gs`, named
   `open5gs-<hash>`.
4. When all four workloads are deployed, the lifecycle operator starts the post-deployment tasks
   from the `KeptnAppContext` `open5gs`. Keptn v2.5.0 creates all tasks of a phase at once, so
   `traffic-burst` and `kpi-guard` run in parallel:
   - `traffic-burst` waits for UERANSIM (up to 6 minutes on a fresh install), restarts the gNB and
     then the UEs, waits for the `uesimtun0` tunnel (up to 3 attempts), and pings the UPF gateway.
   - `kpi-guard` waits for registration traffic, warms up for 3 minutes, then soaks for 5 minutes.
     Two consecutive breaching samples make it request a rollback.
5. The post-deployment evaluation `open5gs-kpis` checks four KeptnMetrics.
6. If every task and the evaluation pass, the promotion task `promote` dispatches
   `keptn-promote.yaml`. With a single `lab` stage that workflow is a no-op.

### First release after a bootstrap

Flux installs UERANSIM only once Open5GS is Ready (`ueransim-gnb` depends on `open5gs`), so the
first Keptn app version starts before any UE exists. `traffic-burst` waits up to 6 minutes for the
gNB and UE Deployments, and `kpi-guard` waits up to 13 minutes (`trafficWaitSeconds: 780`) for
registration traffic before it starts its warm-up. The first release is therefore expected to
**pass**, with no rollback request; the e2e `baseline` step asserts exactly that. Earlier versions
of the lab failed the first release and sent a rollback dispatch right after bootstrap.

## Rollback flow

`keptn-rollback.yaml` is dispatched by `kpi-guard`/`kpi-guard-py` (`source: keptn`) or by
`alert-relay` (`source: alertmanager`). It does not `git revert` the last release commit, because
that commit can also carry unrelated files (every pull request that touches `apps/open5gs` bumps
`RELEASE_ID`). Instead, from the commit before the last release commit it restores only the
release inputs:

- the `configMapGenerator` values selection in `apps/open5gs/kustomization.yaml` (the
  `resources:` list stays as it is),
- the values files that selection references,
- the `apps/open5gs/helmrelease-*.yaml` files that existed then.

It never deletes files. It then bumps `RELEASE_ID` and pushes a `[keptn-rollback]` commit to
`main` as `github-actions[bot]`. Flux applies it and Keptn evaluates it as a new app version.

Guards:

| Situation | Result |
|---|---|
| Restoring changes no release input (for example, the last release commit only added a resource) | Fails with "Nothing to roll back"; pushes nothing |
| Alertmanager request, last release commit younger than 15 minutes | Quiet no-op ("Degradation predates the release"): the alert needs 15 minutes of degradation, so it began before that release |
| Last release commit is a rollback younger than 15 minutes, request for the app version that rollback replaced (or from Alertmanager) | Quiet no-op: a duplicate request |
| Last release commit is a rollback, and the request is older than 15 minutes or names a different app version | Stops in "Needs a human": the rollback did not help |

Both workflows run only from `refs/heads/main`, start from `permissions: {}`, pass inputs through
`env`, validate `stage`, `source` and `appVersion`, and are serialized by a `concurrency` group.
There is no pull-request mode: on a fork with branch protection on `main`, allow
`github-actions[bot]` to push, or the rollback fails.

## Mission control

`Open5GSDegradedAfterRelease` fires when registration success stays below 90 % (with at least
3 failed registrations in 10 minutes) for 15 minutes. That is longer than Keptn's warm-up and soak,
so it catches degradation that appears while the release is in operation, after Keptn passed it.
Alertmanager routes alerts labelled `action="rollback"` to the `alert-relay` Deployment in
`open5gs`, a small Deno service that turns a firing alert into a `keptn-rollback.yaml` dispatch. A
rollback needs a previous state to restore: the last release must have changed a release input
(a `RELEASE_ID`-only release fails with "Nothing to roll back"), and a `[keptn-rollback]` commit as
the last release stops it in "Needs a human". When it runs, the rollback commit produces a new Helm
release of `open5gs`, which also brings back what was changed by hand outside Git (scenario 9).

## Adding a second stage

The `promote` task dispatches `keptn-promote.yaml` with the stage and app version that passed.
The workflow walks `PROMOTION_ORDER` (`lab staging production`) and, when
`clusters/<next>/apps.yaml` exists, bumps that stage's `RELEASE_ID` and pushes. To add a stage:

1. Copy `clusters/lab/` to `clusters/staging/` and point a second cluster's `flux bootstrap` at
   it (`--path=clusters/staging`).
2. Set `metadata.stage` in a per-stage `KeptnAppContext` and the `stage` parameter of `kpi-guard`.
3. Keep one `RELEASE_ID` per stage. `keptn-rollback.yaml` already takes `stage` as input.

## Profiles

| Profile | Kind config | Nodes | Free memory for the cluster | Measured peak (Kind node containers) |
|---|---|---|---|---|
| `light` (default) | `kind/cluster.yaml` | 1 control-plane + 1 worker | about 6 GB | 3.6 to 3.9 GB on a laptop-class host; 4.5 to 4.7 GB on a GitHub runner |
| `full` | `kind/cluster-full.yaml` | 1 control-plane + 2 workers | about 12 GB | 5.7 GB on a GitHub runner |
| `light` + Cilium | `kind/cluster-cilium.yaml` | 1 + 1, Cilium 1.20.4 with SCTP | about 6 GB | 6.2 GB on a GitHub runner |

Both CNIs enforce the NetworkPolicies: Kind v0.24 and later ship kube-network-policies in kindnet.
Cilium is needed for scenario 7's SCTP checks.

## Test harnesses

| Harness | Cluster | Git source | GitHub side |
|---|---|---|---|
| `make bootstrap` | Kind `keptn-5gc` | your fork, through `flux bootstrap github` | real: dispatch token, real workflows |
| `scripts/e2e.sh` (and the `e2e` workflow) | Kind `kfl-e2e` | the working tree, pushed as an OCI artifact to a local registry; an `OCIRepository` named `flux-system` replaces the `GitRepository` | mocked: a GitHub API mock in namespace `e2e` records each `workflow_dispatch` and answers 204 |
| `scripts/live-github-check.sh` (and `live-github-check.yaml`) | Kind `keptn-5gc` | a `*-sandbox` repository, through `scripts/bootstrap.sh` | real: both tokens, the workflows run on GitHub |
