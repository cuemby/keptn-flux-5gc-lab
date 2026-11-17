# References

Curated from the hackathon's project reference list, with broken links fixed and missing pages
added. Many online sources still cover **Keptn v1**; the hackathon and this lab use **Keptn v2.5.0**
(the Kubernetes-native lifecycle toolkit, Helm chart `keptn` 0.11.0). The original list had two
errors, both replaced below: the PodTatoHead link (a malformed GitLab URL) and the "Keptn Metrics
Operator" link (it pointed to the releases page).

Every link was checked on 2026-11-17.

## Keptn

- [CNCF project page: Keptn](https://www.cncf.io/projects/keptn/)
- [Keptn lifecycle toolkit repository](https://github.com/keptn/lifecycle-toolkit) (source, releases, Grafana dashboards, runtimes)
- [Getting started: lifecycle management](https://keptn.sh/stable/docs/getting-started/lifecycle-management/)
- [Lifecycle operator](https://keptn.sh/stable/docs/components/lifecycle-operator/), [KeptnApp and KeptnWorkload](https://keptn.sh/stable/docs/components/lifecycle-operator/keptn-apps/) and [Deployment flow](https://keptn.sh/stable/docs/components/lifecycle-operator/deployment-flow/)
- [Integrate Keptn with your applications](https://keptn.sh/stable/docs/guides/integrate/) and [Auto app discovery](https://keptn.sh/stable/docs/guides/auto-app-discovery/)
- [Deployment tasks](https://keptn.sh/stable/docs/guides/tasks/) and the [KeptnTaskDefinition reference](https://keptn.sh/stable/docs/reference/crd-reference/taskdefinition/) (Deno, Python and container runtimes)
- [Evaluations](https://keptn.sh/stable/docs/guides/evaluations/) and [KeptnEvaluationDefinition](https://keptn.sh/stable/docs/reference/crd-reference/evaluationdefinition/)
- [KeptnMetricsProvider](https://keptn.sh/stable/docs/reference/crd-reference/metricsprovider/) (providers: Prometheus, Thanos, Cortex, Dynatrace, DQL, Datadog, Elastic) and [KeptnMetric](https://keptn.sh/stable/docs/reference/crd-reference/metric/)
- [Analysis with Keptn](https://keptn.sh/stable/docs/guides/slo/), [Analysis](https://keptn.sh/stable/docs/reference/crd-reference/analysis/), [AnalysisDefinition](https://keptn.sh/stable/docs/reference/crd-reference/analysisdefinition/) and [AnalysisValueTemplate](https://keptn.sh/stable/docs/reference/crd-reference/analysisvaluetemplate/)
- [KeptnApp](https://keptn.sh/stable/docs/reference/crd-reference/app/) and [KeptnAppContext](https://keptn.sh/stable/docs/reference/crd-reference/appcontext/)
- [KeptnConfig](https://keptn.sh/stable/docs/reference/crd-reference/config/) (OTel collector URL)
- [Multi-stage application delivery](https://keptn.sh/stable/docs/guides/multi-stage-application-delivery/) (promotion tasks through GitHub workflows)
- [OpenTelemetry observability](https://keptn.sh/stable/docs/guides/otel/), [DORA metrics](https://keptn.sh/stable/docs/guides/dora/) and [Redeploy/restart an application](https://keptn.sh/stable/docs/guides/restart-application-deployment/)
- [Use case: Keptn + Flux](https://keptn.sh/stable/docs/use-cases/flux/)
- [Allocating namespaces for Keptn resources](https://keptn.sh/stable/docs/installation/configuration/namespace-resources/) and [Restricting monitored namespaces](https://keptn.sh/stable/docs/installation/configuration/namespace-keptn/) (relevant to the Mavenir sandbox question in [learning-goals.md](learning-goals.md#open-question-for-the-mavenir-sandbox))
- [PodTatoHead delivery example with Keptn](https://github.com/podtato-head/podtato-head/blob/main/delivery/keptn/README.md)

## Deno and Python runtimes

- [Deno documentation](https://docs.deno.com/runtime/) and [Deno on GitHub](https://github.com/denoland/deno). Deno is sandboxed by default: network and environment access need explicit permission flags (Keptn's runtime passes `--allow-net` and `--allow-env=DATA,SECURE_DATA,KEPTN_CONTEXT`).
- The Python runtime runs standard Python 3 (3.13 in `python-runtime` v1.0.8); `kpi-guard-py` shows the same task without Deno, using only the standard library.

## 5G core and RAN simulator

- [Open5GS documentation](https://open5gs.org/open5gs/docs/) and [Open5GS on GitHub](https://github.com/open5gs/open5gs) (metric names in `src/amf/metrics.c`, `src/smf/metrics.c`, `src/upf/metrics.c`)
- [UERANSIM](https://github.com/aligungr/UERANSIM)
- [Gradiant 5G charts](https://github.com/Gradiant/5g-charts) (the `open5gs` and `ueransim-gnb` charts) and their [Open5GS + UERANSIM tutorial](https://gradiant.github.io/5g-charts/open5gs-ueransim-gnb.html)
- [3GPP TS 28.552](https://www.3gpp.org/DynaReport/28552.htm) (5G performance measurements, the source of the `fivegs_*` names)

## Prometheus, Grafana, OpenTelemetry and Jaeger

- [Prometheus overview](https://prometheus.io/docs/introduction/overview/)
- [Grafana: getting started](https://grafana.com/docs/grafana/latest/fundamentals/getting-started/)
- [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
- [Jaeger 2.20 documentation](https://www.jaegertracing.io/docs/2.20/)
- Open5GS metrics follow 3GPP TS 28.552 naming (`fivegs_amffunction_*`, `fivegs_smffunction_*`, `fivegs_upffunction_*`).

## Flux

- [Flux documentation](https://fluxcd.io/flux/), [Core concepts](https://fluxcd.io/flux/concepts/) and [Flux from end to end](https://fluxcd.io/flux/flux-e2e/)
- [Manage Helm releases](https://fluxcd.io/flux/guides/helmreleases/), including `chartRef` with `OCIRepository`, which this lab uses for OCI charts
- [Kustomize controller](https://fluxcd.io/flux/components/kustomize/) (postBuild substitution, impersonation), [Notification providers](https://fluxcd.io/flux/components/notification/providers/) and [Receivers](https://fluxcd.io/flux/components/notification/receivers/) (webhook instead of polling)
- [Flux monitoring: metrics](https://fluxcd.io/flux/monitoring/metrics/) and the [flux2-monitoring-example](https://github.com/fluxcd/flux2-monitoring-example) (source of the lab's kube-state-metrics configuration and Flux dashboards)
- [Flux architecture overview (ControlPlane)](https://control-plane.io/blog/fluxcd-architecture-overview), useful as a reading guide

## Kubernetes and Kind

- [Kind](https://kind.sigs.k8s.io/) and [kube-network-policies](https://github.com/kubernetes-sigs/kube-network-policies) (NetworkPolicy enforcement in kindnet since Kind v0.24)
- [Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
- [ValidatingAdmissionPolicy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
- [Gateway API](https://gateway-api.sigs.k8s.io/) (the way to expose the UIs; Ingress NGINX is retired)
- [mise](https://mise.jdx.dev/) (installs the pinned toolchain from `mise.toml`)
- [MongoDB SERVER-121912](https://jira.mongodb.org/browse/SERVER-121912) (why the lab pins MongoDB 7.0)

## Git

- [GitHub: managing personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) (use fine-grained tokens scoped to the fork)
- [GitLab: personal access tokens](https://docs.gitlab.com/user/profile/personal_access_tokens/)

## Sylva

- [Sylva project](https://sylvaproject.org/)
