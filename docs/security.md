# Security and RBAC

The lab runs on a laptop, but it is built the way a shared cluster should be: personas with the
least access they need, workload identities with no rights they do not use, Pod Security
Admission, ValidatingAdmissionPolicies, NetworkPolicies, and no secret in Git. The defaults that
are relaxed for the lab are listed at the end.

## Threat model

1. Participants author Keptn objects and read metrics, but cannot change the 5G core outside Git.
2. Flux, the Keptn tasks, the traffic job and the alert relay get only the rights they need.
3. No secret is stored in Git.
4. A leaked dispatch token can only trigger workflows.

Point 1 needs more than RBAC. Keptn task Jobs and metric queries are run by operators, so
Kubernetes never checks whether the author of a `KeptnTaskDefinition` may use the ServiceAccount,
Secrets or privileges the resulting Job gets, or whether the author of a `KeptnMetricsProvider`
or `ServiceMonitor` may read the Secret it references. Three Deny-mode admission policies close
those paths (see [Admission policies](#admission-policies)).

## Personas

Groups come from the client certificate's organisation (`scripts/add-user.sh`) or, on other
clusters, from the OIDC groups claim. Bindings: `infrastructure/rbac/bindings.yaml`.

| Group | Hackathon role | open5gs | observability | other namespaces | Secrets |
|---|---|---|---|---|---|
| `lab:viewers` | Observers | view | view + port-forward | view | none |
| `lab:keptn-authors` | Participants | view; CRUD on Keptn objects (including Analyses); pod logs | view; edit ServiceMonitors, PodMonitors, PrometheusRules and dashboard ConfigMaps; port-forward | view | none |
| `lab:5gc-operators` | 5G core operator | `admin` + Keptn author | as authors | view | open5gs only |
| `lab:platform-admins` | Platform team | cluster-admin | cluster-admin | cluster-admin | all |

Roles (`infrastructure/rbac/`):

- `aggregate-crd-view.yaml` adds the Keptn, Flux and monitoring CRDs to the built-in `view` role.
- `personas.yaml`: `lab-keptn-author` (Keptn app contexts, task and evaluation definitions,
  metrics, providers, analyses, analysis definitions and value templates; `pods/log`),
  `lab-observability-editor` (ServiceMonitors, PodMonitors, PrometheusRules and ConfigMaps) and
  `lab-ui-access` (`pods/portforward` for `scripts/ui.sh`).

`view` never includes Secrets; `admin` in `open5gs` does, for 5GC operators only.

### Adding a user

```bash
scripts/add-user.sh alice lab:keptn-authors     # 7-day client certificate via a CSR
export KUBECONFIG=$PWD/users/alice.kubeconfig    # namespace set to open5gs
kubectl auth whoami
```

The private key never leaves your machine; `users/` is git-ignored. A certificate cannot be
revoked before it expires: remove access sooner by deleting the group binding or, in a lab, by
recreating the cluster. Run the script with `kubectl` connected as a cluster admin.

### Check matrix

`scripts/rbac-check.sh` (scenario 6) runs 59 `kubectl auth can-i` checks with impersonation:
the four personas, a user with no lab group, and the identities `keptn-traffic`,
`keptn-task-runner`, `alert-relay` and `flux-apps`. `scripts/rbac-check.sh add-user` also issues a
real certificate, checks it with `kubectl auth whoami`, `can-i` and real requests, and deletes the
test user's key and kubeconfig. To run single checks by hand:

```bash
A="--as=alice --as-group=lab:keptn-authors"
kubectl auth can-i create analyses.metrics.keptn.sh -n open5gs $A                            # yes
kubectl auth can-i get secrets -n open5gs $A                                                 # no
T="--as=system:serviceaccount:open5gs:keptn-traffic"
kubectl auth can-i patch deployment/ueransim-gnb-ues -n open5gs $T                          # yes
kubectl auth can-i patch deployment/open5gs-amf -n open5gs $T                               # no
kubectl auth can-i get secrets -n open5gs $T                                                # no
kubectl auth can-i create pods --subresource=exec -n open5gs $T                             # yes
```

Subresources need `--subresource`: `kubectl auth can-i create pods/exec` reads `exec` as a pod
name and answers about `pods`.

## Workload identities

| Identity | Namespace | Used by | Permissions |
|---|---|---|---|
| `flux-apps` | open5gs | the `apps` Flux Kustomization and both HelmReleases | `admin` in open5gs; `flux-apps-crds` (HelmReleases, Keptn objects, monitoring objects); `bind` on Role `keptn-traffic` only |
| `keptn-task-runner` | open5gs | `kpi-guard`, `kpi-guard-py`, `promote` | none; token not mounted |
| `keptn-traffic` | open5gs | `traffic-burst` task, `traffic-pulse` CronJob | get, list, watch and patch on Deployments `ueransim-gnb` and `ueransim-gnb-ues`; get and list pods; create `pods/exec` |
| `alert-relay` | open5gs | Alertmanager-to-GitHub relay | none; token not mounted |

`flux-apps` needs `bind` on the `keptn-traffic` Role because the `apps` Kustomization creates the
Role and its RoleBinding in one apply: without it, the API server's escalation check looks the Role
up during Flux's dry-run, before it exists, and the whole apply fails.

`pods/exec` cannot be limited to pods by name. In a lab this is an accepted trade-off; on a
shared cluster, use a UERANSIM image or chart option that generates the traffic itself.

Keptn task Jobs get their ServiceAccount from the task definition (`spec.serviceAccount.name`,
`spec.automountServiceAccountToken.type`), both present in the Keptn 0.11.0 CRDs. The Deno and
Python runtimes are chosen by the lifecycle operator (`ghcr.io/keptn/deno-runtime:v3.0.1`,
`ghcr.io/keptn/python-runtime:v1.0.8`, pinned by digest in `platform/keptn/helmrelease.yaml`).

## Admission policies

`infrastructure/admission/`:

| Policy | Mode | What it does |
|---|---|---|
| `lab-pinned-images` | Warn, Audit | Warns about images with no tag, `:latest` and no digest in the lab namespaces (scenario 8). |
| `lab-keptn-version` | Warn, Audit | Warns when a pod template with `keptn.sh/workload` lacks `keptn.sh/app`, or carries an unsubstituted `${RELEASE_ID}`. |
| `lab-keptn-task-identity` | Deny | For task definitions written by anyone other than Git (`flux-apps`), 5GC operators, platform admins and the Keptn operators: only the `keptn-task-runner` ServiceAccount (or none), only the `github-dispatch` Secret, and for container tasks no `privileged`, no added capabilities, no `allowPrivilegeEscalation: true`, no `runAsUser: 0`, no volume mounts. |
| `lab-keptn-metrics-provider-secret-refs` | Deny | Metrics providers written outside Git may not reference a Secret (`spec.secretKeyRef`), which the metrics operator would send to the provider's `targetServer`. 5GC operators are exempt (they can read open5gs Secrets anyway). |
| `lab-servicemonitor-secret-refs`, `lab-podmonitor-secret-refs` | Deny | Scrape configs written outside Git may not reference Secrets (basic auth, bearer token, authorization, OAuth2, proxy headers, TLS client Secrets) or `bearerTokenFile`, which Prometheus would send to the scrape target. 5GC operators are not exempt: they have no access to observability Secrets. |

The three Deny policies are a security boundary; the two Warn policies are hints. Switch the
Warn bindings to `Deny` on a shared cluster.

## Pod Security

| Namespace | enforce | warn and audit |
|---|---|---|
| `flux-system`, `keptn-system` | baseline | restricted |
| `open5gs`, `observability` | privileged | baseline |

`open5gs` must be privileged because the UPF and the UEs need `NET_ADMIN` and `/dev/net/tun`;
`observability` because of node-exporter. The lab's own workloads run as non-root with read-only
root filesystems and all capabilities dropped where the image allows it: `traffic-pulse` and
`traffic-burst` as UID 65532, `alert-relay` as UID 1993, Jaeger as UID 10001.

## Network policies

`infrastructure/policies/`. Ingress is isolated; egress stays open (the Keptn tasks and the relay
call the GitHub API, the UEs ping through the UPF).

`open5gs`:

- default-deny ingress;
- allow traffic within the namespace (SBI, NGAP over SCTP, PFCP, GTP-U, MongoDB, UERANSIM, task Jobs);
- allow Prometheus from `observability` to scrape;
- allow Alertmanager from `observability` to reach `alert-relay` on 8080.

`observability`:

- default-deny ingress and allow traffic within the namespace;
- Prometheus on 9090 from `keptn-system` (metrics operator) and `open5gs` (kpi-guard);
- OTLP 4317 and 4318 on the collector from `keptn-system`;
- the prometheus-operator admission webhook on 10250 (called by the API server).

Both CNIs enforce these: kindnet ships kube-network-policies since Kind v0.24, and Cilium is the
alternative (`CNI=cilium`). Scenario 7 checks them.

## Secrets

| Secret | Namespace | Created by | Read by |
|---|---|---|---|
| `github-dispatch` (key `SECURE_DATA`: `{"owner","repo","token"}`, optional `"api"`) | open5gs | `scripts/bootstrap.sh` (from stdin, not process arguments) | Keptn task Jobs through `secureParameters`; `alert-relay` (optional: without it the relay answers 503) |
| `grafana-admin` (random password, not rotated on re-run) | observability | `scripts/bootstrap.sh` | Grafana |
| Flux deploy key | flux-system | `flux bootstrap` | source-controller |

None is in Git. For team forks that need Secrets in Git, use SOPS with age.

## GitHub tokens and workflows

| Token | Used by | Permissions (fork only) |
|---|---|---|
| `GITHUB_TOKEN` (bootstrap) | `flux bootstrap`, once | Administration: write, Contents: write. Revoke it afterwards. |
| `KEPTN_DISPATCH_TOKEN` | Keptn tasks, `alert-relay` | Actions: write only |

Workflow hardening:

- Actions pinned by full commit SHA (`make lint` fails on anything else).
- `permissions: {}` at the top level; jobs ask for `contents: write` (rollback, promote) or
  `contents: read` (validate, e2e).
- Inputs passed through `env` and validated (`stage`, `source`, `appVersion`); the free-text
  `reason` is sanitized before it reaches a commit message.
- `keptn-rollback` and `keptn-promote` run only from `refs/heads/main` and are serialized by a
  `concurrency` group. They push to `main` with `GITHUB_TOKEN`, so on a fork with branch protection
  allow `github-actions[bot]` to push.
- `gitleaks` runs on every pull request.

`POST /alert` on `alert-relay` has no authentication: any pod that can reach it can request a
rollback. In the lab only Alertmanager and pods in `open5gs` can, and the workflow's guards limit
what repeated requests do.

## Lab-only defaults to change for shared clusters

- OTLP is sent in plain text inside the cluster.
- Jaeger keeps traces in memory; Prometheus keeps one day on an emptyDir.
- The `open5gs` namespace enforces the `privileged` Pod Security level.
- The traffic job uses `pods/exec` on the UE pods.
- `lab-pinned-images` and `lab-keptn-version` run in Warn and Audit mode.
- NetworkPolicies isolate ingress only; egress stays open.
- `alert-relay` accepts unauthenticated requests from inside the namespace.
- Client certificates instead of OIDC groups; they cannot be revoked before they expire.
