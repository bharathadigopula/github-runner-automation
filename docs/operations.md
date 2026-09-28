<!--
==============================================================================
RUNNER OPERATIONS
==============================================================================
-->

# Operations

<!--
==============================================================================
REGISTRATION TOKEN FLOW
==============================================================================
-->

## Registration Token Flow

GitHub self-hosted runner registration tokens expire roughly one hour after
being minted, so this automation never stores a pre-fetched token. Instead:

1. `scripts/manage.sh deploy` writes the fine-grained GitHub token from the
   secret bundle to a root-only Docker secret file.
2. `scripts/entrypoint.sh`, run as the container's own start-up command, reads
   that secret and calls the GitHub REST API
   (`POST /repos/{owner}/{repo}/actions/runners/registration-token` or the
   `/orgs/{org}/...` equivalent depending on `GITHUB_SCOPE`) to mint a fresh
   registration token every time the container starts.
3. `config.sh --ephemeral --unattended` registers the runner with that fresh
   token, labelled with the runner's role (`deploy` or `validate`) plus
   `platform`.
4. `run.sh` executes exactly one job, then the runner deregisters and the
   container exits; the systemd unit's `Restart=always` starts a new
   container, repeating the cycle.

This means the registration token in the secret bundle only has to be valid
at deploy time, and every subsequent job gets a freshly minted token
automatically - restarts, upgrades, and long idle periods never hit an
expired-token failure.

<!--
==============================================================================
ROLLOUT SEQUENCE
==============================================================================
-->

## Rollout Sequence

1. **Scaffold** (this change): versioned compose/systemd/scripts, no
   production deployment yet.
2. **Deploy alongside Jenkins**: run `scripts/bootstrap.sh deploy` through the
   *existing* Jenkins pipeline, the same way Jenkins deploys every other
   managed service today. Both `runner-deploy` and `runner-validate` start
   next to the running Jenkins controller and agent.
3. **Port pipelines**: move each `.jenkins/pipelines/*.groovy` stage list into
   an equivalent reusable workflow under `github-pipeline-templates`,
   preserving the same checkout / validate / plan / approve / apply gating
   structure stage-for-stage.
4. **Parallel run**: trigger the ported GitHub Actions workflow for a
   repository and confirm it completes successfully at least once before
   changing that repository's required status checks.
5. **Cut over per repository**: update branch protection / required status
   checks from `continuous-integration/jenkins` to the new workflow's check
   name, one repository at a time.
6. **Decommission** (separate, explicitly approved step): once no repository
   depends on Jenkins for a full cycle, stop (not delete) the
   `jenkins-controller-automation` compose stack and reclaim its 4096 MB
   memory cap.

<!--
==============================================================================
LIFECYCLE ACTIONS
==============================================================================
-->

## Lifecycle Actions

| Action | What it does |
| --- | --- |
| `validate` | Confirms required files exist, images are pinned, and runner/agent isolation rules hold (mirrors `jenkins-controller-automation/scripts/validate.sh`) |
| `dry-run` | Runs `validate` and reports the release path without touching the host |
| `deploy` | Installs pinned Docker packages, writes the release under `/opt/github-runner/releases/<ref>`, installs systemd units, starts both runners |
| `upgrade` | Same as `deploy`, but retains the previous release as `/opt/github-runner/previous` for rollback |
| `verify` | Confirms both containers are running, resource caps match the pinned profile, and the GitHub API reports each runner `online` |
| `status` | Reports runner versions, Compose service state, and systemd/timer state |
| `recover` | Restarts a runner that the health timer found offline or stuck busy past the watchdog threshold |

<!--
==============================================================================
DECOMMISSION CHECKLIST
==============================================================================
-->

## Decommission Checklist (Do Not Run Until Explicitly Approved)

- [ ] Every repository's required status check points at the new workflow.
- [ ] Every `.jenkins/pipelines/*.groovy` stage has an equivalent, tested
      GitHub Actions workflow.
- [ ] At least one full deploy pipeline and one full validate pipeline have
      succeeded end-to-end per repository on the new runners.
- [ ] `jenkins-controller-automation`'s compose stack is stopped, not deleted,
      so it remains available as a rollback path for a defined grace period.
