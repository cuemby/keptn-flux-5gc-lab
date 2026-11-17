# Scenarios

Eleven scenarios. Each ends with the numbers of the [learning goals](learning-goals.md) it
answers. Run them on a lab bootstrapped from your fork (`make bootstrap`); most of them commit
and push to your fork, so Flux picks the change up within a minute.

| # | Scenario | Steps | Expected | Goals |
|---|---|---|---|---|
| 1 | Happy path | `make bump`, then commit and push | AMF, SMF, NSSF and UPF roll; traffic-burst runs; kpi-guard passes; the evaluation passes; promote runs. One green Jaeger trace. | 1, 2, 3 |
| 2 | Bad config, Keptn rollback | `make fault` | PDU sessions fail, so the UPF holds no session. kpi-guard dispatches a rollback; a rollback commit appears; Flux applies it; the next release passes. | 4, 6, 7 |
| 3 | Loop guard | Commit a bad `open5gs-good.yaml` without a bump, then `NO_PUSH=1 make fault` and `git push` | One rollback, then "Needs a human" | 7 |
| 4 | No traffic | Suspend `traffic-pulse` and remove `traffic-burst` from the app context, bump, commit and push | kpi-guard fails with "no registration traffic"; no rollback | 6 |
| 5 | Flux failure | Commit an invalid HelmRelease | `FluxReconciliationFailing`; Keptn never starts | 8 |
| 6 | RBAC | `scripts/rbac-check.sh` (or `add-user.sh alice lab:keptn-authors` and the matrix) | Every check matches [security.md](security.md#check-matrix) | 3 |
| 7 | NetworkPolicy | curl the AMF metrics port from `default` | Denied; scrapes, Keptn queries and the alert relay still work | 8 |
| 8 | Admission | A pod with `busybox:latest` in `open5gs` | Warning | 8 |
| 9 | Mission control | Release a change to a release input (not a `RELEASE_ID`-only bump); once it passed and is at least 15 minutes old, break the core directly with `kubectl` (outside Git) | Keptn is no longer watching; after 15 minutes `Open5GSDegradedAfterRelease` fires and alert-relay dispatches; the rollback commit produces a new Helm release, which brings the UDM back | 8 |
| 10 | SLO analysis | `kubectl create -f examples/analysis-run.yaml` during healthy traffic, then during `make fault` | Pass, then fail, with per-objective scores | 4, 5 |
| 11 | Python runtime | Swap `kpi-guard` for `kpi-guard-py` in the app context, then repeat scenario 2 | Same outcome; compare the two task definitions | 2 |

## Where each scenario is tested

| # | Tested where | Notes |
|---|---|---|
| 1 | `e2e` workflow (every pull request; full profile and Cilium nightly), `scripts/e2e.sh` locally, live sandbox check | The CI run checks the promotion *request* at a GitHub API mock; the live check runs `keptn-promote.yaml` on GitHub. |
| 2 | `e2e` workflow, `scripts/e2e.sh`, live sandbox check | CI checks the rollback *request* at the mock; the live check runs `keptn-rollback.yaml`, Flux applies its commit and the next release passes. |
| 3 | live sandbox check only | Needs the rollback workflow to push real commits. |
| 4 | not automated | Run it by hand. |
| 5 | not automated | Run it by hand. |
| 6 | `e2e` workflow (`rbac` step), `scripts/e2e.sh` | 59 matrix checks plus a real `add-user.sh` certificate. |
| 7 | `e2e` workflow, `kind-extended` job with Cilium (nightly and on dispatch) | Also checks SCTP: Cilium `enable-sctp`, NGAP on SCTP/38412, registered UEs. |
| 8 | offline only (a standalone API server in the platform slice's checks) | Run it by hand on Kind. |
| 9 | live sandbox check only | Needs the dispatch token and a 15-minute degradation. |
| 10 | `e2e` workflow (`happy` and `slo` steps) | Healthy 5/5, fault 2/5. |
| 11 | `e2e` workflow (`python` step) | |

[VERIFY.md](../VERIFY.md) lists the runs and what is still open.

## Before you start

```bash
flux get kustomizations -A                      # all Ready
kubectl get keptnappversions -n open5gs         # the first app version Succeeded
make ui                                         # in a second terminal
```

The first app version after a bootstrap is expected to succeed: `traffic-burst` waits for
UERANSIM, which Flux installs after Open5GS, and `kpi-guard` waits for registration traffic before
it starts. A release takes about 10 to 15 minutes from push to verdict: Flux picks up the commit,
the NFs roll, then `kpi-guard` waits for traffic, warms up for 3 minutes and soaks for 5.

Watch a release:

```bash
kubectl get keptnappversions,keptnworkloadversions -n open5gs -w
kubectl get keptntasks -n open5gs
JOB=$(kubectl get keptntasks -n open5gs <kpi-guard task> -o jsonpath='{.status.jobName}')
kubectl logs -n open5gs -l job-name=$JOB --tail=-1 -f
```

## 1. Happy path

```bash
make bump                                          # scripts/bump-release.sh lab
git commit -am "chore: bump RELEASE_ID" && git push
```

`scripts/bump-release.sh lab` writes a new UTC timestamp `RELEASE_ID` into
`clusters/lab/apps.yaml`. It does not commit; `make fault` and `make heal` do. Flux substitutes it into
`keptn.sh/version` on the four NF pod templates, the Deployments roll, and Keptn creates a new
`KeptnAppVersion` `open5gs-<hash>`.

Expected:

- `traffic-burst` restarts the gNB, then the UEs, and pings the UPF gateway `10.45.0.1` through
  `uesimtun0`.
- `kpi-guard` logs one JSON line per sample (`req`, `reg`, `regFailed`, `pduReq`, `pdu`,
  `pduFailed`, `sessions`) and ends with "KPIs healthy for the full soak window".
- The evaluation `open5gs-kpis` passes; the `promote` task dispatches `keptn-promote.yaml`, which is
  a no-op with a single stage.
- `kubectl get keptnappversion -n open5gs` shows the new version `Succeeded`; Jaeger has one trace
  for it.

Which questions did this answer? 1 (what triggers Keptn), 2 (how tasks are defined), 3 (how
Keptn objects relate to Kubernetes objects; see [keptn-primer.md](keptn-primer.md#follow-one-release)).

## 2. Bad config, Keptn rollback

```bash
make fault
```

`scripts/inject-fault.sh` points the `open5gs-values` ConfigMap at
`apps/open5gs/values/open5gs-fault-slice.yaml`, bumps `RELEASE_ID`, commits and pushes. The fault
values are identical to the good ones except the SMF's UE pool, which serves DNN `ims` while the
UEs ask for `internet`. NG Setup and registration keep working; PDU session setup fails, so the UPF
holds no session.

Expected:

- `kpi-guard` sees about 0 PDU successes over many requests and no UPF session; two breaching
  samples in a row make it dispatch `keptn-rollback.yaml` (`source: keptn`) and exit 1 with
  "KPI breach, rollback requested via Git".
- The app version is `Failed`; the evaluation and promotion are skipped.
- On GitHub, `keptn-rollback` restores the values selection from before the fault, bumps
  `RELEASE_ID` and pushes a `[keptn-rollback]` commit. Flux applies it and the next app version
  passes. `make heal` does the same by hand. Run `git pull` before your next change: the rollback
  commit was written on GitHub.

Investigate the failure (question 6):

```bash
kubectl describe keptnappversion -n open5gs <failed version>
kubectl get events -n open5gs --sort-by=.lastTimestamp | grep -i keptn
kubectl logs -n open5gs -l job-name=<kpi-guard job> --tail=-1   # add --previous if the container restarted
```

Then open the app version's trace in Jaeger and the "Open5GS KPIs" dashboard in Grafana.

Which questions did this answer? 4 (metrics in evaluations), 6 (investigating failures), 7 (what
happens when a gate fails: the version is failed, promotion is skipped, and the rollback is a Git
commit, not a Keptn action).

## 3. Loop guard

Make the good config bad too, so a rollback cannot help:

```bash
cp apps/open5gs/values/open5gs-fault-slice.yaml apps/open5gs/values/open5gs-good.yaml
git commit -am "make the good config bad too"   # no make bump
NO_PUSH=1 make fault                             # commits the fault release without pushing
git push
```

Pushing the bad `open5gs-good.yaml` together with the fault means Flux never applies it as a
release of its own, whose rollback would restore the healthy `open5gs-good.yaml` from the commit
before it.

Expected: one `[keptn-rollback]` commit. The release that rollback produces fails too, and its
`kpi-guard` asks for a rollback of a different app version within 15 minutes, so
`keptn-rollback` stops in "Needs a human" and pushes nothing. A request more than 15 minutes after
a rollback stops the same way. Fix the good values by hand afterwards.

Which question did this answer? 7.

## 4. No traffic

Remove `traffic-burst` from `postDeploymentTasks` in `apps/open5gs/keptn/app-context.yaml`, and
suspend `traffic-pulse` in Git (`spec.suspend: true` in `apps/open5gs/traffic/traffic-pulse.yaml`)
so Flux keeps it suspended. Run `make bump`, then commit and push.

Expected: after `trafficWaitSeconds` (13 minutes) `kpi-guard` exits 1 with "no registration
traffic; check UERANSIM and traffic-pulse". The app version fails, but no breach is counted and no
rollback is requested: missing traffic is a test-setup problem, not evidence against the release.
Revert both changes afterwards.

Which question did this answer? 6.

## 5. Flux failure

Commit a HelmRelease that cannot apply, for example an unknown field in
`apps/open5gs/helmrelease-ueransim.yaml`, with a `RELEASE_ID` bump (`make bump`), and push it.

Expected: the `apps` Kustomization goes not Ready (`flux get kustomizations -A`), after 10 minutes
`FluxReconciliationFailing` fires, and no new Keptn app version appears: Keptn only reacts to pods
that changed, so a change Flux never applied is invisible to it. Revert the commit.

Which question did this answer? 8 (Flux applies; Keptn only sees what was applied).

## 6. RBAC

```bash
scripts/rbac-check.sh            # matrix + a real add-user.sh certificate
scripts/add-user.sh alice lab:keptn-authors
KUBECONFIG=users/alice.kubeconfig kubectl get keptnappversions -n open5gs   # allowed
KUBECONFIG=users/alice.kubeconfig kubectl get secrets -n open5gs            # Forbidden
```

Expected: every check passes. See [security.md](security.md#check-matrix).

Which question did this answer? 3 (task Jobs run as `keptn-task-runner` or `keptn-traffic`, not
as the author).

## 7. NetworkPolicy

```bash
kubectl run np-test -n default --rm -it --restart=Never \
  --image=alpine/k8s:1.37.2@sha256:7a82aeefea3d554a43a8676b137f2b88bae6c1fe11c13862b191b3a086cc28c0 -- \
  curl -sS -m 5 http://open5gs-amf-metrics.open5gs.svc:9090/metrics      # times out
```

Check the AMF metrics Service name with `kubectl get svc -n open5gs`. Expected: denied from
`default`, while Prometheus targets in `open5gs` stay up, the KeptnMetrics keep updating and
Alertmanager still reaches `alert-relay`. Both kindnet and Cilium enforce the policies; with
`CNI=cilium` the e2e step also checks that NGAP runs over SCTP.

Which question did this answer? 8.

## 8. Admission

```bash
kubectl -n open5gs run test --image=busybox:latest --restart=Never --dry-run=server
```

Expected: the request is admitted with a warning from `lab-pinned-images`. The Deny-mode
policies are a different matter: try to create, as a Keptn author, a container task with
`privileged: true` and it is rejected by `lab-keptn-task-identity`.

Which question did this answer? 8.

## 9. Mission control

First release a change to a release input, so the rollback has a previous state to restore. A
`RELEASE_ID`-only release (a plain `make bump`) leaves nothing to roll back, and the workflow fails
with "Nothing to roll back"; a `[keptn-rollback]` commit as the last release (after scenario 2 or
3) makes it stop in "Needs a human". For example:

```bash
echo "# scenario 9 release" >> apps/open5gs/values/open5gs-good.yaml
make bump
git commit -am "release before the scenario 9 break"
git push
```

Wait until that release passes and is at least 15 minutes old: an Alertmanager request less than
15 minutes after a release commit is ignored as "Degradation predates the release". Then break the
core outside Git, for example as a 5GC operator:

```bash
kubectl -n open5gs scale deployment/open5gs-udm --replicas=0
```

Expected: Keptn is no longer watching (the release window closed). Registrations fail, and after
15 minutes `Open5GSDegradedAfterRelease` fires. Alertmanager posts it to `alert-relay`, which
dispatches `keptn-rollback.yaml` (`source: alertmanager`). The rollback commit restores the release
inputs from before your release and bumps `RELEASE_ID`. Flux applies it, helm-controller upgrades
`open5gs` to a new Helm release, and that upgrade brings the UDM back to its declared replica count.

Which question did this answer? 8 (Keptn launch control vs Alertmanager mission control; Flux
applies both).

## 10. SLO analysis

```bash
kubectl create -f examples/analysis-run.yaml
kubectl get analyses -n open5gs -w
kubectl get analysis -n open5gs <name> -o jsonpath='{.status}' | jq
```

Run it once during healthy traffic (expected: pass, 5/5), then at least 15 minutes after
`make fault` (expected: fail, 2/5, with `smf-pdu-success` and `upf-sessions` failing and
`amf-reg-success` passing). Keptn v2.5.0 evaluates the window that ended about 10 minutes before
the Analysis was created; see [observability.md](observability.md#keptn-metrics-and-gates).

A good hackathon exercise is turning the analysis into the post-deployment gate: a small task that
creates an `Analysis` and waits for its result, or a replacement for the evaluation.

Which questions did this answer? 4, 5.

## 11. Python runtime

In `apps/open5gs/keptn/app-context.yaml`, change `postDeploymentTasks` to
`[traffic-burst, kpi-guard-py]`, run `make bump`, commit and push, then repeat scenario 2.

Expected: the same outcome. The healthy release passes and is promoted; the fault makes
`kpi-guard-py` request the rollback. Compare the two task definitions: the same parameters and
breach rules, `deno` vs `python` runtime, `DATA`, `SECURE_DATA` and `KEPTN_CONTEXT` read from the
environment in both.

Which question did this answer? 2.
