<!--
==============================================================================
RUNNER ARCHITECTURE
==============================================================================
-->

# Architecture

<!--
==============================================================================
HOST PLACEMENT
==============================================================================
-->

## Host Placement

Both runners deploy to the `platform` host, the same Always Free
`VM.Standard.A1.Flex` instance that runs Jenkins today:

| Host | Shape | OCPU | RAM | Boot volume |
| --- | --- | --- | --- | --- |
| `platform` | `VM.Standard.A1.Flex` | 1 | 6 GB | 70 GB |

`platform` also hosts Backstage. No new compute is provisioned; this
repository only changes what runs inside the existing OCPU/RAM budget.

<!--
==============================================================================
RESOURCE COMPARISON
==============================================================================
-->

## Resource Comparison

| | Jenkins (current) | GitHub runners (this repository) |
| --- | --- | --- |
| Always-on RAM reserved | 4096 MB capped (`jenkins` 2048 MB + `platform-agent` 2048 MB); realistically 1.5-2.5 GB resident at idle | ~50-100 MB idle per runner, ~1536 MB capped worst case across both during an active job |
| Always-on CPU reserved | 1.20 OCPU capped, oversubscribing the host's single OCPU | ~0 at idle; 0.80 OCPU capped worst case across both during an active job |
| Executors | 1 (controller has 0, `platform-agent` has 1) | 2 processes, each handling exactly one job at a time |
| Persistent state | `JENKINS_HOME` volume (job history, plugin cache, workspace caches) growing against the 70 GB boot volume | None; ephemeral workspace per job, torn down after each run |
| Freed headroom for Backstage | - | ~1.5-2.5 GB RAM and most CPU time back, versus today |

<!--
==============================================================================
CONCURRENCY MODEL
==============================================================================
-->

## Concurrency Model

The host still has only **one physical OCPU**. Running two runners does not
create two OCPUs - a heavy Terraform apply and a lint job "in parallel" still
time-slice the same core. The benefit is not raw speed, it is that a fast
validation job no longer queues behind a long-running deploy job the way it
would with Jenkins' single shared executor.

Infra-mutating pipelines must not rely on runner count as their only
safeguard. Every workflow that runs on `runner-deploy` must declare an
explicit GitHub Actions concurrency group, for example:

```yaml
concurrency:
  group: deploy-${{ inputs.environment }}
  cancel-in-progress: false
```

This reproduces (and makes explicit) the implicit single-executor lock
Jenkins provides today, independent of how many runner processes exist.

<!--
==============================================================================
STATELESS DESIGN
==============================================================================
-->

## Stateless Design

Runners are ephemeral (`config.sh --ephemeral`): each container registers,
executes exactly one job, deregisters, and exits. Docker Compose's restart
policy brings up a fresh container and registration for the next job. There
is no equivalent to `JENKINS_HOME` to back up or restore, and no
`jenkins-controller-backup.timer` equivalent is required.
