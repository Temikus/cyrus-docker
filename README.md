# cyrus-docker

[![build](https://github.com/temikus/cyrus-docker/actions/workflows/build.yml/badge.svg)](https://github.com/temikus/cyrus-docker/actions/workflows/build.yml)
[![license](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

Unofficial container image for [Cyrus](https://github.com/cyrusagents/cyrus),
an agent that picks up Linear issues and GitHub PR comments and works on them
with Claude Code. Upstream ships Cyrus only as the `cyrus-ai` npm package; this
repo builds an image and pushes it to `ghcr.io/temikus/cyrus` for linux/amd64
and linux/arm64.

## What this adds on top of `npm install -g cyrus-ai`

- **Listens on all interfaces.** Cyrus binds `localhost` unless
  `CYRUS_HOST_EXTERNAL=true`, which would make it unreachable in a container.
  The image sets it.
- **Toolchain included.** `git`, `gh`, `jq`, `openssh-client`, plus
  `bubblewrap` and `socat` for Claude Code's sandbox. Git over
  HTTPS signs in with `$GITHUB_TOKEN` through `gh`. Claude Code comes bundled
  with the Agent SDK.
- **GitHub App key from an env var.** Cyrus reads the key only from
  `~/.cyrus/github-app.pem`. If `GITHUB_APP_PRIVATE_KEY` is set, the entrypoint
  writes it there with mode 600.
- **`config.json` seeded on first start.** With Linear credentials set and no
  repos yet, Cyrus never writes the file itself, and `cyrus self-auth-linear`
  then refuses to run.
- **tini as PID 1**, so zombie subprocesses from agent sessions are reaped.

## Usage

```bash
docker run -d --name cyrus \
  -p 3456:3456 \
  -v cyrus-data:/home/node \
  --env-file cyrus.env \
  ghcr.io/temikus/cyrus:0.2.73
```

All state lives under `/home/node`: `~/.cyrus` (config, Linear tokens, repo
clones, worktrees) and `~/.claude`. Mount one volume there. The image runs as
`node` (uid/gid 1000); on Kubernetes set `fsGroup: 1000` so the volume is
writable.

Cyrus has no web UI. Expose only `/linear-webhook` to the internet, plus
`/github-webhook` if you want GitHub triggers (read [Security](#security)
first). Its `/api/update/*` endpoints change config and should stay private
(they reject every request while `CYRUS_API_KEY` is unset).

### Environment

| Variable | Purpose |
| --- | --- |
| `CYRUS_BASE_URL` | Public URL, e.g. `https://cyrus.example.com` |
| `LINEAR_DIRECT_WEBHOOKS` | `true` for self-hosted Linear webhooks |
| `LINEAR_CLIENT_ID`, `LINEAR_CLIENT_SECRET`, `LINEAR_WEBHOOK_SECRET` | Your Linear OAuth app |
| `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` | Claude auth (`claude setup-token` makes the former) |
| `GITHUB_TOKEN` | PAT used by `git` and `gh` for clones, pushes and PRs |
| `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL` | Commit identity |
| `GITHUB_WEBHOOK_SECRET`, `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_PRIVATE_KEY` | GitHub App for PR comment webhooks |
| `GITHUB_BOT_USERNAME` | Comments from this user are ignored, which prevents reply loops |
| `CYRUS_SENTRY_DISABLED` | `1` stops error reports going to the Cyrus maintainers |

See upstream's [self-hosting guide](https://github.com/cyrusagents/cyrus/blob/main/docs/SELF_HOSTING.md)
for creating the Linear OAuth app and GitHub App.

### Linking Linear

`cyrus self-auth-linear` starts its own listener on `CYRUS_SERVER_PORT`, which
the running server already holds. Run it on a second port, and add
`http://localhost:3457/callback` as a callback URL in the Linear OAuth app:

```bash
# Terminal 1 (on Kubernetes: kubectl port-forward <pod> 3457)
docker exec -it \
  -e CYRUS_SERVER_PORT=3457 -e CYRUS_BASE_URL=http://localhost:3457 \
  cyrus cyrus self-auth-linear
```

Open the printed URL in a browser that can reach the container's port 3457 (for
`docker run`, publish it with `-p 3457:3457`). Restart the container afterwards
so Cyrus loads the new tokens. Then add repositories with
`docker exec -it cyrus cyrus self-add-repo <git-url>`; that needs no restart.

## Security

Read this before pointing Cyrus at repositories other people can comment on.

- **Agent sessions can read every secret.** Cyrus passes its whole environment
  to each Claude session, and sessions run as the same user. A session can read
  the GitHub App key, `GITHUB_TOKEN`, the Linear secret and the Claude token.
- **GitHub triggers have no author check.** On a repo that sends Cyrus
  webhooks, any GitHub user who mentions the bot in a PR comment starts a
  session, and any "request changes" review starts one without a mention.
  `userAccessControl` applies to Linear only. On repos with outside
  contributors, drive Cyrus from Linear only: leave `GITHUB_WEBHOOK_SECRET`
  unset and don't expose `/github-webhook`. Cyrus still pushes and opens PRs
  with `GITHUB_TOKEN`. With neither `GITHUB_WEBHOOK_SECRET` nor
  `CYRUS_API_KEY` set, `/github-webhook` rejects every request.
- **Limit Linear delegation** with `userAccessControl.allowedUsers` in
  `~/.cyrus/config.json`.
- **Turn on the egress sandbox** (`"sandbox": {"enabled": true,
  "networkPolicy": {"preset": "trusted"}}` in `config.json`). It filters
  traffic from Bash-run tools only, and the preset allows GitHub, so treat it
  as damage limitation. It runs tools under `bubblewrap`, which needs
  unprivileged user namespaces inside the container. Ubuntu 24.04 hosts block
  those by default (`kernel.apparmor_restrict_unprivileged_userns=1`), as does
  the default container AppArmor profile. Cyrus logs
  `[bwrap-sandbox] bubblewrap cannot create an unprivileged user namespace`
  when that's the case.
- **Scope the credentials.** Give `GITHUB_TOKEN` to a dedicated bot account
  that is a collaborator only on the target repos. A fine-grained PAT can't
  reach repos owned by another personal account, so outside an org that means
  a classic `repo` PAT. Use a Claude token you can revoke on its own.

## Building

Versions are pinned as `ARG`s at the top of the `Dockerfile`. Renovate bumps
them, and CI rebuilds and pushes on merge to `main`. Each build is tagged
`X.Y.Z`, `X.Y.Z-<run>` and `X.Y.Z-<yyyymmddhhmm>`, where `X.Y.Z` is the
`cyrus-ai` version.

```bash
just build   # linux/amd64 image
just check   # hadolint + shellcheck, then smoke-test the built image
just run     # local run with env from ./.env
```

`just test` boots the image and checks that it runs as uid 1000 under tini,
that every tool reports a version, that an unsigned webhook gets 401 from the
host, that the entrypoint writes `config.json` and the PEM, and that
`self-auth-linear` can start on port 3457. CI runs it before pushing.

## Licence

Cyrus is Apache-2.0. This repo is Apache-2.0 too.
