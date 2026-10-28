# Security review – 2026-10-28

## Scope

Full repository at `master` @ `afa3948`: `Dockerfile`, `entrypoint.sh`, `nginx.conf`,
`sshd_config`, `ci/smoke-test.sh`, `.github/workflows/build.yml`, `.github/workflows/ci.yml`,
`README.md`. Focus on security, correctness bugs included.

## Model / command

```
codex exec --sandbox read-only --model gpt-6.1-sol -c model_reasoning_effort=high -
```

codex-cli 0.163.0. Codex had no Docker access; the key claims were then reproduced in
throwaway containers built from the image.

## Dependency status (same day)

- GitHub Actions: all on the current major, all `using: node24` (checkout v7,
  setup-qemu/setup-buildx/login v4, build-push v7).
- Base image: `alpine:3.24` is latest-stable (3.24.3).
- apk packages unpinned; the last image build was 2026-09-11, with no scheduled rebuild.

## Findings

| ID | Severity | Where | Finding | Verdict | Action |
|----|----------|-------|---------|---------|--------|
| R2 | medium | `nginx.conf:5-7` | Symlinks uploaded over SFTP make nginx serve any world-readable container file (e.g. `/etc/passwd`) | reproduced | fixed |
| R3 | medium | `entrypoint.sh:33-34` | `chmod -R go=rX` on every start makes privately uploaded files (0600) world-readable and served | reproduced | fixed |
| R4 | medium | `nginx.conf:5-8` | Dotfiles (`.env`, `.git/`, `.htaccess`) are served | valid | fixed |
| R5 | medium | `entrypoint.sh:16-22,33` | Existing system accounts (`root`, `nginx`, `sshd`) are accepted as `USER`; the webroot is chowned to them, login is impossible | reproduced | fixed |
| R6 | low | `entrypoint.sh:21` | Newline in `PASSWORD` sets other accounts' passwords via `chpasswd` | reproduced | fixed |
| R1 | low | `entrypoint.sh:2,92,95,100` | Under `set -e` the service subshell never writes its exit line; the container only stops because the fifo open fails with EINTR | reproduced (no hang, exit reason not logged) | fixed |
| R8 | low | `nginx.conf:20-22` | `/internal/health` is public and matches any prefix (`/internal/healthxyz`) | reproduced | fixed |
| R9 | low | `build.yml` | No `concurrency` group; parallel publishes can move `:stable`/`:latest` backwards | by reading | fixed |
| R10 | low | `build.yml:63,74` | Tag regex accepts `+`, which Docker tags do not allow | valid | fixed |
| R11 | low | `ci/smoke-test.sh:110-112,214-221` | Upload check passes on an HTTP error body | by reading | fixed |
| R12 | low | `ci/smoke-test.sh:22,43,55` | `docker rm -f` leaves anonymous volumes behind | valid | fixed |
| R13 | low | `README.md:69-72` | Host-key text is inaccurate (keys survive restart, change on recreate) | valid | fixed |

### Hardening

| ID | Severity | Where | Suggestion | Action |
|----|----------|-------|------------|--------|
| H-R7 | low | `sshd_config` | `DisableForwarding yes` (stream-local forwarding defaults to yes; no escape reproduced) | fixed |
| H1 | low | `entrypoint.sh:35-36` | `chmod 777 /data/webroot` – make it owned by the SFTP user, 0755 | fixed |
| H2 | low | `entrypoint.sh` | Support `PASSWORD_FILE`, `unset PASSWORD` before starting services | fixed |
| H3 | low | `entrypoint.sh:45-50` | Mounted host keys are not checked for owner/mode | fixed |
| H4 | medium | `build.yml` | Publishing not tied to `master`; any tag can become `:stable` | fixed |
| H5 | low | `ci.yml` | No `permissions:` block; add `contents: read`, `persist-credentials: false` | fixed |
| H6 | medium | both workflows | Actions pinned to major tags, not SHAs | fixed |
| H7 | low | `Dockerfile`, `build.yml` | Base image not digest-pinned; no scheduled rebuild for apk security fixes | fixed |
| H8 | low | `build.yml` | Only amd64 is smoke-tested; publish build has no `cache-to` | fixed |
| H9 | low | `sshd_config` | Optional: `AllowUsers`, `KbdInteractiveAuthentication no`, sftp logging/umask (defaults of OpenSSH 10.3 are otherwise strong) | fixed |
| H10 | low | `ci/smoke-test.sh` | No negative tests; stale supervisord/`docker_kill.py` references | fixed |
| H11 | low | `build.yml` | No SBOM / signing | fixed |

## Follow-up review of the fix diff

Scope: uncommitted `security-hardening` changes (all findings above implemented).
Command: `codex exec --sandbox read-only --model gpt-6.1-terra -c model_reasoning_effort=high -`
(codex-cli 0.163.0). Runtime claims verified with a local image build and the full smoke test;
all action SHA pins checked against their version comments and `using: node24`.

| ID | Severity | Where | Finding | Verdict | Action |
|----|----------|-------|---------|---------|--------|
| F1 | medium | `entrypoint.sh` host-key check | Root-owned 0400 keys on a read-only mount make the container exit (chown fails under `set -e`) – regression | reproduced | fixed |
| F2 | low (Codex: high) | `build.yml` | H4 ancestry check runs from the tagged commit's own workflow, so a tag on a branch with an older `build.yml` bypasses it; guard against mistakes only | plausible | code-side guard in place; tag ruleset "Protect release tags" created (create/update/delete of `*.*.*` tags limited to repo admins) |
| F3 | low (Codex: medium) | `build.yml` | `:stable` can still move backwards across concurrency groups during a long build | plausible | fixed |
| F4 | low (Codex: medium) | `build.yml` | Re-check compares tag names only; a moved tag publishes the planned commit | by reading | fixed |
| F5 | low (Codex: medium) | `build.yml` | Scheduled rebuild's GitHub attestation records the master head, not the release commit | plausible | fixed |
| F6 | low (Codex: medium) | `build.yml` | Scheduled rebuild: tested and published images are separate no-cache builds | confirmed | fixed |
| F7 | low | `build.yml` | Newest bad/off-master tag blocks the weekly rebuild and `:stable` | by reading | fixed |
| F8 | low | `entrypoint.sh` host-key loop | Follows symlinks, accepts non-regular files | by reading | fixed |
| F9 | low | `ci/smoke-test.sh` | Dotfile/symlink/private-file tests can pass vacuously | confirmed | fixed |
| F10 | low | `build.yml` | Release tag regex has no 128-char limit | confirmed | fixed |
| F11 | low | `build.yml` | `:latest` might not follow master push order | plausible | fixed |
| F12 | info | `entrypoint.sh` | USER equal to an existing group name aborts in adduser with an unclear message | reproduced | fixed |

### Rejected

- Recursive chown/chmod following symlinks (TOCTOU): refuted by test; BusyBox changes the link,
  sshd starts only after the walk.
- Hardlinks into the webroot: cross-device, and paths outside `/data` are not reachable.
- Script injection via `GITHUB_REF_NAME`: used as a quoted shell variable only.
- GHA cache poisoning from forks: `ci.yml` does not use the gha cache.
- `server_tokens`, autoindex, nginx worker user: already safe in Alpine's defaults.
- New `PASSWORD` not applied on restart: changing env requires recreate, which applies it.
