#!/usr/bin/env bash

#==============================================================================
# UPSTREAM VERSION DRIFT CHECK
#==============================================================================

#==============================================================================
# SHELL SAFETY
#==============================================================================

set -euo pipefail

#==============================================================================
# REPOSITORY VERSION PINS
#==============================================================================

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runner_version=$(sed -n 's/^FROM ghcr.io\/actions\/actions-runner://p' "$repository_root/Dockerfile")
node_exporter_version=$(sed -n 's/^[[:space:]]*image: quay.io\/prometheus\/node-exporter:v//p' "$repository_root/compose.yaml")
checkout_version=$(sed -n 's/^[[:space:]]*- uses: actions\/checkout@v//p' "$repository_root/.github/workflows/validate.yaml")
containerd_version=$(grep '^containerd_version=' "$repository_root/scripts/install-docker.sh" | awk -F':-' '{ value = $2; sub(/}"$/, "", value); print value }')
docker_buildx_version=$(grep '^docker_buildx_version=' "$repository_root/scripts/install-docker.sh" | awk -F':-' '{ value = $2; sub(/}"$/, "", value); print value }')
docker_compose_version=$(grep '^docker_compose_version=' "$repository_root/scripts/install-docker.sh" | awk -F':-' '{ value = $2; sub(/}"$/, "", value); print value }')
docker_engine_version=$(grep '^docker_engine_version=' "$repository_root/scripts/install-docker.sh" | awk -F':-' '{ value = $2; sub(/}"$/, "", value); print value }')

#==============================================================================
# GITHUB RELEASE CHECKS
#==============================================================================

latest_release() {
  local repository="$1"

  curl --fail --silent --show-error \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/$repository/releases/latest" | jq -r '.tag_name | ltrimstr("v")'
}

assert_current() {
  local component="$1"
  local pinned="$2"
  local latest="$3"

  if [[ "$pinned" != "$latest" ]]; then
    printf '%s is stale: pinned=%s latest=%s\n' "$component" "$pinned" "$latest" >&2
    return 1
  fi
  printf '%s=%s\n' "$component" "$pinned"
}

assert_current github_runner "$runner_version" "$(latest_release actions/runner)"
assert_current node_exporter "$node_exporter_version" "$(latest_release prometheus/node_exporter)"
assert_current actions_checkout "$checkout_version" "$(latest_release actions/checkout)"

#==============================================================================
# DOCKER NOBLE PACKAGE CHECKS
#==============================================================================

check_docker_architecture() {
  local architecture="$1"
  local package_index

  package_index=$(curl --fail --silent --show-error \
    "https://download.docker.com/linux/ubuntu/dists/noble/stable/binary-$architecture/Packages.gz" | gzip -dc)

  latest_package() {
    local package_name="$1"

    awk -v expected_package="$package_name" '
      $1 == "Package:" { package = $2 }
      package == expected_package && $1 == "Version:" { print $2; package = "" }
    ' <<< "$package_index" | sort -Vr | head -n 1
  }

  assert_current "docker_engine_$architecture" "$docker_engine_version" "$(latest_package docker-ce)"
  assert_current "containerd_$architecture" "$containerd_version" "$(latest_package containerd.io)"
  assert_current "docker_buildx_$architecture" "$docker_buildx_version" "$(latest_package docker-buildx-plugin)"
  assert_current "docker_compose_$architecture" "$docker_compose_version" "$(latest_package docker-compose-plugin)"
}

check_docker_architecture arm64
check_docker_architecture amd64
printf 'github_runner_version_check=ready\n'
