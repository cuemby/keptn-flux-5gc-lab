# Observability

kube-prometheus-stack (Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter),
the OpenTelemetry Collector and Jaeger v2, all in namespace `observability`. Open them with
`make ui` (`scripts/ui.sh`):

| UI | Local address | Service |
|---|---|---|
| Grafana | http://127.0.0.1:3000 | `kube-prometheus-stack-grafana` (user `admin`, password in Secret `observability/grafana-admin`) |
| Prometheus | http://127.0.0.1:9090 | `kube-prometheus-stack-prometheus` |
| Alertmanager | http://127.0.0.1:9093 | `kube-prometheus-stack-alertmanager` |
| Jaeger | http://127.0.0.1:16686 | `jaeger` (only with the optional tracing part) |

```bash
kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

In-cluster Prometheus, as used by Keptn: `http://kube-prometheus-stack-prometheus.observability.svc:9090`.

## What each tool answers

| Question | Tool | Signal |
|---|---|---|
| Is the 5G core healthy? | Grafana "Open5GS KPIs" | AMF registration success, SMF PDU session success, UPF PDU sessions, registered UEs vs UPF sessions |
| What did this release do? | Jaeger | One trace per Keptn app version, with spans for the workloads, the tasks (`traffic-burst`, `kpi-guard`), the evaluation and the promotion |
| Why didn't Flux apply my commit? | Grafana "Flux Cluster Stats" and "Flux Control Plane"; alert `FluxReconciliationFailing` | `gotk_resource_info{ready="False"}` (from kube-state-metrics), controller metrics |
| Deploy frequency and failure rate | Grafana "Keptn Applications", "Keptn Workloads", "Keptn Metrics" | Keptn lifecycle-operator metrics, through the OTel Collector |
| Did something break after the release window? | Alertmanager | `Open5GSDegradedAfterRelease` (routed to `alert-relay`) |

## Open5GS KPIs

Open5GS exports 3GPP TS 28.552 style metrics on the AMF, SMF and UPF metrics endpoints; the
chart's ServiceMonitors are enabled in `apps/open5gs/values/open5gs-good.yaml`. The NSSF exports
no metrics, so it is judged through registration and PDU session success.

| KPI | Metric | Used by |
|---|---|---|
| Initial registration requests and successes | `fivegs_amffunction_rm_reginitreq`, `fivegs_amffunction_rm_reginitsucc` | kpi-guard, KeptnMetric `amf-reg-success-ratio`, Analysis `amf-reg-success`, alerts |
| Registered UEs | `fivegs_amffunction_rm_registeredsubnbr` | KeptnMetric `amf-registered-subscribers`, alert `UPFNoUserPlaneTraffic` |
| PDU session creation requests and successes | `fivegs_smffunction_sm_pdusessioncreationreq`, `fivegs_smffunction_sm_pdusessioncreationsucc` | kpi-guard, KeptnMetric `smf-pdu-success-ratio`, Analysis `smf-pdu-success`, alert |
| PDU sessions on the UPF | `fivegs_upffunction_upf_sessionnbr` | kpi-guard, KeptnMetric `upf-sessions`, Analysis `upf-sessions`, alert `UPFNoUserPlaneTraffic` |

**Not used: the N3 packet counter.** Open5GS 2.8.0 exports `fivegs_ep_n3_gtp_indatapktn3upf`
(and `...outdatapktn3upf`) but never increments them: they stayed at 0 while UE pings through the
UPF passed. The lab's user-plane KPI is therefore the number of PDU sessions the UPF holds.

### The small-count rule

With the lab's two UEs, a 2- or 5-minute window holds only a handful of registrations. Every
2 minutes `traffic-pulse` restarts the UEs, which aborts one or two registrations ("UplinkNASTransport
on stale NG context" in the AMF log); on their own those read 0.57 to 0.75. A real fault fails
every retry. So every success ratio in the lab (kpi-guard, the KeptnMetrics, the
AnalysisValueTemplates and the three ratio alerts) counts as low only when **at least 3 requests
failed** in the window (requests minus successes). Otherwise the ratio reads as 1. Numerators
default to 0, so a fresh SMF with no success series reads 0 rather than 1.

## Keptn metrics and gates

`apps/open5gs/keptn/metrics.yaml` (KeptnMetrics, fetched every 15 s through the `prometheus`
KeptnMetricsProvider):

| KeptnMetric | Query (simplified) | Evaluation target in `open5gs-kpis` |
|---|---|---|
| `amf-reg-success-ratio` | registration successes / requests over 5m, read as 1 with fewer than 3 failures | `>0.95` |
| `smf-pdu-success-ratio` | PDU session successes / requests over 5m, read as 1 with fewer than 3 failures | `>0.95` |
| `amf-registered-subscribers` | `sum(fivegs_amffunction_rm_registeredsubnbr)` | `>0` |
| `upf-sessions` | `sum(fivegs_upffunction_upf_sessionnbr)` | `>0` |

`apps/open5gs/keptn/analysis/` (the weighted SLO, `open5gs-slo`):

| AnalysisValueTemplate | Query | Failure | Warning | Weight |
|---|---|---|---|---|
| `amf-reg-success` (key objective) | registration ratio over `{{.window}}`, small-count rule | `< 0.95` | `< 0.99` | 2 |
| `smf-pdu-success` | PDU session ratio over `{{.window}}`, small-count rule | `< 0.95` | `< 0.99` | 2 |
| `upf-sessions` | `quantile_over_time(0.5, sum(fivegs_upffunction_upf_sessionnbr)[{{.window}}:])` | `< 1` | | 1 |

The analysis passes at 90 % of the total score and warns at 75 %. A failing key objective fails
the whole analysis. `upf-sessions` is the median of the summed UPF sessions over the window: at
least 1 means the UPF held sessions for at least half the window, which tolerates the gaps while
`traffic-pulse` re-registers the UEs, and summing per step first keeps an old UPF pod's series
from masking a new UPF with no sessions. Measured on the GitHub runner: 5/5 on the healthy lab;
2/5 (fail) during the fault, with `smf-pdu-success` and `upf-sessions` failing.

**Analysis timeframe in Keptn v2.5.0.** The metrics operator's Prometheus provider runs a range
query over the Analysis timeframe and keeps the first point. With `timeframe: { recent: 10m }` and
`args: { window: "5m" }`, the Analysis therefore describes the 5-minute window that ended about
10 minutes before the Analysis was created, not the last 5 minutes. To judge a change, create the
Analysis at least 15 minutes after it (the e2e `slo` step waits until the fault is 16 minutes old).

## kpi-guard

`kpi-guard` (Deno) and `kpi-guard-py` (Python, standard library only) are the same task. Their
parameters (`apps/open5gs/keptn/task-kpi-guard*.yaml`):

| Parameter | Value | Meaning |
|---|---|---|
| `trafficWaitSeconds` | 780 | Wait this long for registration requests in a 2m window. On the first release after a bootstrap UERANSIM does not exist yet. No traffic by then: exit 1 as "no traffic", no breach, no rollback. |
| `warmupSeconds` | 180 | After traffic appears, wait out `traffic-burst`'s gNB and UE restarts and the SMF-UPF re-association, so the 2m windows only see the new release. |
| `soakSeconds` | 300 | Watch the KPIs for 5 minutes. |
| `pollSeconds` | 30 | One sample every 30 s. |
| `minRegSuccess` | 0.95 | Registration success ratio threshold. |
| `minPduSuccess` | 0.95 | PDU session success ratio threshold. |
| `minFailedRequests` | 3 | A low ratio is a breach only with at least this many failed requests in the 2m window. |

A sample breaches when:

- the registration ratio is below `minRegSuccess` and at least 3 registrations failed; or
- the SMF saw PDU session requests, the PDU ratio is below `minPduSuccess` and at least 3 failed; or
- the UPF holds no PDU session.

A Prometheus query that fails is logged and read as NaN, which also counts as a breach. Two
consecutive breaching samples end the soak and dispatch `keptn-rollback.yaml` with
`{stage, appVersion, reason, source: keptn}`; the task then exits 1. If GitHub rejects the
dispatch, the log says "rollback dispatch FAILED" with the response body. The task timeout is 25
minutes.

## Alert rules

`infrastructure/observability/monitors/alert-rules.yaml`:

| Alert | Condition | For | Labels |
|---|---|---|---|
| `AMFRegistrationSuccessLow` | registration ratio over 5m `< 0.95`, at least 3 failures | 5m | `severity: warning` |
| `SMFPduSessionSuccessLow` | PDU session ratio over 5m `< 0.95`, at least 3 failures | 5m | `severity: warning` |
| `UPFNoUserPlaneTraffic` | registered UEs `> 0` and UPF sessions `== 0` | 10m | `severity: warning` |
| `Open5GSDegradedAfterRelease` | registration ratio over 10m `< 0.90`, at least 3 failures | 15m | `severity: critical`, `action: rollback` |
| `FluxReconciliationFailing` | `gotk_resource_info{ready="False", suspended!="true"}` | 10m | `severity: warning` |

Alertmanager routes `action="rollback"` to the `keptn-rollback` receiver (webhook
`http://alert-relay.open5gs.svc:8080/alert`, `send_resolved: false`, `repeat_interval: 1h`);
everything else goes to a `null` receiver. Add your own receivers in
`infrastructure/observability/kube-prometheus-stack.yaml`.

`FluxReconciliationFailing` uses `gotk_resource_info`, which kube-state-metrics builds from the
Flux objects (custom resource state, after `fluxcd/flux2-monitoring-example`). The Flux
controllers no longer export `gotk_reconcile_condition`.

## Traces and Keptn metrics

```
Keptn lifecycle operator ── OTLP gRPC :4317 ──► otel-collector ── OTLP ──► Jaeger (traces)
lifecycle-operator-metrics-service:2222 ◄── scrape (job="otel-collector") ── otel-collector :8889 ◄── Prometheus
```

- `platform/keptn/config/keptn-config.yaml` sets `OTelCollectorUrl` to
  `otel-collector.observability.svc.cluster.local:4317`. Restart the lifecycle operator after
  changing it: `kubectl -n keptn-system rollout restart deployment/lifecycle-operator`.
- Keptn v2.5.0 exposes its own metrics in Prometheus format on port 2222. The collector scrapes
  them as `job="otel-collector"`, which Keptn's Grafana dashboards query, and re-exports them on
  port 8889; a ServiceMonitor scrapes 8888 (collector telemetry) and 8889.
- Jaeger 2.20.0 is all-in-one with in-memory storage (20000 traces at most), so traces are lost on
  restart. Grafana has a `Jaeger` data source.
- In Jaeger, pick the Keptn lifecycle operator's service and look for the trace of the app
  version (`open5gs-<hash>`, as shown by `kubectl get keptnappversions -n open5gs`).

## Dashboards

ConfigMaps labelled `grafana_dashboard: "1"`, from `infrastructure/observability/dashboards/`:
"Open5GS KPIs" (written for the lab), "Flux Cluster Stats" and "Flux Control Plane" (from the Flux
monitoring example), and "Keptn Applications", "Keptn Workloads" and "Keptn Metrics" (from
`keptn/lifecycle-toolkit`, with their data source UIDs mapped to `prometheus` and `jaeger`).

## Sizing (light profile)

| Component | Requests | Limit |
|---|---|---|
| Prometheus | 100m, 384Mi | 1Gi; retention 1 day or 1 GB on an emptyDir |
| Grafana | 50m, 128Mi | 384Mi |
| Alertmanager | 10m, 32Mi | 128Mi |
| prometheus-operator | 20m, 64Mi | 256Mi |
| kube-state-metrics | 10m, 48Mi | 192Mi |
| OTel Collector | 25m, 96Mi | 256Mi |
| Jaeger (optional) | 20m, 64Mi | 512Mi |

Kind runs etcd, the controller manager, the scheduler and kube-proxy bound to localhost, so their
scrapes and default rules are disabled. Raise retention, use a PersistentVolumeClaim and remove the
in-memory Jaeger for anything that lives longer than a lab session.
