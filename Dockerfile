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

FROM ghcr.io/actions/actions-runner:2.337.0

#==============================================================================
# ROOT IMAGE ASSEMBLY
#==============================================================================

USER root

COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-buildx
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose

RUN apt-get update >/dev/null && \
	DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends python3-venv >/dev/null && \
	rm -rf /var/lib/apt/lists/*

COPY scripts/entrypoint.sh /usr/local/bin/github-runner-entrypoint
RUN chmod 0755 /usr/local/bin/github-runner-entrypoint

#==============================================================================
# NON-ROOT RUNTIME USER
#==============================================================================

USER root
ENV HOME=/home/runner
WORKDIR /home/runner

ENTRYPOINT ["/usr/local/bin/github-runner-entrypoint"]
