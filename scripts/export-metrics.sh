#!/usr/bin/env bash

#==============================================================================
# RUNNER METRICS EXPORT
#==============================================================================

#==============================================================================
# SHELL SAFETY
#==============================================================================

set -Eeuo pipefail
trap 'printf "github_runner_metrics_failure=line_%s\n" "$LINENO"' ERR

#==============================================================================
# EXPORT INPUTS
#==============================================================================

install_root="${GITHUB_RUNNER_INSTALL_ROOT:-/opt/github-runner}"
textfile_directory="${GITHUB_RUNNER_TEXTFILE_DIRECTORY:-/var/lib/github-runner-metrics}"
token_file="$install_root/current/secrets/github-token"

# shellcheck source=/dev/null
source "$install_root/current/.env"

case "$GITHUB_SCOPE" in
  repo)
    listing_endpoint="$GITHUB_API_URL/repos/$GITHUB_TARGET/actions/runners"
    workflow_runs_endpoint="$GITHUB_API_URL/repos/$GITHUB_TARGET/actions/runs?per_page=100"
    ;;
  org)
    listing_endpoint="$GITHUB_API_URL/orgs/$GITHUB_TARGET/actions/runners"
    workflow_runs_endpoint="$GITHUB_API_URL/orgs/$GITHUB_TARGET/actions/runs?per_page=100"
    ;;
  *) printf 'GITHUB_SCOPE must be "repo" or "org".\n' >&2; exit 1 ;;
esac

if [[ ! -r "$token_file" ]]; then
  printf 'GitHub token file is not readable.\n' >&2
  exit 1
fi

#==============================================================================
# RUNNER STATE RETRIEVAL
#==============================================================================

runners_json=$(curl --fail --silent --show-error \
  --header "Authorization: Bearer $(<"$token_file")" \
  --header 'Accept: application/vnd.github+json' \
  --header 'X-GitHub-Api-Version: 2022-11-28' \
  "$listing_endpoint")
workflow_runs_json=$(curl --fail --silent --show-error \
  --header "Authorization: Bearer $(<"$token_file")" \
  --header 'Accept: application/vnd.github+json' \
  --header 'X-GitHub-Api-Version: 2022-11-28' \
  "$workflow_runs_endpoint")

#==============================================================================
# TEXTFILE COLLECTOR RENDERING
#==============================================================================

install -d -m 0755 "$textfile_directory"
render_path="$textfile_directory/github_runner.prom.$$"

{
  printf '# HELP github_runner_online Whether GitHub reports the runner as online.\n'
  printf '# TYPE github_runner_online gauge\n'
  printf '# HELP github_runner_busy Whether GitHub reports the runner as executing a job.\n'
  printf '# TYPE github_runner_busy gauge\n'
  printf '# HELP github_runner_scrape_success Whether the last GitHub runner API scrape succeeded.\n'
  printf '# TYPE github_runner_scrape_success gauge\n'
  printf '# HELP github_actions_workflow_runs Current workflow runs by status among the latest one hundred runs.\n'
  printf '# TYPE github_actions_workflow_runs gauge\n'
  printf '# HELP github_actions_failed_runs_6h Failed workflow runs created during the last six hours.\n'
  printf '# TYPE github_actions_failed_runs_6h gauge\n'

  jq -r --arg runner_name_prefix "$RUNNER_NAME_PREFIX" '
    .runners[]
    | select(.name | startswith($runner_name_prefix + "-deploy-") or startswith($runner_name_prefix + "-validate-"))
    | [.name,
       (if (.name | startswith($runner_name_prefix + "-deploy-")) then "deploy" else "validate" end),
       (if .status == "online" then 1 else 0 end),
       (if .busy then 1 else 0 end)]
    | @tsv
  ' <<< "$runners_json" | while IFS=$'\t' read -r name role online busy; do
    printf 'github_runner_online{name="%s",role="%s"} %s\n' "$name" "$role" "$online"
    printf 'github_runner_busy{name="%s",role="%s"} %s\n' "$name" "$role" "$busy"
  done

  for workflow_status in queued in_progress completed; do
    workflow_count=$(jq --arg workflow_status "$workflow_status" '[.workflow_runs[] | select(.status == $workflow_status)] | length' <<< "$workflow_runs_json")
    printf 'github_actions_workflow_runs{status="%s"} %s\n' "$workflow_status" "$workflow_count"
  done

  failed_runs=$(jq --argjson cutoff "$(( $(date +%s) - 21600 ))" '[.workflow_runs[] | select(.conclusion == "failure" and (.created_at | fromdateiso8601) >= $cutoff)] | length' <<< "$workflow_runs_json")
  printf 'github_actions_failed_runs_6h %s\n' "$failed_runs"

  printf 'github_runner_scrape_success 1\n'
} > "$render_path"

mv "$render_path" "$textfile_directory/github_runner.prom"
printf 'github_runner_metrics_export=ready\n'
