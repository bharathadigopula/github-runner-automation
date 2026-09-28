<!--
==============================================================================
GITHUB RUNNER AUTOMATION
==============================================================================
-->

# GitHub Runner Automation

Deploy two lightweight, ephemeral self-hosted GitHub Actions runners on the same
one-OCPU, 6 GB `platform` host that previously ran the Jenkins controller and
its single build agent, with a pinned container image, systemd lifecycle
management, and explicit recovery operations. This repository is the
replacement path for `jenkins-controller-automation`; both stacks run in
parallel until every managed pipeline is proven on the new runners.

<!--
==============================================================================
WHY TWO RUNNERS, NOT ONE
==============================================================================
-->

## Why Two Runners, Not One

Jenkins today runs with exactly one executor (`numExecutors: 1` on the
`platform` agent), so every job across every repository already queues
serially. A single self-hosted runner reproduces that behaviour at a fraction
of the memory cost. A second, smaller runner is only affordable *because*
runners are lightweight compared with Jenkins' fixed 2 GB agent container -
see [`docs/architecture.md`](docs/architecture.md) for the full resource
comparison.

| Runner | Labels | Purpose | Resource cap |
| --- | --- | --- | --- |
| `bharathcloudops-oci-platform-deploy-01` | `bharathcloudops`, `oci-platform`, `deploy` | Terraform apply, container publish, deploy, backup pipelines - anything that mutates production | 0.50 CPU, 1024 MB |
| `bharathcloudops-oci-platform-validate-01` | `bharathcloudops`, `oci-platform`, `validate` | Lint, ShellCheck, `terraform validate`/`plan`, unit tests, repository validation | 0.30 CPU, 512 MB |

Runner names follow `bharathcloudops-<cloud>-<server>-<role>-<sequence>`. The
cloud and server segments identify the OCI `platform` host, the role is `deploy` or `validate`, and the
two-digit sequence leaves room for future capacity without renaming existing
runners. For example, a second validation runner on the same host is
`bharathcloudops-oci-platform-validate-02`.

Infra-mutating workflows must additionally declare a GitHub Actions
`concurrency:` group (for example `deploy-${{ inputs.environment }}`) so only
one mutating job ever runs regardless of runner count. The runner split
prevents fast validation checks from queueing behind a long-running deploy;
the `concurrency:` group is the actual safety lock, not the runner count.

<!--
==============================================================================
RUNNER PROFILE
==============================================================================
-->

## Runner Profile

| Setting | Default |
| --- | --- |
| Runner image | `ghcr.io/actions/actions-runner:2.337.0` |
| Docker Engine and CLI | `29.8.1` |
| containerd | `2.3.6` |
| Docker Buildx | `0.37.1` |
| Docker Compose | `5.5.1` |
| Runner mode | `--ephemeral` (one job per registration, then re-registers) |
| `runner-deploy` limit | 0.50 CPU and 1024 MB memory |
| `runner-validate` limit | 0.30 CPU and 512 MB memory |
| Combined worst case | 0.80 CPU and 1536 MB memory (versus Jenkins' fixed 1.20 CPU / 4096 MB) |

A private node-exporter endpoint adds a 0.02 CPU / 32 MB cap and exposes OCI
`platform` host capacity plus runner API state to the existing Prometheus
instance. It binds only to `GITHUB_RUNNER_BIND_ADDRESS`, which defaults to
loopback; deployments may set a private RFC1918 address, but must never
publish port `9101` publicly.

Both runners are stateless between jobs. There is no `JENKINS_HOME` equivalent
to back up; a fresh ephemeral workspace is created and discarded per job, so
this repository has no backup or restore operations.

<!--
==============================================================================
REGISTRATION SCOPE
==============================================================================
-->

## Registration Scope

GitHub only allows organisation-wide runner groups (one runner shared across
many repositories) under a **GitHub Organization**. Personal-account
repositories can only register
**repository-level** runners - one registration per repository, even though
the same two containers can still serve multiple repositories sequentially by
being re-registered, or by running one container pair per repository.

This automation supports both modes through `GITHUB_SCOPE`:

| `GITHUB_SCOPE` | `GITHUB_TARGET` | Effect |
| --- | --- | --- |
| `repo` (default) | `owner/repository` | Registers against a single repository |
| `org` | `organization` | Registers against an organisation-wide runner group (requires migrating the affected repositories into a GitHub Organization first) |

Until an organisation migration is approved, deploy one `runner-deploy` /
`runner-validate` pair per repository that needs to leave Jenkins, reusing the
same pinned image and systemd units with a different `GITHUB_TARGET`.

<!--
==============================================================================
SECURITY MODEL
==============================================================================
-->

## Security Model

- Runners are **ephemeral**: `config.sh --ephemeral` deregisters the runner
  after exactly one job, limiting the blast radius of a compromised job.
- Runners must only ever be registered against private repositories that do
  not accept workflow runs from forked pull requests without maintainer
  approval - a self-hosted runner executes whatever workflow YAML the
  registering repository grants it.
- The GitHub token used to mint registration tokens is a fine-grained,
  short-lived credential stored as a root-only host file and mounted as a
  Docker secret, readable only by the non-root container user, exactly as
  `jenkins-controller-automation` handles its GitHub token today.
- Each container mints its own short-lived registration token at start-up
  through the GitHub REST API rather than reusing a token passed in at
  deploy time, so the token cannot go stale across restarts or upgrades.
- The Docker socket is mounted only into these runner containers, never into
  any other service on `platform`.

<!--
==============================================================================
VALIDATION AND DRY RUN
==============================================================================
-->

## Validate And Dry Run

These commands do not mutate the host:

```bash
shellcheck scripts/*.sh
bash scripts/validate.sh
bash scripts/manage.sh dry-run
bash scripts/install-docker.sh dry-run
```

<!--
==============================================================================
VERSIONED DEPLOYMENT
==============================================================================
-->

## Versioned Deployment

`bootstrap.sh` stays below the OCI Run Command 4,096-byte payload limit,
matching the pattern used by `jenkins-controller-automation`. It downloads an
immutable semantic-version archive, validates it, installs pinned Docker
packages only for `deploy`, and invokes the lifecycle manager.

```bash
bash scripts/bootstrap.sh \
  dry-run \
  owner/github-runner-automation \
  v1.0.0 \
  repo \
  owner/github-pipeline-templates \
  ""
```

Use `deploy` explicitly and append the secret-manager JSON as the final
argument for mutation:

```json
{"github_token":"replace-with-fine-grained-token"}
```

Use a fine-grained GitHub token scoped only to
`administration:write` (repository) or
`organization_self_hosted_runners:write` (organisation) on the target.

<!--
==============================================================================
LIFECYCLE OPERATIONS
==============================================================================
-->

## Operations

| Action | Mutation | Result |
| --- | --- | --- |
| `validate` | No | Checks pinned images, Compose, and systemd units |
| `dry-run` | No | Validates and reports the release path |
| `deploy` | Yes | Builds and starts both runners through systemd |
| `upgrade` | Yes | Deploys a new release and retains the prior release |
| `verify` | No | Checks both runner containers are running, resource caps are applied, and each runner is `online` and `idle` in the GitHub API |
| `status` | No | Reports runner versions, Compose state, and systemd/timer state; exits nonzero for an inactive component |
| `recover` | Yes | Restarts a runner that has gone offline or stuck busy beyond the health watchdog threshold |

See [`docs/operations.md`](docs/operations.md) for the full rollout, parallel-run,
and Jenkins decommission sequence.

<!--
==============================================================================
DOCUMENTATION
==============================================================================
-->

## Documentation

- [`docs/architecture.md`](docs/architecture.md) - host placement, resource
  comparison against Jenkins, and the concurrency model.
- [`docs/operations.md`](docs/operations.md) - lifecycle actions, registration
  token flow, rollout and cutover sequence.
- [`docs/security.md`](docs/security.md) - runner scope restrictions, secret
  handling, and ephemeral-mode rationale.

<!--
==============================================================================
RECOVERY BOUNDARY
==============================================================================
-->

## Recovery Boundary

Like Jenkins, these runners cannot be their own only bootstrap mechanism.
Preserve the versioned GitHub Actions workflow in `.github/workflows/validate.yaml`
as an external recovery path that can:

1. Provision or recover the host.
2. Retrieve this repository by immutable tag.
3. Retrieve the secret bundle from a secret manager.
4. Execute `dry-run` and then `deploy` through the cloud remote-command service.

Until both runners have executed every managed pipeline successfully at least
once, `jenkins-controller-automation` remains the production pipeline
executor; do not stop the Jenkins compose stack until that parallel-run
period is complete and explicitly approved.
