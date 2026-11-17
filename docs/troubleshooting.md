# Troubleshooting

Start with the layer that owns the problem: Flux (did the change apply?), Keptn (did the release
checks run?), the 5G core (do UEs register?), then GitHub (did the rollback or promotion run?).

`scripts/collect-diagnostics.sh [dir]` dumps Flux objects and controller logs, Keptn objects with
`describe`, task Job logs (including `--previous`), pods, events and every container log in
`open5gs`. It never dumps Secrets.

## Flux

```bash
flux get kustomizations -A
flux get helmreleases -A
flux get sources all -A
flux logs --level=error --since=30m
```

| Symptom | Cause | Fix |
|---|---|---|
| `observability` not Ready for a long time on the first install | kube-prometheus-stack pulls many images; the Kustomization has a 15-minute timeout | Wait, or check `kubectl get pods -n observability` for image pull or memory problems |
| A Kustomization fails with "no matches for kind ..." | A custom resource is in the same Flux Kustomization as the HelmRelease that installs its CRD; Flux's dry-run fails and applies nothing | Put the custom resource in its own Kustomization that depends on (or is health-checked by) the one with the HelmRelease, as `observability-monitors` and `platform-config` do |
| `apps` fails with `RoleBinding/open5gs/keptn-traffic not found` | `flux-apps` lacks `bind` on the Role it creates in the same apply | Keep the `bind` rule in `infrastructure/rbac/flux-apps.yaml` |
| The `validate` workflow fails "release inputs changed without a RELEASE_ID bump" | You changed `apps/open5gs/values/`, a HelmRelease, the apps kustomization or the Open5GS chart sources | Run `scripts/bump-release.sh lab` and commit `clusters/lab/apps.yaml` |
| A HelmRelease is stuck after a failed upgrade | `upgrade.remediation.retries: 0`: rollbacks are Git commits, never silent Helm rollbacks | Fix the values in Git; `flux reconcile helmrelease -n open5gs open5gs --force` if needed |

## Keptn

```bash
kubectl get keptnappversions,keptnworkloadversions -n open5gs
kubectl describe keptnappversion -n open5gs <version>
kubectl get keptntasks -n open5gs
kubectl get events -n open5gs --sort-by=.lastTimestamp | grep -i keptn
kubectl -n keptn-system logs deploy/lifecycle-operator --tail=200
```

| Symptom | Cause | Fix |
|---|---|---|
| No new app version after a commit | Flux did not apply it, `RELEASE_ID` did not change, or the pod template has no `keptn.sh/workload` label | `flux get kustomizations -A`; check `clusters/lab/apps.yaml`; `lab-keptn-version` warnings on the NF Deployments |
| Pods stay `SchedulingGated` | Keptn's scheduling gate waits for pre-deployment checks of a workload version; a pod Keptn should not manage was adopted | Only pods with the `keptn.sh/workload` label should reach the webhook (`platform/keptn/helmrelease.yaml`); check `kubectl get keptnworkloads -n open5gs` lists exactly the four NFs |
| More KeptnApps or workloads than `open5gs` and its four NFs | The webhook `objectSelector` patch is missing | Check `kubectl get mutatingwebhookconfiguration lifecycle-mutating-webhook-configuration -o yaml` |
| `kpi-guard`: "no registration traffic; check UERANSIM and traffic-pulse" | No registrations reached the AMF within 13 minutes | Check UERANSIM (below) and that `traffic-pulse` is not suspended; this does not request a rollback |
| `kpi-guard`: "KPI breach, rollback dispatch FAILED (HTTP 401/404/422)" | Expired or wrong dispatch token, wrong owner or repo in `github-dispatch`, or the workflow file is missing on `main` | Recreate the Secret (below); check that `.github/workflows/keptn-rollback.yaml` is on `main` |
| `kpi-guard`: "prometheus query failed" | Prometheus restarting or unreachable; the query counts as a breach | Check `kubectl get pods -n observability`, NetworkPolicy `allow-prometheus-queries` |
| Task output missing | The Job restarted the failed container in place | `kubectl logs -n open5gs -l job-name=<job> --previous` |
| Promotion never runs | `promotionTasksEnabled` off, or a task or evaluation failed | `kubectl describe keptnappversion`; `platform/keptn/helmrelease.yaml` |
| No Keptn traces in Jaeger | `KeptnConfig` changed without a restart, tracing part disabled, or OTLP blocked | `kubectl -n keptn-system rollout restart deployment/lifecycle-operator`; `flux get kustomizations tracing`; NetworkPolicy `allow-otlp-from-keptn` |
| An Analysis passes during an obvious fault | Keptn v2.5.0 evaluates the window that ended about 10 minutes before the Analysis was created | Create it at least 15 minutes after the change |

Recreate the dispatch Secret without putting the token in your shell history or process list:

```bash
read -rs KEPTN_DISPATCH_TOKEN
jq -cn --arg o "$GITHUB_USER" --arg r keptn-flux-5gc-lab --arg t "$KEPTN_DISPATCH_TOKEN" \
  '{owner:$o, repo:$r, token:$t}' |
  kubectl -n open5gs create secret generic github-dispatch --from-file=SECURE_DATA=/dev/stdin \
    --dry-run=client -o yaml | kubectl apply -f -
```

Rerunning `make bootstrap` with the new token also works: it reuses the cluster, re-applies
`github-dispatch` and keeps the existing Grafana password.

## Open5GS and UERANSIM

```bash
kubectl get pods -n open5gs
kubectl logs -n open5gs deploy/open5gs-amf --tail=100
kubectl logs -n open5gs deploy/ueransim-gnb --tail=50
kubectl logs -n open5gs deploy/ueransim-gnb-ues --tail=50
kubectl exec -n open5gs deploy/ueransim-gnb-ues -- ip addr show uesimtun0
kubectl exec -n open5gs deploy/ueransim-gnb-ues -- ping -I uesimtun0 -c 3 10.45.0.1
```

| Symptom | Cause | Fix |
|---|---|---|
| MongoDB exits at start ("kernel" in its log) | `mongo:8.0.34`, the chart default, refuses to run on Linux kernels 6.19 to 7.0.13 (MongoDB SERVER-121912) | The lab pins `mongo` 7.0.48 in both values files. A volume written by 8.0 cannot be opened by 7.0: delete the MongoDB PVC on an old lab |
| `open5gs-populate` init container `OOMKilled` | `mongosh` peaks at about 205 MiB | The values give `wait-for-mongodb` a 320Mi limit; keep it |
| gNB logs `Association terminated for AMF`; later registrations fail with "AMF selection ... failed" | Every release rolls the AMF and UERANSIM 3.2.6 never redoes NG Setup | `traffic-burst` and `traffic-pulse` restart the gNB before the UEs; to recover by hand: `kubectl rollout restart deploy/ueransim-gnb deploy/ueransim-gnb-ues -n open5gs` |
| UEs registered but no `uesimtun0`; SMF logs "No UPF available" | The SMF is still re-associating PFCP with a restarted UPF; a UE whose PDU session fails does not retry | `traffic-burst` retries up to 3 times; by hand, restart the UE Deployment again |
| AMF log "UplinkNASTransport on stale NG context" | `traffic-pulse` restarts the UEs mid-registration every 2 minutes | Expected; the small-count rule (3 failures) ignores it |
| Pods `Pending` or `OOMKilled` across the lab | Not enough memory for the profile | Use the light profile, drop tracing, close other workloads; see the README profile table |
| UE pods fail with `/dev/net/tun` errors | Not a Linux host or VM, or Pod Security stricter than `privileged` in `open5gs` | Run on Linux; check the namespace labels |

## Observability

| Symptom | Cause | Fix |
|---|---|---|
| Open5GS dashboard empty | ServiceMonitors not picked up, or scrapes blocked | Prometheus UI > Status > Targets; `kubectl get servicemonitors -n open5gs`; NetworkPolicy `allow-prometheus-scrape` |
| N3 packet panels or queries read 0 on a healthy lab | Open5GS 2.8.0 never increments `fivegs_ep_n3_gtp_indatapktn3upf` | Use `fivegs_upffunction_upf_sessionnbr` |
| `UPFNoUserPlaneTraffic` firing | UEs registered but the UPF has no PDU session for 10 minutes | Check the SMF and UPF logs, and the PFCP association |
| Flux dashboards empty | kube-state-metrics custom resource state not configured | Check `gotk_resource_info` in Prometheus |
| Keptn dashboards empty | The collector cannot scrape `lifecycle-operator-metrics-service.keptn-system:2222` | Check the collector logs; the dashboards query `job="otel-collector"` |
| Grafana login fails | Wrong password | `kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' \| base64 -d` |
| `make ui` says "skipped" for Jaeger | The optional tracing part is off | Expected when `tracing.yaml` is not in `clusters/lab/kustomization.yaml` |

## GitHub workflows

| Symptom | Cause | Fix |
|---|---|---|
| `keptn-rollback`: "Nothing to roll back" | The last release commit changed no release input (for example only a new resource and a `RELEASE_ID` bump) | Roll back by hand (`make heal` or a revert), then commit |
| `keptn-rollback`: "Needs a human" | The last release commit is already a rollback and the KPIs still breach | Fix the configuration by hand; the loop guard stops further automatic rollbacks |
| `keptn-rollback`: "Degradation predates the release" | An Alertmanager request less than 15 minutes after a release commit | Expected: the 15-minute alert began before that release |
| `keptn-rollback` push rejected | Branch protection on `main` | Allow `github-actions[bot]` to push to `main` in your fork |
| A workflow is skipped | It was dispatched on a ref other than `main` | Dispatch on `main` |
| `alert-relay` answers 503 "not configured" | No `github-dispatch` Secret | Create it (above) and restart the relay |

## Kind and the host

```bash
kind get clusters
docker stats --no-stream
free -m
```

- Kind needs a cgroup v2 host. On Linux, `scripts/bootstrap.sh` refuses to create a new cluster
  with less available memory than the profile needs (6 GB light, 12 GB full); `SKIP_MEMORY_CHECK=1`
  overrides it.
- Many pods on one node can exhaust inotify watches; raise `fs.inotify.max_user_watches` and
  `fs.inotify.max_user_instances` as the Kind documentation describes.
- `make down` deletes the lab cluster; `scripts/e2e.sh down` deletes the e2e cluster and its
  registry.
