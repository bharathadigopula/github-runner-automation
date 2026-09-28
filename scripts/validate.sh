#!/usr/bin/env bash

#==============================================================================
# GITHUB RUNNER STACK VALIDATION
#==============================================================================

#==============================================================================
# SHELL SAFETY
#==============================================================================

set -euo pipefail

#==============================================================================
# REQUIRED RUNNER FILES
#==============================================================================

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
required_files=(
  .jenkins/pipelines/validate.groovy
  Dockerfile
  compose.yaml
  scripts/entrypoint.sh
  scripts/install-docker.sh
  scripts/manage.sh
  systemd/github-runner-health.service
  systemd/github-runner-health.timer
  systemd/github-runner-deploy.service
  systemd/github-runner-validate.service
)

for required_file in "${required_files[@]}"; do
  if [[ ! -f "$repository_root/$required_file" ]]; then
    printf 'Missing required file: %s\n' "$required_file" >&2
    exit 1
  fi
done

#==============================================================================
# CONTAINER IMAGE VALIDATION
#==============================================================================

if grep -R --line-number --extended-regexp '(FROM|image:)[[:space:]]+[^[:space:]]+:latest([[:space:]]|$)' \
  "$repository_root/Dockerfile" "$repository_root/compose.yaml"; then
  printf 'Container images must use pinned version tags.\n' >&2
  exit 1
fi

#==============================================================================
# EPHEMERAL AND NON-ROOT RUNTIME VALIDATION
#==============================================================================

if ! grep -Fq -- '--ephemeral' "$repository_root/scripts/entrypoint.sh" || \
  ! grep -Fq 'USER runner' "$repository_root/Dockerfile"; then
  printf 'Runners must run ephemeral and as the non-root runner user.\n' >&2
  exit 1
fi

if grep -Fq 'GITHUB_TOKEN=' "$repository_root/compose.yaml"; then
  printf 'The GitHub token must be mounted as a Docker secret, not an inline environment value.\n' >&2
  exit 1
fi

#==============================================================================
# RESOURCE ISOLATION VALIDATION
#==============================================================================

deploy_compose=$(sed -n '/^[[:space:]]*runner-deploy:/,/^[[:space:]]*runner-validate:/p' "$repository_root/compose.yaml")
validate_compose=$(sed -n '/^[[:space:]]*runner-validate:/,/^secrets:/p' "$repository_root/compose.yaml")

if ! grep -Fq 'cpus: "0.50"' <<< "$deploy_compose" || \
  ! grep -Fq 'memory: 1024M' <<< "$deploy_compose" || \
  ! grep -Fq 'cpus: "0.30"' <<< "$validate_compose" || \
  ! grep -Fq 'memory: 512M' <<< "$validate_compose"; then
  printf 'Deploy and validate runners must keep their pinned, distinct resource caps.\n' >&2
  exit 1
fi

if ! grep -Fq 'platform,deploy' <<< "$deploy_compose" || \
  ! grep -Fq 'platform,validate' <<< "$validate_compose"; then
  printf 'Runner labels must distinguish the deploy and validate roles.\n' >&2
  exit 1
fi

printf 'github_runner_validation=ready\n'
