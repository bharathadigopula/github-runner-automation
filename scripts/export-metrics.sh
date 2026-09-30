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
    ;;
  *) printf 'GITHUB_SCOPE must be "repo" or "org".\n' >&2; exit 1 ;;
esac

if [[ ! -r "$token_file" ]]; then
  printf 'GitHub token file is not readable.\n' >&2
  exit 1
fi

github_token=$(<"$token_file")

github_get() {
  curl --fail --silent --show-error \
    --header "Authorization: Bearer $github_token" \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    "$1"
}

#==============================================================================
# RUNNER STATE RETRIEVAL
#==============================================================================

runners_json=$(github_get "$listing_endpoint")

if [[ "$GITHUB_SCOPE" == "repo" ]]; then
  workflow_runs_json=$(github_get "$workflow_runs_endpoint")
else
  repository_page=1
  workflow_runs_json='{"workflow_runs":[]}'
  while :; do
    repositories_json=$(github_get "$GITHUB_API_URL/orgs/$GITHUB_TARGET/repos?type=all&per_page=100&page=$repository_page")
    repository_count=$(jq 'length' <<< "$repositories_json")
    while IFS= read -r repository_name; do
      repository_runs_json=$(github_get "$GITHUB_API_URL/repos/$repository_name/actions/runs?per_page=100")
      workflow_runs_json=$(jq -sc \
        '{workflow_runs: ([.[].workflow_runs[]] | sort_by(.created_at) | reverse | .[:100])}' \
        <(printf '%s\n' "$workflow_runs_json") \
        <(printf '%s\n' "$repository_runs_json"))
    done < <(jq -r '.[] | select(.archived == false) | .full_name' <<< "$repositories_json")
    if (( repository_count < 100 )); then
      break
    fi
    (( repository_page += 1 ))
  done
fi

queued_deploy_jobs=0
queued_validate_jobs=0
while IFS=$'\t' read -r repository_name run_id; do
  jobs_json=$(github_get "$GITHUB_API_URL/repos/$repository_name/actions/runs/$run_id/jobs?filter=latest&per_page=100")
  queued_deploy_count=$(jq \
    --arg organisation_label "${RUNNER_ORGANISATION_LABEL:-bharathcloudops}" \
    --arg location_label "${RUNNER_LOCATION_LABEL:-oci-platform}" \
    '[.jobs[] | select(
      .status == "queued" and
      (.labels | index("self-hosted")) and
      (.labels | index($organisation_label)) and
      (.labels | index($location_label)) and
      (.labels | index("deploy"))
    )] | length' <<< "$jobs_json")
  queued_validate_count=$(jq \
    --arg organisation_label "${RUNNER_ORGANISATION_LABEL:-bharathcloudops}" \
    --arg location_label "${RUNNER_LOCATION_LABEL:-oci-platform}" \
    '[.jobs[] | select(
      .status == "queued" and
      (.labels | index("self-hosted")) and
      (.labels | index($organisation_label)) and
      (.labels | index($location_label)) and
      (.labels | index("validate"))
    )] | length' <<< "$jobs_json")
  (( queued_deploy_jobs += queued_deploy_count )) || true
  (( queued_validate_jobs += queued_validate_count )) || true
done < <(jq -r '.workflow_runs[] | select(.status == "queued") | [.repository.full_name, .id] | @tsv' <<< "$workflow_runs_json")

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
  printf '# HELP github_actions_oci_queued_jobs Queued jobs explicitly requesting a BharathCoudOps OCI runner.\n'
  printf '# TYPE github_actions_oci_queued_jobs gauge\n'
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

  printf 'github_actions_oci_queued_jobs{role="deploy"} %s\n' "$queued_deploy_jobs"
  printf 'github_actions_oci_queued_jobs{role="validate"} %s\n' "$queued_validate_jobs"

  failed_runs=$(jq --argjson cutoff "$(( $(date +%s) - 21600 ))" '[.workflow_runs[] | select(.conclusion == "failure" and (.created_at | fromdateiso8601) >= $cutoff)] | length' <<< "$workflow_runs_json")
  printf 'github_actions_failed_runs_6h %s\n' "$failed_runs"

  printf 'github_runner_scrape_success 1\n'
} > "$render_path"

mv "$render_path" "$textfile_directory/github_runner.prom"
printf 'github_runner_metrics_export=ready\n'
