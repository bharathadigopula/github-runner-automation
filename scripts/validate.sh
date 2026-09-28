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
  scripts/export-metrics.sh
  scripts/check-latest-versions.sh
  scripts/install-docker.sh
  scripts/manage.sh
  systemd/github-runner-health.service
  systemd/github-runner-health.timer
  systemd/github-runner-metrics.service
  systemd/github-runner-metrics.timer
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
  ! grep -Fq -- '--reuid 1001' "$repository_root/scripts/entrypoint.sh" || \
  ! grep -Fq 'docker_socket_gid' "$repository_root/scripts/entrypoint.sh" || \
  ! grep -Fq 'export HOME=/home/runner' "$repository_root/scripts/entrypoint.sh" || \
  ! grep -Fq 'ENV HOME=/home/runner' "$repository_root/Dockerfile" || \
  ! grep -Fq 'chown -R 1001:1001 /home/runner/_work' "$repository_root/scripts/entrypoint.sh"; then
  printf 'Runners must run ephemeral with a writable workspace and non-root Docker socket access.\n' >&2
  exit 1
fi

if grep -Fq 'GITHUB_TOKEN=' "$repository_root/compose.yaml"; then
  printf 'The GitHub token must be mounted as a Docker secret, not an inline environment value.\n' >&2
  exit 1
fi

if ! grep -Fq "chown root:root \"\$release_path/secrets/github-token\"" "$repository_root/scripts/manage.sh" || \
  ! grep -Fq "chmod 0400 \"\$release_path/secrets/github-token\"" "$repository_root/scripts/manage.sh"; then
  printf 'The long-lived GitHub token must remain readable only by root.\n' >&2
  exit 1
fi

if ! grep -Fq 'systemctl restart github-runner-deploy.service' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'systemctl restart github-runner-validate.service' "$repository_root/scripts/manage.sh"; then
  printf 'Deployments must restart both runner services to activate the selected release.\n' >&2
  exit 1
fi

if ! grep -Fq "GITHUB_RUNNER_BIND_ADDRESS=\$github_runner_bind_address" "$repository_root/scripts/bootstrap.sh"; then
  printf 'The metrics bind address must be forwarded through the versioned bootstrap.\n' >&2
  exit 1
fi

#==============================================================================
# RESOURCE ISOLATION VALIDATION
#==============================================================================

deploy_compose=$(sed -n '/^[[:space:]]*runner-deploy:/,/^[[:space:]]*runner-validate:/p' "$repository_root/compose.yaml")
validate_compose=$(sed -n '/^[[:space:]]*runner-validate:/,/^secrets:/p' "$repository_root/compose.yaml")
deploy_name_definition="RUNNER_NAME: \${RUNNER_NAME_PREFIX:-bharathcloudops-oci-platform}-deploy-\${RUNNER_DEPLOY_SEQUENCE:-01}"
deploy_label_definition="RUNNER_LABELS: \${RUNNER_ORGANISATION_LABEL:-bharathcloudops},\${RUNNER_LOCATION_LABEL:-oci-platform},deploy"
validate_name_definition="RUNNER_NAME: \${RUNNER_NAME_PREFIX:-bharathcloudops-oci-platform}-validate-\${RUNNER_VALIDATE_SEQUENCE:-01}"
validate_label_definition="RUNNER_LABELS: \${RUNNER_ORGANISATION_LABEL:-bharathcloudops},\${RUNNER_LOCATION_LABEL:-oci-platform},validate"
home_definition='HOME: /home/runner'

if ! grep -Fq 'cpus: "0.50"' <<< "$deploy_compose" || \
  ! grep -Fq 'memory: 1024M' <<< "$deploy_compose" || \
  ! grep -Fq 'cpus: "0.30"' <<< "$validate_compose" || \
  ! grep -Fq 'memory: 512M' <<< "$validate_compose"; then
  printf 'Deploy and validate runners must keep their pinned, distinct resource caps.\n' >&2
  exit 1
fi

if ! grep -Fq "$deploy_name_definition" <<< "$deploy_compose" || \
  ! grep -Fq "$deploy_label_definition" <<< "$deploy_compose" || \
  ! grep -Fq "$home_definition" <<< "$deploy_compose" || \
  ! grep -Fq "$validate_name_definition" <<< "$validate_compose" || \
  ! grep -Fq "$validate_label_definition" <<< "$validate_compose" || \
  ! grep -Fq "$home_definition" <<< "$validate_compose"; then
  printf 'Runner labels must distinguish the deploy and validate roles.\n' >&2
  exit 1
fi

if ! grep -Fq 'quay.io/prometheus/node-exporter:v1.12.1' "$repository_root/compose.yaml" || \
  ! grep -Fq 'memory: 32M' "$repository_root/compose.yaml" || \
  ! grep -Fq 'github_runner_online' "$repository_root/scripts/export-metrics.sh"; then
  printf 'Runner monitoring must use the pinned private textfile exporter.\n' >&2
  exit 1
fi

printf 'github_runner_validation=ready\n'
