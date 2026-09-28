<!--
==============================================================================
RUNNER SECURITY MODEL
==============================================================================
-->

# Security

<!--
==============================================================================
WHY SELF-HOSTED RUNNERS NEED TIGHTER SCOPING THAN JENKINS
==============================================================================
-->

## Why Self-Hosted Runners Need Tighter Scoping Than Jenkins

A self-hosted GitHub Actions runner executes whatever workflow YAML the
registering repository (or organisation) grants it, including workflow
changes proposed in a pull request unless the repository requires approval
for first-time or all outside contributors. Jenkins jobs are defined and
gated centrally by JCasC and the shared pipeline library; a self-hosted
runner has no equivalent central gate by default. This is a larger blast
radius risk on a shared, resource-constrained host than Jenkins carries
today, and must be mitigated explicitly.

<!--
==============================================================================
MANDATORY SCOPING RULES
==============================================================================
-->

## Mandatory Scoping Rules

- Only register these runners against **private repositories**.
- Every repository that uses these runners must require approval for
  workflow runs from outside collaborators (GitHub repository setting:
  *Require approval for all outside collaborators*).
- Runners run in **ephemeral** mode (`--ephemeral`): one job per registration,
  then the runner deregisters and the container exits. A compromised job
  cannot persist across jobs or exfiltrate a live runner token for reuse.
- The Docker socket is mounted only into these two runner containers -
  no other service on `platform` shares it.
- `runner-deploy` and `runner-validate` are separate containers with separate
  resource caps; a compromised or runaway validate job cannot exhaust the
  resources reserved for deploy pipelines, and vice versa.

<!--
==============================================================================
CREDENTIAL HANDLING
==============================================================================
-->

## Credential Handling

- The GitHub token used to mint registration tokens is a fine-grained,
  short-lived credential, stored as a root-only host file and mounted as a
  Docker secret readable only by the non-root container user - the same
  pattern `jenkins-controller-automation` already uses for its GitHub token.
- The token is scoped to the minimum permission required:
  `administration:write` for repository-level registration, or
  `organization_self_hosted_runners:write` for organisation-level
  registration. It must never be granted broader repository or organisation
  permissions.
- Registration tokens minted from that credential expire in roughly one
  hour and are never persisted to disk; they exist only in the entrypoint
  process's memory for the duration of `config.sh`.
- Secrets are never logged. `scripts/entrypoint.sh` and `scripts/manage.sh`
  must not print token values, even at increased verbosity.

<!--
==============================================================================
NEVER DO THIS
==============================================================================
-->

## Never Do This

- Never register a runner against a public repository or a repository that
  accepts unreviewed pull requests from forks.
- Never disable ephemeral mode to "save on registration overhead" - the
  resulting persistent runner becomes a standing target across every job it
  ever executes.
- Never widen the GitHub token's scope beyond runner registration to work
  around an unrelated permission error; fix the actual permission instead.
