image := "ghcr.io/temikus/cyrus"

cyrus_version := `sed -n 's/^ARG CYRUS_VERSION=//p' Dockerfile | head -1`
build_date := `date -u +%Y-%m-%dT%H:%M:%SZ`
vcs_ref := `git rev-parse --short HEAD 2>/dev/null || echo unknown`

default:
    @just --list

# Print the pinned cyrus-ai version
version:
    @echo {{ cyrus_version }}

# Build the image for linux/amd64
build:
    docker build \
        --platform=linux/amd64 \
        --build-arg BUILD_DATE={{ build_date }} \
        --build-arg VCS_REF={{ vcs_ref }} \
        -t {{ image }}:{{ cyrus_version }} \
        .

# Lint the Dockerfile and shell scripts
lint:
    docker run --rm -i hadolint/hadolint < Dockerfile
    docker run --rm -v "{{ justfile_directory() }}:/mnt" -w /mnt koalaman/shellcheck \
        cyrus-entrypoint.sh scripts/smoke.sh

# Smoke-test the built image
test:
    ./scripts/smoke.sh {{ image }}:{{ cyrus_version }} {{ cyrus_version }}

# Lint + tests
check: lint test

# Push the built image
push:
    docker push {{ image }}:{{ cyrus_version }}

# Run locally on :3456 with state in the cyrus-data volume and env from ./.env
run:
    docker run --rm -it \
        -p 3456:3456 \
        -v cyrus-data:/home/node \
        --env-file .env \
        {{ image }}:{{ cyrus_version }}
