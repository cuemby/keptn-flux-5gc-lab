# Security policy

This repository is a learning lab. It is meant to run on a local Kind cluster or a disposable
test cluster, not in production. Several defaults are deliberately relaxed for a lab and are
listed in the README section "Lab-only defaults to change for shared clusters".

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private vulnerability
reporting instead: on the repository page, open **Security**, then **Report a vulnerability**.

Include what you found, how to reproduce it, and the commit or tag you tested. We aim to
acknowledge reports within five working days.

In scope:

- Manifests, scripts and GitHub Actions workflows in this repository.
- Anything that would let a lab participant change the 5G core outside Git, read Secrets they
  should not see, or escalate privileges beyond the documented personas.
- Anything that leaks a token or credential into Git, logs or CI output.

Out of scope: vulnerabilities in upstream projects (Flux, Keptn, Open5GS, UERANSIM,
kube-prometheus-stack, OpenTelemetry, Jaeger, Kind). Please report those upstream.

## Secrets and tokens

- No secret is stored in Git. `scripts/bootstrap.sh` creates the runtime Secrets
  (`open5gs/github-dispatch`, `observability/grafana-admin`) directly in the cluster, and
  `flux bootstrap` creates the Flux deploy key.
- Use fine-grained GitHub tokens scoped to your fork only:
  - `GITHUB_TOKEN` for `flux bootstrap`: Administration and Contents write. Revoke it after
    bootstrap.
  - `KEPTN_DISPATCH_TOKEN` for Keptn tasks and the alert relay: Actions write only. A leaked
    token can trigger workflows and nothing else.
- For team forks that need Secrets in Git, use SOPS with age; never commit plain Secrets.

## Supply chain

- Container images and Helm charts are pinned to exact versions, and where possible to
  digests. Renovate opens pull requests for updates.
- GitHub Actions are pinned to full commit SHAs, workflows start from `permissions: {}`, and
  `make lint` fails on any unpinned action.
- `gitleaks` runs on every pull request.
