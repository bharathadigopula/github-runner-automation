#==============================================================================
# PINNED GITHUB ACTIONS RUNNER IMAGE
#==============================================================================

#==============================================================================
# DOCKER CLI SOURCE IMAGE
#==============================================================================

FROM docker:29.8.1-cli AS docker-cli

#==============================================================================
# GITHUB ACTIONS RUNNER BASE IMAGE
#==============================================================================

FROM ghcr.io/actions/actions-runner:2.331.0

#==============================================================================
# ROOT IMAGE ASSEMBLY
#==============================================================================

USER root

COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-buildx

RUN apt-get update \
  && apt-get install --yes --no-install-recommends \
    curl=8.5.0-2ubuntu10.6 \
    jq=1.7.1-5.1ubuntu4.24.04.1 \
  && rm -rf /var/lib/apt/lists/*

COPY scripts/entrypoint.sh /usr/local/bin/github-runner-entrypoint
RUN chmod 0755 /usr/local/bin/github-runner-entrypoint

#==============================================================================
# NON-ROOT RUNTIME USER
#==============================================================================

USER runner
WORKDIR /home/runner

ENTRYPOINT ["/usr/local/bin/github-runner-entrypoint"]
