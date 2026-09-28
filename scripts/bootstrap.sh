#!/usr/bin/env bash

#==============================================================================
# VERSIONED GITHUB RUNNER BOOTSTRAP
#==============================================================================

#==============================================================================
# SHELL SAFETY
#==============================================================================

set -euo pipefail

#==============================================================================
# BOOTSTRAP INPUTS
#==============================================================================

action="${1:-validate}"
automation_repository="${2:-}"
automation_ref="${3:-}"
github_scope="${4:-repo}"
github_target="${5:-}"
github_runner_bind_address="${6:-127.0.0.1}"
secret_bundle="${7:-}"

case "$action" in
  validate|dry-run|deploy|verify|status|recover) ;;
  *) printf 'Unsupported GitHub runner lifecycle action.\n' >&2; exit 2 ;;
esac

if [[ ! "$automation_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  printf 'A GitHub owner/repository value is required.\n' >&2
  exit 1
fi

if [[ ! "$automation_ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'An immutable semantic version tag is required.\n' >&2
  exit 1
fi

if [[ "$github_scope" != "repo" && "$github_scope" != "org" ]]; then
  printf 'GITHUB_SCOPE must be "repo" or "org".\n' >&2
  exit 1
fi

if [[ ! "$github_runner_bind_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  printf 'GITHUB_RUNNER_BIND_ADDRESS must be an IPv4 address.\n' >&2
  exit 1
fi

IFS=. read -r first_octet second_octet third_octet fourth_octet <<< "$github_runner_bind_address"
for octet in "$first_octet" "$second_octet" "$third_octet" "$fourth_octet"; do
  if (( 10#$octet > 255 )); then
    printf 'GITHUB_RUNNER_BIND_ADDRESS contains an invalid IPv4 octet.\n' >&2
    exit 1
  fi
done

if [[ "$action" != "validate" && "$action" != "dry-run" ]]; then
  if [[ -z "$github_target" ]]; then
    printf 'A registration target is required for %s.\n' "$action" >&2
    exit 1
  fi
  if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true; then
    printf '%s requires non-interactive sudo access.\n' "$action" >&2
    exit 1
  fi
fi

#==============================================================================
# VERSIONED SOURCE DOWNLOAD
#==============================================================================

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT
curl --fail --location --silent --show-error \
  "https://github.com/$automation_repository/archive/refs/tags/$automation_ref.tar.gz" \
  --output "$temporary_directory/automation.tar.gz"
mkdir "$temporary_directory/source"
tar --extract --gzip --file "$temporary_directory/automation.tar.gz" \
  --directory "$temporary_directory/source" --strip-components=1

#==============================================================================
# VERSIONED AUTOMATION EXECUTION
#==============================================================================

manage_script="$temporary_directory/source/scripts/manage.sh"
manage_environment=(
  env
  "AUTOMATION_REF=$automation_ref"
  "GITHUB_RUNNER_BIND_ADDRESS=$github_runner_bind_address"
  "GITHUB_SCOPE=$github_scope"
  "GITHUB_TARGET=$github_target"
)

if [[ "$action" == "deploy" ]]; then
  sudo -n bash "$temporary_directory/source/scripts/install-docker.sh" "$action"
  printf 'github_runner_deploy=ready\n'
  sudo -n "${manage_environment[@]}" bash "$manage_script" "$action" "$secret_bundle"
elif [[ "$action" == "validate" || "$action" == "dry-run" ]]; then
  bash "$temporary_directory/source/scripts/install-docker.sh" "$action"
  "${manage_environment[@]}" bash "$manage_script" "$action"
else
  sudo -n "${manage_environment[@]}" bash "$manage_script" "$action"
fi
