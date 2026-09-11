#!/bin/sh
# Smoke test against the real image: nginx, sshd and the supervisord watchdog
# all have to work together, and only a running container can show that.
#
# A Dockerfile that builds proves nothing here - "Protocol 2" in sshd_config
# builds fine and kills sshd on every modern OpenSSH. Everything below asserts
# on observable behaviour of the built image.
set -eu

IMAGE=${1:-nginx-sftp:test}
FAILURES=0
CONTAINER=""
NETWORK=""
KEYS_VOLUME=""
CLIENT_IMAGE="nginx-sftp-smoke-client:latest"

SFTP_USER=smokeuser
SFTP_PASSWORD=smokepassword

cleanup() {
    if [ -n "${CONTAINER}" ]; then
        docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    fi
    if [ -n "${NETWORK}" ]; then
        docker network rm "${NETWORK}" >/dev/null 2>&1 || true
    fi
    if [ -n "${KEYS_VOLUME}" ]; then
        docker volume rm "${KEYS_VOLUME}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

fail() {
    echo "FAIL: $*"
    FAILURES=$((FAILURES + 1))
}

pass() {
    echo "OK: $*"
}

drop_container() {
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    CONTAINER=""
}

running() {
    docker ps -q --filter "name=^${CONTAINER}$"
}

# Start the image detached and wait until nginx answers. Polling the health
# endpoint beats a fixed sleep, which is either flaky or slow.
start_container() {
    CONTAINER="nginx-sftp-smoke-$$"
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    docker run -d --name "${CONTAINER}" --network "${NETWORK}" \
        -e USER="${SFTP_USER}" -e PASSWORD="${SFTP_PASSWORD}" \
        $1 "${IMAGE}" >/dev/null

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

    fail "container did not become healthy within ${waited}s"
    docker logs "${CONTAINER}" 2>&1 | tail -20
    return 1
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
sftp_batch() {
    docker run --rm --network "${NETWORK}" \
        -e "SFTP_BATCH=$1" -e "SFTP_PASSWORD=${SFTP_PASSWORD}" \
        -e "SFTP_TARGET=${SFTP_USER}@${CONTAINER}" \
        --entrypoint sh "${CLIENT_IMAGE}" -c '
            printf "%s\n" "$SFTP_BATCH" > /tmp/batch
            sshpass -p "$SFTP_PASSWORD" sftp \
                -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -o LogLevel=ERROR \
                "$SFTP_TARGET" < /tmp/batch
        ' 2>&1
}

http_get() {
    docker exec "${CONTAINER}" wget -q -O - "http://127.0.0.1$1" 2>&1
}

NETWORK="nginx-sftp-smoke-net-$$"
docker network rm "${NETWORK}" >/dev/null 2>&1 || true
docker network create "${NETWORK}" >/dev/null
build_client_image

# ---------------------------------------------------------------------------
# 1. Missing credentials are rejected before anything starts
# ---------------------------------------------------------------------------

check_missing_env() {
    label=$1
    expected=$2
    shift 2

    echo "== config: ${label} =="
    rc=0
    output=$(docker run --rm "$@" "${IMAGE}" 2>&1) || rc=$?

    if [ "${rc}" -eq 0 ]; then
        fail "${label}: container started although the variable is missing"
    elif ! echo "${output}" | grep -q "${expected}"; then
        fail "${label}: expected message '${expected}', got:"
        echo "${output}" | head -5
    else
        pass "${label} (exit ${rc})"
    fi
}

check_missing_env "USER missing" "set an USER variable" -e PASSWORD=x
check_missing_env "PASSWORD missing" "set a PASSWORD variable" -e USER=x

# ---------------------------------------------------------------------------
# 2. nginx serves /data/webroot and answers the health endpoint
# ---------------------------------------------------------------------------

echo "== http: nginx serves the webroot =="
if start_container ""; then
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
put /etc/hostname uploaded.html') || true
    if echo "${upload}" | grep -qiE 'permission denied|failure'; then
        fail "sftp upload into webroot was rejected: ${upload}"
    elif [ -z "$(http_get /uploaded.html)" ]; then
        fail "file uploaded over sftp is not served by nginx"
    else
        pass "file uploaded over sftp is served by nginx"
    fi

    # -----------------------------------------------------------------------
    # 4. A dying service takes the container down (docker_kill.py listener)
    # -----------------------------------------------------------------------

    echo "== watchdog: nginx crash stops the container =="
    # SIGKILL on the pid supervisord tracks: a "supervisorctl stop" would be an
    # orderly stop and must not take the container down.
    docker exec "${CONTAINER}" sh -c 'kill -9 "$(supervisorctl pid nginx)"' >/dev/null 2>&1 || true

    waited=0
    while [ "${waited}" -lt 30 ]; do
        if [ -z "$(running)" ]; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    if [ -n "$(running)" ]; then
        fail "container kept running ${waited}s after nginx died"
        docker logs "${CONTAINER}" 2>&1 | tail -20
    else
        pass "container stopped after nginx died (${waited}s)"
    fi
fi
drop_container

# ---------------------------------------------------------------------------
# 5. Host keys are generated once and reused from the volume
# ---------------------------------------------------------------------------

echo "== host keys: generated once, reused from the volume =="
KEYS_VOLUME="nginx-sftp-smoke-keys-$$"
docker volume create "${KEYS_VOLUME}" >/dev/null

first=""
if start_container "-v ${KEYS_VOLUME}:/etc/ssh/keys"; then
    first=$(docker exec "${CONTAINER}" cat /etc/ssh/keys/ssh_host_ed25519_key.pub)
    drop_container

    if start_container "-v ${KEYS_VOLUME}:/etc/ssh/keys"; then
        second=$(docker exec "${CONTAINER}" cat /etc/ssh/keys/ssh_host_ed25519_key.pub)
        if [ -z "${first}" ]; then
            fail "no host key was generated"
        elif [ "${first}" != "${second}" ]; then
            fail "host key changed across restarts although the volume persists"
        else
            pass "host key is generated once and reused"
        fi
    fi
fi
drop_container

# ---------------------------------------------------------------------------

echo
if [ "${FAILURES}" -eq 0 ]; then
    echo "smoke test passed"
else
    echo "smoke test FAILED (${FAILURES} check(s))"
    exit 1
fi
