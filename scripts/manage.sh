#!/usr/bin/env bash

#==============================================================================
# GITHUB RUNNER LIFECYCLE
#==============================================================================

#==============================================================================
# SHELL SAFETY
#==============================================================================

set -Eeuo pipefail
trap 'printf "github_runner_failure=line_%s\n" "$LINENO"' ERR

#==============================================================================
# LIFECYCLE INPUTS
#==============================================================================

action="${1:-validate}"
secret_bundle="${2:-}"
source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
install_root="${GITHUB_RUNNER_INSTALL_ROOT:-/opt/github-runner}"
release_ref="${AUTOMATION_REF:-local}"
release_key=${release_ref//[^a-zA-Z0-9._-]/-}
release_path="$install_root/releases/$release_key"

#==============================================================================
# STACK VALIDATION
#==============================================================================

validate_stack() {
  bash "$source_root/scripts/validate.sh"
}

#==============================================================================
# ROOT PRIVILEGE VALIDATION
#==============================================================================

require_root() {
  if (( EUID != 0 )); then
    printf '%s must run as root.\n' "$action" >&2
    exit 1
  fi
}

#==============================================================================
# RELEASE ENVIRONMENT
#==============================================================================

write_environment() {
  cat > "$release_path/.env" <<EOF
GITHUB_API_URL=${GITHUB_API_URL:-https://api.github.com}
GITHUB_RUNNER_BIND_ADDRESS=${GITHUB_RUNNER_BIND_ADDRESS:-127.0.0.1}
GITHUB_RUNNER_VERSION=${GITHUB_RUNNER_VERSION:-2.337.0}
GITHUB_SCOPE=${GITHUB_SCOPE:-repo}
GITHUB_TARGET=${GITHUB_TARGET:?GITHUB_TARGET is required}
GITHUB_TOKEN_FILE=./secrets/github-token
RUNNER_LOCATION_LABEL=${RUNNER_LOCATION_LABEL:-oci-platform}
RUNNER_NAME_PREFIX=${RUNNER_NAME_PREFIX:-bharathcloudops-oci-platform}
RUNNER_ORGANISATION_LABEL=${RUNNER_ORGANISATION_LABEL:-bharathcloudops}
EOF
  chmod 0600 "$release_path/.env"
}

#==============================================================================
# RUNNER DEPLOYMENT
#==============================================================================

deploy_runners() {
  require_root
  if ! jq -e '
    type == "object" and
    (.github_token | type == "string" and length >= 20 and (contains("\n") | not))
  ' <<< "$secret_bundle" >/dev/null; then
    printf 'Secret bundle must contain a fine-grained GitHub token.\n' >&2
    exit 1
  fi

  validate_stack
  docker compose version >/dev/null
  install -d -m 0755 "$install_root/releases"
  rm -rf "$release_path"
  install -d -m 0755 "$release_path"
  cp -a "$source_root/." "$release_path/"
  install -d -m 0700 "$release_path/secrets"
  jq -r '.github_token' <<< "$secret_bundle" > "$release_path/secrets/github-token"
  chown root:root "$release_path/secrets/github-token"
  chmod 0400 "$release_path/secrets/github-token"
  write_environment

  if [[ -L "$install_root/current" ]]; then
    ln -sfn "$(readlink -f "$install_root/current")" "$install_root/previous"
  fi

  ln -sfn "$release_path" "$install_root/current"
  install -m 0644 "$release_path/systemd/github-runner-deploy.service" /etc/systemd/system/github-runner-deploy.service
  install -m 0644 "$release_path/systemd/github-runner-validate.service" /etc/systemd/system/github-runner-validate.service
  install -m 0644 "$release_path/systemd/github-runner-health.service" /etc/systemd/system/github-runner-health.service
  install -m 0644 "$release_path/systemd/github-runner-health.timer" /etc/systemd/system/github-runner-health.timer
  install -m 0644 "$release_path/systemd/github-runner-metrics.service" /etc/systemd/system/github-runner-metrics.service
  install -m 0644 "$release_path/systemd/github-runner-metrics.timer" /etc/systemd/system/github-runner-metrics.timer
  systemctl daemon-reload
  install -d -m 0755 /var/lib/github-runner-metrics
  systemctl enable github-runner-deploy.service
  systemctl enable github-runner-validate.service
  systemctl restart github-runner-deploy.service
  systemctl restart github-runner-validate.service
  docker compose --project-directory "$install_root/current" --file "$install_root/current/compose.yaml" up --detach runner-metrics
  systemctl enable --now github-runner-health.timer
  systemctl enable --now github-runner-metrics.timer
  printf 'github_runner_deploy=ready\n'
  verify_runners
}

#==============================================================================
# RUNNER HEALTH VERIFICATION
#==============================================================================

runner_service_running() {
  local service_name="$1"

  systemctl is-active --quiet "$service_name"
}

verify_runners() {
  if ! runner_service_running github-runner-deploy.service || \
    ! runner_service_running github-runner-validate.service; then
    printf 'One or both runner services are not active.\n' >&2
    systemctl status --no-pager github-runner-deploy.service github-runner-validate.service >&2 || true
    return 1
  fi

  if ! docker inspect --format 'runner_deploy={{.HostConfig.NanoCpus}}/{{.HostConfig.Memory}}' \
    "$(docker compose --project-directory "$install_root/current" --file "$install_root/current/compose.yaml" ps --quiet runner-deploy)" >/dev/null; then
    printf 'Unable to inspect the deploy runner container.\n' >&2
    return 1
  fi

  printf 'github_runner_verify=ready\n'
}

#==============================================================================
# RUNNER STATUS
#==============================================================================

status_runners() {
  local component
  local exit_code=0

  for component in github-runner-deploy.service github-runner-validate.service github-runner-health.timer github-runner-metrics.timer; do
    if runner_service_running "$component"; then
      printf '%s=active\n' "$component"
    else
      printf '%s=inactive\n' "$component"
      exit_code=1
    fi
  done

  df --human-readable / /var/lib/docker
  docker system df
  docker compose --project-directory "$install_root/current" --file "$install_root/current/compose.yaml" ps || exit_code=1
  if (( exit_code == 0 )); then
    printf 'github_runner_status=ready\n'
  fi
  return "$exit_code"
}

#==============================================================================
# RUNNER RECOVERY
#==============================================================================

recover_runners() {
  require_root
  local component

  for component in github-runner-deploy.service github-runner-validate.service; do
    printf 'github_runner_restarting=%s\n' "$component"
    systemctl restart "$component"
  done

  verify_runners
  printf 'github_runner_recover=ready\n'
}

#==============================================================================
# LIFECYCLE DISPATCH
#==============================================================================

case "$action" in
  validate) validate_stack ;;
  dry-run) validate_stack; printf 'github_runner_dry_run=ready\n' ;;
  deploy|upgrade) deploy_runners ;;
  verify) verify_runners ;;
  status) status_runners ;;
  recover) recover_runners ;;
  *)
    printf 'Unsupported GitHub runner lifecycle action: %s\n' "$action" >&2
    exit 2
    ;;
esac
