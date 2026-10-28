#!/bin/sh
# Smoke test against the real image: nginx, sshd and the entrypoint's watchdog
# all have to work together, and only a running container can show that.
#
# A Dockerfile that builds proves nothing here - "Protocol 2" in sshd_config
# builds fine and kills sshd on every modern OpenSSH. Everything below asserts
# on observable behaviour of the built image, including what it must refuse:
# bad configuration, symlinks out of the webroot, dotfiles, private files.
#
# Usage: ci/smoke-test.sh <image>
set -eu

# Git Bash on Windows rewrites arguments that look like POSIX paths
# (/data/webroot -> C:/Program Files/Git/data/webroot) before they reach
# docker.exe. No effect anywhere else.
export MSYS_NO_PATHCONV=1

IMAGE=${1:-nginx-sftp:test}
FAILURES=0
CONTAINER=""
NETWORK=""
# Every volume the script creates, space separated; cleanup removes exactly
# these by name.
VOLUMES=""
CLIENT_IMAGE="nginx-sftp-smoke-client:latest"

SFTP_USER=smokeuser
SFTP_PASSWORD=smokepassword
# Known content for uploads, so the served body can be compared exactly - a
# non-empty answer alone would also be an error page.
UPLOAD_CONTENT="smoke-upload-$$"

# Prints the HTTP status code for the URL in $1; runs inside a container
# (busybox wget). wget exits non-zero on 4xx/5xx, the status is still printed.
# shellcheck disable=SC2016  # expands inside the container, not here
STATUS_SNIPPET='wget -S -O /dev/null "$1" 2>&1 | sed -n "s/.*HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p" | tail -n 1'

# -v also removes the anonymous volumes the image declares (/data,
# /etc/ssh/keys); without it every run leaves two behind.
cleanup() {
    if [ -n "${CONTAINER}" ]; then
        docker rm -fv "${CONTAINER}" >/dev/null 2>&1 || true
    fi
    if [ -n "${NETWORK}" ]; then
        docker network rm "${NETWORK}" >/dev/null 2>&1 || true
    fi
    for volume in ${VOLUMES}; do
        docker volume rm "${volume}" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT INT TERM

fail() {
    echo "FAIL: $*"
    FAILURES=$((FAILURES + 1))
}

pass() {
    echo "OK: $*"
}

# Create a named volume for this run ($1 is a suffix) and record it for
# cleanup. The name is left in $volume - not printed, because a $(...)
# subshell would lose the VOLUMES update.
new_volume() {
    volume="nginx-sftp-smoke-$1-$$"
    docker volume create "${volume}" >/dev/null
    VOLUMES="${VOLUMES} ${volume}"
}

drop_container() {
    if [ -n "${CONTAINER}" ]; then
        docker rm -fv "${CONTAINER}" >/dev/null 2>&1 || true
    fi
    CONTAINER=""
}

running() {
    docker ps -q --filter "name=^${CONTAINER}$"
}

# Wait until nginx answers. Polling the health endpoint beats a fixed sleep,
# which is either flaky or slow.
wait_ready() {
    waited=0
    while [ "${waited}" -lt 60 ]; do
        if docker exec "${CONTAINER}" wget -q -O /dev/null http://127.0.0.1/internal/health 2>/dev/null; then
            return 0
        fi
        if [ -z "$(running)" ]; then
            fail "container exited during startup"
            docker logs "${CONTAINER}" 2>&1 | tail -20
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
    done

    fail "container did not become ready within ${waited}s"
    docker logs "${CONTAINER}" 2>&1 | tail -20
    return 1
}

# Start the image detached with the given extra "docker run" arguments.
# --health-interval only shortens the image's HEALTHCHECK schedule; the check
# command itself is the one from the Dockerfile.
start_container() {
    CONTAINER="nginx-sftp-smoke-$$"
    docker rm -fv "${CONTAINER}" >/dev/null 2>&1 || true
    docker run -d --name "${CONTAINER}" --network "${NETWORK}" \
        --health-interval=2s "$@" "${IMAGE}" >/dev/null
    wait_ready
}

start_default() {
    start_container -e "USER=${SFTP_USER}" -e "PASSWORD=${SFTP_PASSWORD}" "$@"
}

# sftp client and sshpass live in a throwaway image so the test behaves the same
# on a developer machine and on a runner, without adding tools to the image
# under test.
build_client_image() {
    docker build -q -t "${CLIENT_IMAGE}" - >/dev/null <<'DOCKERFILE'
FROM alpine:3.24
RUN apk add --no-cache openssh-client sshpass
DOCKERFILE
}

# Run an sftp batch ($1, newline separated) against the container.
#
# The commands are fed in through stdin instead of "sftp -b": -b turns on batch
# mode, which disables password authentication outright, so every login would
# look like a credential failure. Host key checking is off on purpose - every
# container generates fresh host keys.
#
# /tmp/upload.html (UPLOAD_CONTENT, mode 0666) is there to be uploaded; 0666
# shows whether the server's umask strips the write bits again.
sftp_batch() {
    docker run --rm --network "${NETWORK}" \
        -e "SFTP_BATCH=$1" -e "SFTP_PASSWORD=${SFTP_PASSWORD}" \
        -e "SFTP_TARGET=${SFTP_USER}@${CONTAINER}" \
        -e "UPLOAD_CONTENT=${UPLOAD_CONTENT}" \
        --entrypoint sh "${CLIENT_IMAGE}" -c '
            printf "%s\n" "$UPLOAD_CONTENT" > /tmp/upload.html
            chmod 666 /tmp/upload.html
            printf "%s\n" "$SFTP_BATCH" > /tmp/batch
            sshpass -p "$SFTP_PASSWORD" sftp \
                -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -o LogLevel=ERROR \
                "$SFTP_TARGET" < /tmp/batch
        ' 2>&1
}

# Body of $1 from inside the container. Only the body: errors go to stderr and
# the exit status is wget's, so an error page can never pass as content.
http_get() {
    docker exec "${CONTAINER}" wget -q -O - "http://127.0.0.1$1" 2>/dev/null
}

# HTTP status of $1, requested from inside the container (127.0.0.1).
http_status() {
    docker exec "${CONTAINER}" sh -c "${STATUS_SNIPPET}" sh "http://127.0.0.1$1"
}

# HTTP status of $1, requested from another container on the network - what
# any client outside sees.
http_status_outside() {
    docker run --rm --network "${NETWORK}" --entrypoint sh "${CLIENT_IMAGE}" \
        -c "${STATUS_SNIPPET}" sh "http://${CONTAINER}$1"
}

# Environment of the nginx master, every sshd process and any extra PIDs
# given as arguments (1 for tini), one variable per line. nginx workers are
# forked from the master and share its environment; their /proc entry is not
# readable from "docker exec" (other UID, no CAP_SYS_PTRACE), so they are left
# out. A PID that cannot be read prints UNREADABLE=<pid> rather than nothing,
# so the check cannot pass on an empty read.
service_environ() {
    # shellcheck disable=SC2016  # expands inside the container, not here
    docker exec "${CONTAINER}" sh -c '
        for pid in "$@" $(cat /run/nginx/nginx.pid) $(pidof sshd); do
            tr "\0" "\n" 2>/dev/null < "/proc/${pid}/environ" || echo "UNREADABLE=${pid}"
        done' sh "$@"
}

# Kill a service ($2 is the kill command, SIGKILL i.e. a crash rather than an
# orderly shutdown) and require the container to stop with a non-zero code -
# a restart policy only reacts to failure exits - and to log why.
check_watchdog() {
    service=$1
    kill_cmd=$2

    docker exec "${CONTAINER}" sh -c "${kill_cmd}" >/dev/null 2>&1 || true

    waited=0
    while [ "${waited}" -lt 30 ]; do
        if [ -z "$(running)" ]; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    if [ -n "$(running)" ]; then
        fail "container kept running ${waited}s after ${service} died"
        docker logs "${CONTAINER}" 2>&1 | tail -20
        return 1
    fi

    rc=$(docker inspect -f '{{.State.ExitCode}}' "${CONTAINER}")
    if [ "${rc}" = "0" ]; then
        fail "container stopped after ${service} died, but exited 0"
    elif ! docker logs "${CONTAINER}" 2>&1 | grep -q "${service} exited with status"; then
        fail "container stopped after ${service} died, but did not log '${service} exited with status'"
        docker logs "${CONTAINER}" 2>&1 | tail -20
    else
        pass "container stopped after ${service} died (${waited}s, exit ${rc}, reason logged)"
    fi
}

NETWORK="nginx-sftp-smoke-net-$$"
docker network rm "${NETWORK}" >/dev/null 2>&1 || true
docker network create "${NETWORK}" >/dev/null
build_client_image

# ---------------------------------------------------------------------------
# 1. Bad configuration is rejected before anything starts
# ---------------------------------------------------------------------------

check_refused() {
    label=$1
    expected=$2
    shift 2

    echo "== config: ${label} =="
    rc=0
    output=$(docker run --rm "$@" "${IMAGE}" 2>&1) || rc=$?

    if [ "${rc}" -eq 0 ]; then
        fail "${label}: container started although the configuration is invalid"
    elif ! echo "${output}" | grep -q "${expected}"; then
        fail "${label}: expected message '${expected}', got:"
        echo "${output}" | head -5
    else
        pass "${label} (exit ${rc})"
    fi
}

check_refused "USER missing" "set an USER variable" -e PASSWORD=x
check_refused "PASSWORD missing" "set a PASSWORD variable" -e USER=x
check_refused "USER not a plain login name" "USER must match" -e "USER=Bad User" -e PASSWORD=x
# Existing system accounts: the webroot would be chowned to them.
check_refused "USER=root" "already exists as a system account" -e USER=root -e PASSWORD=x
check_refused "USER=nginx" "already exists as a system account" -e USER=nginx -e PASSWORD=x
# Not a user, but a system group of that name: adduser would abort with a
# cryptic "group in use", joining it would put the SFTP user in wheel.
check_refused "USER=wheel (existing group)" "clashes with an existing system group" -e USER=wheel -e PASSWORD=x
# chpasswd reads one "user:password" per line - the second line would set
# root's password.
check_refused "PASSWORD with a newline" "must not contain line breaks" \
    -e USER=x -e "PASSWORD=$(printf 'x\nroot:pwned')"
check_refused "PASSWORD and PASSWORD_FILE" "either PASSWORD or PASSWORD_FILE" \
    -e USER=x -e PASSWORD=x -e PASSWORD_FILE=/etc/hostname
check_refused "PASSWORD_FILE unreadable" "not a readable file" \
    -e USER=x -e PASSWORD_FILE=/run/secrets/missing

# ---------------------------------------------------------------------------
# 2. nginx serves /data/webroot; the health endpoint is internal only
# ---------------------------------------------------------------------------

echo "== http: nginx serves the webroot =="
if start_default; then
    docker exec "${CONTAINER}" sh -c 'echo smoke-index > /data/webroot/index.html'
    docker exec "${CONTAINER}" sh -c 'mkdir -p /data/webroot/sub && echo smoke-sub > /data/webroot/sub/index.html'

    if [ "$(http_get /)" != "smoke-index" ]; then
        fail "nginx did not serve /data/webroot/index.html"
    elif [ "$(http_get /sub/)" != "smoke-sub" ]; then
        fail "nginx did not serve a subdirectory index"
    elif ! http_get /internal/health | grep -q 'Active connections'; then
        fail "health endpoint did not answer with stub_status output"
    else
        pass "nginx serves the webroot and the health endpoint"
    fi

    echo "== http: health endpoint is internal and exact =="
    status=$(http_status_outside /internal/health)
    if [ "${status}" != "403" ]; then
        fail "/internal/health from another container answered ${status}, expected 403"
    elif [ "$(http_status /internal/healthxyz)" != "404" ]; then
        fail "/internal/healthxyz is not a 404 - the health location is still a prefix match"
    else
        pass "/internal/health is denied from outside (403), exact match only"
    fi

    # The Dockerfile's HEALTHCHECK runs against 127.0.0.1 and must still get in.
    health=""
    waited=0
    while [ "${waited}" -lt 30 ]; do
        health=$(docker inspect -f '{{.State.Health.Status}}' "${CONTAINER}")
        [ "${health}" = "healthy" ] && break
        sleep 2
        waited=$((waited + 2))
    done
    if [ "${health}" = "healthy" ]; then
        pass "HEALTHCHECK reports healthy"
    else
        fail "HEALTHCHECK status is '${health}' after ${waited}s"
    fi

    # PID 1 (tini) got PASSWORD from "docker run -e" and keeps it - nothing the
    # image can change. Only what the entrypoint hands down is checked here.
    echo "== env: services do not see PASSWORD =="
    environ=$(service_environ)
    if echo "${environ}" | grep -q '^UNREADABLE='; then
        fail "could not read a service environment: $(echo "${environ}" | grep '^UNREADABLE=')"
    elif echo "${environ}" | grep -q '^PASSWORD'; then
        fail "nginx or sshd has PASSWORD in its environment"
    else
        pass "nginx and sshd run without PASSWORD in their environment"
    fi

    # -----------------------------------------------------------------------
    # 3. SFTP login works, is chrooted, and uploads land in the webroot
    # -----------------------------------------------------------------------

    echo "== sftp: login, chroot and upload =="
    listing=$(sftp_batch 'pwd
ls') || true

    if echo "${listing}" | grep -qiE 'permission denied|connection closed|not a valid|broken pipe'; then
        fail "sftp login failed: ${listing}"
    elif ! echo "${listing}" | grep -q 'Remote working directory: /'; then
        fail "sftp session is not chrooted to the home directory, got: ${listing}"
    elif ! echo "${listing}" | grep -q 'webroot'; then
        fail "webroot is not visible inside the chroot, got: ${listing}"
    else
        pass "sftp login is chrooted and shows the webroot"
    fi

    upload=$(sftp_batch 'cd webroot
put /tmp/upload.html uploaded.html') || true
    body=$(http_get /uploaded.html) || body="<request failed>"
    mode=$(docker exec "${CONTAINER}" stat -c '%a' /data/webroot/uploaded.html 2>/dev/null) || mode=""
    if echo "${upload}" | grep -qiE 'permission denied|failure'; then
        fail "sftp upload into webroot was rejected: ${upload}"
    elif [ "${body}" != "${UPLOAD_CONTENT}" ]; then
        fail "file uploaded over sftp is not served as uploaded, got: ${body}"
    elif [ "${mode}" != "644" ]; then
        fail "a 0666 upload ended up ${mode}, expected 644 (sftp umask 022)"
    else
        pass "file uploaded over sftp is served byte for byte, mode 644"
    fi

    # -----------------------------------------------------------------------
    # 4. What the SFTP user must not be able to publish
    # -----------------------------------------------------------------------

    echo "== http: symlinks out of the webroot are not followed =="
    sftp_batch 'cd webroot
ln -s /etc/passwd passwd.html' >/dev/null || true
    if ! docker exec "${CONTAINER}" test -L /data/webroot/passwd.html; then
        fail "could not create the symlink over sftp, test is void"
    elif http_get /passwd.html | grep -q '^root:'; then
        fail "a symlink to /etc/passwd in the webroot is served"
    elif [ "$(http_status /passwd.html)" != "403" ]; then
        # Anything but 403 means the request never reached disable_symlinks -
        # a 404 here would pass even with the protection switched off.
        fail "symlink to /etc/passwd answered $(http_status /passwd.html), expected 403 (disable_symlinks)"
    else
        pass "symlink to /etc/passwd is refused (403)"
    fi

    echo "== http: dotfiles hidden, /.well-known/ served =="
    sftp_batch 'cd webroot
put /tmp/upload.html .env
mkdir .well-known
put /tmp/upload.html .well-known/x
put /tmp/upload.html .well-known/.hidden' >/dev/null || true
    # The files have to exist, or a 404 proves nothing.
    if ! docker exec "${CONTAINER}" test -f /data/webroot/.env         || ! docker exec "${CONTAINER}" test -f /data/webroot/.well-known/.hidden; then
        fail "could not upload .env and .well-known/.hidden over sftp, test is void"
    elif [ "$(http_status /.env)" != "404" ]; then
        fail "/.env is served (status $(http_status /.env))"
    elif [ "$(http_status /.well-known/.hidden)" != "404" ]; then
        fail "/.well-known/.hidden is served"
    elif [ "$(http_get /.well-known/x)" != "${UPLOAD_CONTENT}" ]; then
        fail "/.well-known/x is not served"
    else
        pass "/.env and /.well-known/.hidden are 404, /.well-known/x is served"
    fi

    echo "== permissions: a private upload stays private across restarts =="
    sftp_batch 'cd webroot
put /tmp/upload.html private.html
chmod 600 private.html' >/dev/null || true
    before=$(http_status /private.html)
    docker restart "${CONTAINER}" >/dev/null
    if wait_ready; then
        perms=$(docker exec "${CONTAINER}" stat -c '%U %a' /data/webroot/private.html 2>/dev/null) || perms=""
        after=$(http_status /private.html)
        if [ "${perms}" != "${SFTP_USER} 600" ]; then
            fail "private.html is '${perms}' after restart, expected '${SFTP_USER} 600'"
        elif [ "${before}" != "403" ] || [ "${after}" != "403" ]; then
            # 403 is nginx failing to open the file. A 404 would mean the
            # upload never happened and the check proves nothing.
            fail "a 0600 upload answered ${before} before and ${after} after restart, expected 403 both times"
        elif [ "$(http_get /uploaded.html)" != "${UPLOAD_CONTENT}" ]; then
            fail "uploaded.html is no longer served after restart"
        else
            pass "0600 upload stays 0600 and unserved (${after}) across docker restart"
        fi
    fi

    # -----------------------------------------------------------------------
    # 5. A dying service takes the container down (entrypoint.sh watchdog)
    # -----------------------------------------------------------------------

    echo "== watchdog: nginx crash stops the container =="
    # shellcheck disable=SC2016  # expands inside the container, not here
    check_watchdog "nginx" 'kill -9 "$(cat /run/nginx/nginx.pid)"'
fi
drop_container

# A crashed sshd has to take the container down just like a crashed nginx -
# otherwise the container stays "up" while nobody can upload any more.
echo "== watchdog: sshd crash stops the container =="
if start_default; then
    # shellcheck disable=SC2016  # expands inside the container, not here
    check_watchdog "sshd" 'kill -9 "$(pidof sshd)"'
fi
drop_container

# ---------------------------------------------------------------------------
# 6. docker stop terminates promptly
#
#    PID 1 has to act on SIGTERM itself. A process that ignores it makes every
#    "docker stop" sit out the full grace period before the SIGKILL - visible
#    only as a slow deployment, never as an error.
# ---------------------------------------------------------------------------

echo "== signals: docker stop terminates promptly =="
if start_default; then
    started=$(date +%s)
    docker stop -t 30 "${CONTAINER}" >/dev/null
    elapsed=$(( $(date +%s) - started ))
    rc=$(docker inspect -f '{{.State.ExitCode}}' "${CONTAINER}")
    drop_container

    if [ "${elapsed}" -gt 10 ]; then
        fail "docker stop took ${elapsed}s, SIGTERM was not handled"
    elif [ "${rc}" != "0" ]; then
        fail "orderly stop exited with ${rc}, expected 0"
    else
        pass "docker stop completed in ${elapsed}s (exit ${rc})"
    fi
fi
drop_container

# ---------------------------------------------------------------------------
# 7. PASSWORD_FILE (Docker secret) works and the password stays out of every
#    process environment
# ---------------------------------------------------------------------------

echo "== secrets: PASSWORD_FILE =="
new_volume secret
SECRET_VOLUME=${volume}
docker run --rm -v "${SECRET_VOLUME}:/s" -e "SFTP_PASSWORD=${SFTP_PASSWORD}" \
    --entrypoint sh "${CLIENT_IMAGE}" -c 'printf "%s\n" "$SFTP_PASSWORD" > /s/sftp_password'

if start_container -e "USER=${SFTP_USER}" \
    -e PASSWORD_FILE=/run/secrets/sftp_password \
    -v "${SECRET_VOLUME}:/run/secrets:ro"; then
    listing=$(sftp_batch 'pwd') || true
    environ=$(service_environ 1)
    if ! echo "${listing}" | grep -q 'Remote working directory: /'; then
        fail "sftp login with the password from PASSWORD_FILE failed: ${listing}"
    elif echo "${environ}" | grep -q '^UNREADABLE='; then
        fail "could not read a process environment: $(echo "${environ}" | grep '^UNREADABLE=')"
    elif echo "${environ}" | grep -qE "^PASSWORD=|${SFTP_PASSWORD}"; then
        fail "the password shows up in the environment of PID 1, nginx or sshd"
    else
        pass "PASSWORD_FILE login works, password in no process environment"
    fi
fi
drop_container

# ---------------------------------------------------------------------------
# 8. Host keys are generated once, reused from the volume, and kept private
# ---------------------------------------------------------------------------

echo "== host keys: generated once, reused from the volume =="
new_volume keys
KEYS_VOLUME=${volume}

first=""
if start_default -v "${KEYS_VOLUME}:/etc/ssh/keys"; then
    first=$(docker exec "${CONTAINER}" cat /etc/ssh/keys/ssh_host_ed25519_key.pub)
    drop_container

    # A key restored with the wrong owner and mode must be fixed before sshd
    # reads it.
    docker run --rm -v "${KEYS_VOLUME}:/k" --entrypoint sh "${CLIENT_IMAGE}" \
        -c 'chown 65534:65534 /k/ssh_host_ed25519_key && chmod 644 /k/ssh_host_ed25519_key'

    if start_default -v "${KEYS_VOLUME}:/etc/ssh/keys"; then
        second=$(docker exec "${CONTAINER}" cat /etc/ssh/keys/ssh_host_ed25519_key.pub)
        keyperms=$(docker exec "${CONTAINER}" stat -c '%u:%g %a' /etc/ssh/keys/ssh_host_ed25519_key)
        if [ -z "${first}" ]; then
            fail "no host key was generated"
        elif [ "${first}" != "${second}" ]; then
            fail "host key changed across restarts although the volume persists"
        else
            pass "host key is generated once and reused"
        fi

        echo "== host keys: owner and mode enforced =="
        if [ "${keyperms}" != "0:0 600" ]; then
            fail "private host key is '${keyperms}', expected '0:0 600'"
        elif ! docker logs "${CONTAINER}" 2>&1 | grep -q 'Fixing owner/mode of /etc/ssh/keys/ssh_host_ed25519_key'; then
            fail "host key was fixed silently, expected a log line"
        elif [ -z "$(docker exec "${CONTAINER}" pidof sshd)" ]; then
            fail "sshd is not running with the fixed host key"
        else
            pass "mis-owned 0644 host key reset to root 0600 and logged"
        fi
    fi
fi
drop_container

# Keys as a Kubernetes secret (defaultMode 0400) or a ":ro" volume arrive
# root-owned 0400 on a read-only mount. That is already private; the
# entrypoint must accept it as is rather than die trying to chmod it.
echo "== host keys: read-only mount with root 0400 keys =="
new_volume rokeys
RO_KEYS_VOLUME=${volume}
docker run --rm -v "${RO_KEYS_VOLUME}:/k" --entrypoint sh "${CLIENT_IMAGE}" -c '
    ssh-keygen -q -t ed25519 -f /k/ssh_host_ed25519_key -N "" &&
    ssh-keygen -q -t rsa -b 2048 -f /k/ssh_host_rsa_key -N "" &&
    chown 0:0 /k/ssh_host_*_key && chmod 400 /k/ssh_host_*_key'
expected_key=$(docker run --rm -v "${RO_KEYS_VOLUME}:/k:ro" --entrypoint cat "${CLIENT_IMAGE}" /k/ssh_host_ed25519_key.pub)

if start_default -v "${RO_KEYS_VOLUME}:/etc/ssh/keys:ro"; then
    listing=$(sftp_batch 'pwd') || true
    served_key=$(docker exec "${CONTAINER}" cat /etc/ssh/keys/ssh_host_ed25519_key.pub)
    keyperms=$(docker exec "${CONTAINER}" stat -c '%u %a' /etc/ssh/keys/ssh_host_ed25519_key)
    if ! echo "${listing}" | grep -q 'Remote working directory: /'; then
        fail "sftp login with read-only 0400 host keys failed: ${listing}"
    elif [ "${served_key}" != "${expected_key}" ]; then
        fail "container does not use the provided host key"
    elif [ "${keyperms}" != "0 400" ]; then
        fail "provided host key is '${keyperms}', expected '0 400'"
    elif docker logs "${CONTAINER}" 2>&1 | grep -q 'Fixing owner/mode'; then
        fail "a root 0400 key was treated as needing repair"
    else
        pass "read-only root 0400 host keys are used as they are, sftp works"
    fi
fi
drop_container

# An empty read-only mount: nothing to use, nothing can be generated.
new_volume emptykeys
check_refused "read-only key mount without keys" "has to contain the host keys" \
    -e "USER=${SFTP_USER}" -e "PASSWORD=${SFTP_PASSWORD}" -v "${volume}:/etc/ssh/keys:ro"

# A symlink at a key path would make the owner/mode repair act on its target.
new_volume linkkeys
docker run --rm -v "${volume}:/k" --entrypoint ln "${CLIENT_IMAGE}" \
    -s /etc/passwd /k/ssh_host_ed25519_key
check_refused "symlink at a host key path" "is a symlink or not a regular file" \
    -e "USER=${SFTP_USER}" -e "PASSWORD=${SFTP_PASSWORD}" -v "${volume}:/etc/ssh/keys"

# ---------------------------------------------------------------------------

echo
if [ "${FAILURES}" -eq 0 ]; then
    echo "smoke test passed"
else
    echo "smoke test FAILED (${FAILURES} check(s))"
    exit 1
fi
