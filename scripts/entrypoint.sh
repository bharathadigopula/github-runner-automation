#!/usr/bin/env bash

#==============================================================================
# EPHEMERAL RUNNER ENTRYPOINT
#==============================================================================

#==============================================================================
# SHELL SAFETY
#==============================================================================

set -Eeuo pipefail
trap 'printf "github_runner_failure=line_%s\n" "$LINENO"' ERR

#==============================================================================
# RUNTIME INPUTS
#==============================================================================

github_api_url="${GITHUB_API_URL:-https://api.github.com}"
github_scope="${GITHUB_SCOPE:?GITHUB_SCOPE is required}"
github_target="${GITHUB_TARGET:?GITHUB_TARGET is required}"
runner_labels="${RUNNER_LABELS:?RUNNER_LABELS is required}"
runner_name="${RUNNER_NAME:?RUNNER_NAME is required}"
token_file="/run/secrets/github_token"
docker_socket_gid=$(stat --format '%g' /var/run/docker.sock)
export HOME=/home/runner

cleanup_runner_state() {
  find /home/runner/_work -mindepth 1 -maxdepth 1 ! -name _tool -exec rm -rf -- {} +
  if [[ ",$runner_labels," == *,deploy,* ]]; then
    DOCKER_CONFIG=/tmp/github-runner-docker-cleanup docker builder prune --all --force >/dev/null 2>&1 || true
    DOCKER_CONFIG=/tmp/github-runner-docker-cleanup docker image prune --all --force >/dev/null 2>&1 || true
    rm -rf /tmp/github-runner-docker-cleanup
  fi
  install -d -o 1001 -g 1001 -m 0700 /home/runner/.docker
  chown -R 1001:1001 /home/runner/.docker
}

if [[ ! -r "$token_file" ]]; then
  printf 'GitHub token secret is not mounted.\n' >&2
  exit 1
fi

install -d -o 1001 -g 1001 -m 0755 /home/runner/_work /home/runner/_work/_tool
cleanup_runner_state
chown -R 1001:1001 /home/runner/_work

#==============================================================================
# REGISTRATION ENDPOINT SELECTION
#==============================================================================

case "$github_scope" in
  repo)
    registration_endpoint="$github_api_url/repos/$github_target/actions/runners/registration-token"
    runner_url="https://github.com/$github_target"
    ;;
  org)
    registration_endpoint="$github_api_url/orgs/$github_target/actions/runners/registration-token"
    runner_url="https://github.com/$github_target"
    ;;
  *)
    printf 'GITHUB_SCOPE must be "repo" or "org".\n' >&2
    exit 1
    ;;
esac

#==============================================================================
# SHORT-LIVED REGISTRATION TOKEN
#==============================================================================

registration_token=$(curl --fail --silent --show-error \
  --request POST \
  --header "Authorization: Bearer $(<"$token_file")" \
  --header 'Accept: application/vnd.github+json' \
  --header 'X-GitHub-Api-Version: 2022-11-28' \
  "$registration_endpoint" | jq -r '.token')

if [[ -z "$registration_token" || "$registration_token" == "null" ]]; then
  printf 'GitHub did not return a runner registration token.\n' >&2
  exit 1
fi

#==============================================================================
# EPHEMERAL REGISTRATION AND EXECUTION
#==============================================================================

setpriv --reuid 1001 --regid 1001 --groups "$docker_socket_gid" --no-new-privs ./config.sh \
  --unattended \
  --ephemeral \
  --url "$runner_url" \
  --token "$registration_token" \
  --name "$runner_name" \
  --labels "$runner_labels" \
  --work "_work"

# shellcheck disable=SC2317,SC2329
cleanup() {
  setpriv --reuid 1001 --regid 1001 --groups "$docker_socket_gid" --no-new-privs ./config.sh remove --token "$registration_token" >/dev/null 2>&1 || true
  rm -f .credentials .credentials_rsaparams .runner
  cleanup_runner_state
}
trap cleanup EXIT

set +e
setpriv --reuid 1001 --regid 1001 --groups "$docker_socket_gid" --no-new-privs ./run.sh
runner_exit_code=$?
set -e
exit "$runner_exit_code"
