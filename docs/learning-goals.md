# Learning goals

The Sylva hackathon environment sets the bar for this lab: participants should leave able to
design, configure, troubleshoot and extend a Keptn solution on their own. It also recommends
working through three or four use cases in depth rather than many shallow demos. The lab is
organised around the nine questions below. Each scenario in [scenarios.md](scenarios.md) ends
with the numbers of the questions it answers.

| # | Question | Where the lab answers it |
|---|---|---|
| 1 | What triggers Keptn to execute a lifecycle action? | Scenario 1. A pod template change in the Keptn-enabled `open5gs` namespace, on a Deployment that carries the `keptn.sh/workload` label and the `keptn.sh/app`, `keptn.sh/workload` and `keptn.sh/version` annotations, creates a new `KeptnWorkloadVersion`. `scripts/bump-release.sh` writes a new `RELEASE_ID`, Flux substitutes it into `keptn.sh/version` on the AMF, SMF, NSSF and UPF, and that is the change. See [keptn-primer.md](keptn-primer.md#what-triggers-a-lifecycle-run). |
| 2 | How are lifecycle tasks defined and configured? | `KeptnTaskDefinition` in all three runtimes: Deno (`kpi-guard`), Python (`kpi-guard-py`) and container (`traffic-burst`), in `apps/open5gs/keptn/`. Scenario 11 swaps the Deno task for the Python one. |
| 3 | How do Keptn resources interact with Kubernetes resources? | Scenario 1 walkthrough: Deployment, then `KeptnWorkload` and `KeptnWorkloadVersion`, then `KeptnApp` and `KeptnAppVersion`, then the task Jobs. The commands are in [keptn-primer.md](keptn-primer.md#follow-one-release). Scenario 6 shows which Kubernetes identity each task Job runs as. |
| 4 | How are application metrics incorporated into evaluations? | `KeptnMetricsProvider` (Prometheus), then `KeptnMetric`, then `KeptnEvaluationDefinition` (`open5gs-kpis`). For weighted SLOs: `AnalysisValueTemplate`, then `AnalysisDefinition`, then `Analysis`. Scenarios 2 and 10. |
| 5 | How are SLOs and quality gates represented? | A simple gate: `KeptnEvaluationDefinition` `open5gs-kpis`. A weighted SLO: `AnalysisDefinition` `open5gs-slo` and a one-shot `Analysis` (`examples/analysis-run.yaml`). Scenario 10. |
| 6 | How can execution failures be investigated? | Scenarios 2 and 4: `kubectl describe keptnappversion`, the task Job logs, Keptn events, the Jaeger trace for the app version, and Grafana. See [troubleshooting.md](troubleshooting.md). |
| 7 | What happens when a quality gate is not satisfied? | Scenario 2. The app version is marked failed and promotion is skipped. Keptn does not roll back by itself: the `kpi-guard` task requests a Git rollback through GitHub `workflow_dispatch`, and Flux applies the rollback commit. Scenario 3 shows the loop guard when the rollback does not help. |
| 8 | Which responsibilities belong to Keptn and which remain with external tools? | Scenarios 5, 7, 8 and 9, and the responsibility table in [architecture.md](architecture.md#who-owns-what). Keptn owns lifecycle tasks and gates around a deployment. Flux applies. Git is the source of truth and the rollback mechanism. Prometheus holds the data. Alertmanager watches after the release window. |
| 9 | What would be required to integrate Keptn into a real delivery pipeline? | The `promote` task and the `keptn-promote` workflow, the GitHub workflows, the multi-stage layout (`clusters/<stage>/apps.yaml`), and Keptn's [multi-stage delivery guide](https://keptn.sh/stable/docs/guides/multi-stage-application-delivery/). See [architecture.md](architecture.md#adding-a-second-stage). |

## Launch control and mission control

The hackathon material splits the work into launch control and mission control:

| Phase | Analogy | Owner in this lab |
|---|---|---|
| Release checks: traffic, KPIs, SLO gate, rollback request | Launch control (continuous deployment) | Keptn tasks and evaluations |
| Watching the running system after the release window | Mission control (continuous operations) | Prometheus rules and Alertmanager, through `alert-relay`, requesting the same Git rollback |
| Applying any change, including a rollback | Ground systems | Flux, from Git |

## Hackathon Use-Case One

Use-Case One, "Automate Post-Deployment Functional and Performance Verification for 5GC
Software", maps onto the lab like this:

| Use-case step | Lab implementation |
|---|---|
| 1. Trigger functional tests after the GitOps rollout | The `traffic-burst` Keptn task: gNB restart, UE re-registration, PDU sessions and user-plane pings |
| 2. Evaluate 5GC KPIs (session establishment rate, setup success %, packet delivery) | The `kpi-guard` soak and the `open5gs-kpis` evaluation; the `open5gs-slo` Analysis for weighted SLOs |
| 3. Automated judgment and GitOps fallback | A failed gate dispatches `keptn-rollback`; the rollback commit lands in Git; Flux applies it; promotion is skipped |

Notes for the use-case text:

- **Keptn cannot hold a release back once it is deployed.** Post-deployment tasks run after the
  new pods are live; only pre-deployment tasks can keep pods from starting. The fallback is
  therefore a Git rollback, which is what this lab does.
- **"PDN session" should read "PDU session".** PDN is the 4G term.
- **"Packet delivery" is measured as UPF PDU sessions.** Open5GS 2.8.0 exports the N3 GTP-U
  packet counter `fivegs_ep_n3_gtp_indatapktn3upf` but never increments it, so the lab uses
  `fivegs_upffunction_upf_sessionnbr` as its user-plane KPI. See
  [observability.md](observability.md#open5gs-kpis).

## Open question for the hackathon sandbox

Keptn objects (app context, task definitions, evaluations) normally live in the workload's
namespace, and the hackathon sandbox's 5G core namespaces are closed to participants. Decide one of these
before the hackathon:

- Keep the Keptn objects in a namespace participants can write to, and check what Keptn allows
  in [Allocating namespaces for Keptn resources](https://keptn.sh/stable/docs/installation/configuration/namespace-resources/).
- The 5GC operator applies the participants' Keptn objects through Git.
- The 5G core vendor grants write access to the Keptn CRDs only in its namespaces. The `lab-keptn-author`
  role in [security.md](security.md#personas) is exactly that scope.

Moving the lab to the hackathon sandbox means changing:

- the post-renderer targets in `apps/open5gs/helmrelease-open5gs.yaml` (or the operator adds the
  `keptn.sh/*` labels and annotations),
- the PromQL in the KeptnMetrics, the AnalysisValueTemplates, `kpi-guard` and the alert rules,
- the traffic task, which triggers the sandbox's commercial traffic generator instead of UERANSIM,
- the Git repository Flux watches.

The README section [Swapping the 5G core](../README.md#8-swapping-the-5g-core) lists the files.
