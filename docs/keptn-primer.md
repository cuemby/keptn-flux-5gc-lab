# Keptn primer

This lab uses **Keptn v2.5.0** (Helm chart `keptn` 0.11.0), the Kubernetes-native lifecycle
toolkit. Much of what you find online still describes Keptn v1, which had a control plane,
shipyards and a CLI; none of that applies here. Keptn v2 is a set of operators and CRDs that
watch your Deployments and run checks around them.

Chart 0.11.0 deploys three operators in `keptn-system`:

| Operator | Version | Job |
|---|---|---|
| lifecycle-operator | v2.0.0 | Pod webhook, workload and app versions, tasks, evaluations, promotion, OTel traces |
| metrics-operator | v2.1.0 | `KeptnMetric` values and `Analysis` results from Prometheus |
| certificate-operator | v3.0.0 | TLS certificates for the webhooks |

## The objects

| Object | API group | Written by | In this lab |
|---|---|---|---|
| `KeptnApp` | lifecycle.keptn.sh | Keptn (auto-discovered from `keptn.sh/app`) | `open5gs` |
| `KeptnAppContext` | lifecycle.keptn.sh | you | `open5gs`: tasks, evaluation and promotion for the app |
| `KeptnWorkload` | lifecycle.keptn.sh | Keptn | `open5gs-amf`, `open5gs-smf`, `open5gs-nssf`, `open5gs-upf` |
| `KeptnWorkloadVersion` | lifecycle.keptn.sh | Keptn | one per workload and `keptn.sh/version` |
| `KeptnAppVersion` | lifecycle.keptn.sh | Keptn | one per release: `open5gs-<hash>` |
| `KeptnTaskDefinition` | lifecycle.keptn.sh | you | `traffic-burst`, `kpi-guard`, `kpi-guard-py`, `promote` |
| `KeptnTask` | lifecycle.keptn.sh | Keptn | one per task run; points at its Job |
| `KeptnEvaluationDefinition` | lifecycle.keptn.sh | you | `open5gs-kpis` |
| `KeptnEvaluation` | lifecycle.keptn.sh | Keptn | one per evaluation run |
| `KeptnMetricsProvider` | metrics.keptn.sh | you | `prometheus` |
| `KeptnMetric` | metrics.keptn.sh | you | four Open5GS KPIs, fetched every 15 s |
| `AnalysisValueTemplate`, `AnalysisDefinition` | metrics.keptn.sh | you | `open5gs-slo` and its three SLIs |
| `Analysis` | metrics.keptn.sh | you, by hand | `examples/analysis-run.yaml` |
| `KeptnConfig` | options.keptn.sh | you | OTel collector URL |

```
Deployment open5gs-amf (pod template: keptn.sh/workload label + keptn.sh/app, workload, version annotations)
  └─► KeptnWorkload open5gs-amf ──► KeptnWorkloadVersion open5gs-amf-<version>
KeptnApp open5gs (4 workloads) + KeptnAppContext open5gs
  └─► KeptnAppVersion open5gs-<hash>
        ├─ pre-deployment tasks/evaluations (none in this lab)
        ├─ workload deployments (the 4 KeptnWorkloadVersions)
        ├─ post-deployment tasks: KeptnTask traffic-burst ─► Job ─► Pod
        │                         KeptnTask kpi-guard     ─► Job ─► Pod
        ├─ post-deployment evaluation: KeptnEvaluation open5gs-kpis ─► KeptnMetrics ─► Prometheus
        └─ promotion task: KeptnTask promote ─► Job ─► Pod
```

## What triggers a lifecycle run

1. The namespace is enabled: `open5gs` carries the annotation `keptn.sh/lifecycle-toolkit: enabled`.
2. The pod reaches Keptn's mutating webhook. In this lab the webhook is limited to `open5gs`
   (`lifecycleOperator.allowedNamespaces`) and to pods with the `keptn.sh/workload` label (a
   post-renderer on the Keptn HelmRelease sets the webhook's `objectSelector`).
3. The workload names its app, workload and version (`keptn.sh/app`, `keptn.sh/workload`,
   `keptn.sh/version`). The Open5GS HelmRelease's post-renderer adds them to the AMF, SMF, NSSF and
   UPF only.
4. A new `keptn.sh/version` value means a new `KeptnWorkloadVersion`, and a new app version.
   This lab writes `RELEASE_ID` into it, so every `make bump` is a new release.

Without the `objectSelector`, Keptn v2 adopts every pod in an enabled namespace that has
`app.kubernetes.io/name` (or a parent Deployment, StatefulSet or DaemonSet with it): MongoDB, the
populate job, every other NF, UERANSIM and the alert relay all became auto-apps, and
`open5gs-populate` joined the `open5gs` app as a fifth workload. The two UERANSIM Deployments even
collided into one workload whose version flipped between two pod specs, and the gNB pod sat in
`SchedulingGated` for over 10 minutes.

## Follow one release

```bash
make bump && git commit -am "chore: bump RELEASE_ID" && git push
kubectl get keptnworkloadversions -n open5gs -w       # 4 new versions, one per NF
kubectl get keptnappversions -n open5gs               # open5gs-<hash>: phase and status
kubectl describe keptnappversion -n open5gs open5gs-<hash>
kubectl get keptntasks -n open5gs                     # traffic-burst, kpi-guard, promote
kubectl get keptntask -n open5gs <task> -o jsonpath='{.status.jobName}'; echo
kubectl logs -n open5gs -l job-name=<job> --tail=-1
kubectl get keptnevaluations -n open5gs
kubectl get keptnmetrics -n open5gs                   # current values
kubectl get events -n open5gs --field-selector involvedObject.kind=KeptnAppVersion
```

Then find the app version's trace in Jaeger.

Things the lab confirmed about Keptn v2.5.0:

- **Tasks in one phase run in parallel.** The lifecycle operator creates all post-deployment
  tasks at once. `kpi-guard` therefore waits for registration traffic and warms up for 3 minutes
  while `traffic-burst` restarts the gNB and UEs.
- **`retries: 0` is not "run once".** A task Job's failed container is restarted in place
  (Job restart policy) until the Job's backoff limit; the first run's output is in
  `kubectl logs --previous`. The rollback workflow treats a repeated request for the same app
  version as a duplicate.
- **Keptn does not roll back.** A failed task or evaluation marks the app version failed and
  skips promotion. The pods of the new release keep running.
- **Promotion tasks are off by default.** The lab sets `lifecycleOperator.promotionTasksEnabled: true`.

## Task runtimes

| Runtime | Field | Image | Lab task |
|---|---|---|---|
| Deno | `spec.deno.inline.code` | `ghcr.io/keptn/deno-runtime:v3.0.1` (Deno 2.0.5) | `kpi-guard`, `promote` |
| Python | `spec.python.inline.code` | `ghcr.io/keptn/python-runtime:v1.0.8` (Python 3.13) | `kpi-guard-py` |
| Container | `spec.container` (a full core/v1 Container) | your image | `traffic-burst` (`alpine/k8s:1.37.2`) |

The lifecycle operator picks the Deno and Python images (pinned by digest in
`platform/keptn/helmrelease.yaml`); a task definition cannot. Both runtimes get three environment
variables:

| Variable | Content |
|---|---|
| `DATA` | JSON of `spec.<runtime>.parameters.map` |
| `SECURE_DATA` | the `SECURE_DATA` key of the Secret named in `secureParameters.secret` (the CRD description calls it `SECRET_DATA`; the code uses `SECURE_DATA`) |
| `KEPTN_CONTEXT` | JSON with the app name, version (`appVersion`), workload and phase |

The Deno runtime runs with `--allow-net --allow-env=DATA,SECURE_DATA,KEPTN_CONTEXT`. Task
definitions take `spec.serviceAccount.name` and `spec.automountServiceAccountToken.type`, so a Job
can run as a dedicated identity with or without an API token.

Every task definition in this lab carries the annotation
`kustomize.toolkit.fluxcd.io/substitute: disabled`, so Flux leaves `${...}` in the task code alone.

## Evaluations and analyses

- **`KeptnEvaluationDefinition`** is a pass/fail gate: each objective is a `KeptnMetric` and a
  target such as `>0.95`. It runs as a pre- or post-deployment evaluation of the app context.
- **`AnalysisDefinition`** is a weighted SLO: objectives point at `AnalysisValueTemplate` queries
  (Go templates such as `{{.window}}`, filled from the `Analysis`'s `args`), each with failure and
  warning targets, a weight and an optional key objective, plus pass and warning percentages of the
  total score. An `Analysis` runs it once over a timeframe.

In Keptn v2.5.0 the Prometheus provider runs an `Analysis` as a range query over the timeframe and
keeps the first point, so `timeframe: { recent: 10m }` evaluates the window that ended about
10 minutes before the Analysis was created.

## Further reading

[references.md](references.md) lists the Keptn documentation pages for every object above.
