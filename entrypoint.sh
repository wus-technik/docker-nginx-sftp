#!/bin/sh
set -e

# ---------------------------------------------------------------------------
# Validation
#
# Everything the container is told from outside is checked here, before the
# first file is touched: a bad USER used to get the webroot chowned to it
# (root, nginx, ...) before anything noticed, and a newline in PASSWORD was
# passed straight on to chpasswd, which reads one "user:password" per line.
# ---------------------------------------------------------------------------

NL='
'
CR=$(printf '\r')

# Checks for USER variable
if [ -z "$USER" ]; then
  echo >&2 'Please set an USER variable (ie.: -e USER=john).'
  exit 1
fi

# A plain login name: lower case, digits, "_" and "-", not starting with a
# digit or "-", at most 32 characters. That rules out anything chpasswd,
# sshd_config or a shell could read as more than a name - including CR/LF.
# "case" instead of grep: grep matches per line, so "ok<LF>root" would pass.
case "${USER}" in
  *[!a-z0-9_-]* | [!a-z_]*)
    echo >&2 "USER must match ^[a-z_][a-z0-9_-]{0,31}\$, refusing to start."
    exit 1
    ;;
esac
if [ "${#USER}" -gt 32 ]; then
  echo >&2 "USER must be at most 32 characters long, refusing to start."
  exit 1
fi

# The password comes either from PASSWORD or from a file named by
# PASSWORD_FILE (a Docker/Compose secret, e.g. /run/secrets/sftp_password).
# The file keeps the password out of "docker inspect" and out of the
# environment of every process in the container.
if [ -n "${PASSWORD}" ] && [ -n "${PASSWORD_FILE}" ]; then
  echo >&2 'Set either PASSWORD or PASSWORD_FILE, not both.'
  exit 1
fi
if [ -n "${PASSWORD_FILE}" ]; then
  if [ ! -f "${PASSWORD_FILE}" ] || [ ! -r "${PASSWORD_FILE}" ]; then
    echo >&2 "PASSWORD_FILE ${PASSWORD_FILE} is not a readable file."
    exit 1
  fi
  # $(...) drops trailing newlines, so a secret file written by an editor
  # with a final newline still works. A CRLF ending is caught below.
  PASSWORD=$(cat "${PASSWORD_FILE}")
  if [ -z "${PASSWORD}" ]; then
    echo >&2 "PASSWORD_FILE ${PASSWORD_FILE} is empty."
    exit 1
  fi
fi

# Checks for PASSWORD variable
if [ -z "${PASSWORD}" ]; then
  echo >&2 'Please set a PASSWORD variable (ie.: -e PASSWORD=hackme) or PASSWORD_FILE.'
  exit 1
fi

case "${PASSWORD}" in
  *"${NL}"* | *"${CR}"*)
    echo >&2 'PASSWORD must not contain line breaks (CR or LF), refusing to start.'
    exit 1
    ;;
esac

# An existing account is only acceptable if it is one this script created on
# an earlier start of the same container (docker restart): home /data and a
# regular UID. Anything else is a system account (root, nginx, sshd, nobody)
# that must neither own the webroot nor get a password set.
existing=$(awk -F: -v u="${USER}" '$1 == u { print $3 ":" $6 }' /etc/passwd)
if [ -n "${existing}" ]; then
  uid=${existing%%:*}
  home=${existing#*:}
  if [ "${home}" != "/data" ] || [ "${uid}" -lt 1000 ]; then
    echo >&2 "User ${USER} already exists as a system account (uid ${uid}, home ${home}), refusing to start."
    exit 1
  fi
  echo "User ${USER} already exists"
else
  # adduser also creates a group of the same name. If a system group already
  # has that name (wheel, shadow, www-data, ping, ...), busybox aborts with a
  # terse "group 'x' in use" - safe, but it does not say what to change.
  # Joining that group instead would be worse: wheel or shadow membership for
  # the SFTP user. So refuse here, with a message that names the problem.
  if awk -F: -v g="${USER}" '$1 == g { found = 1 } END { exit !found }' /etc/group; then
    echo >&2 "USER ${USER} clashes with an existing system group of the same name, choose another USER. Refusing to start."
    exit 1
  fi
  # busybox adduser hands out regular UIDs from 1000 upwards; the check below
  # holds it to that instead of trusting the default.
  echo "Creating user ${USER} with home /data"
  adduser -D -H -h /data "${USER}"
  uid=$(id -u "${USER}")
  if [ "${uid}" -lt 1000 ]; then
    echo >&2 "User ${USER} was created with uid ${uid} below 1000, refusing to start."
    exit 1
  fi
fi

# Set on every start, not only on creation, so a rotated PASSWORD_FILE takes
# effect on a plain restart. printf is a builtin: the password never shows up
# in a process list, and the validation above guarantees it is one line.
printf '%s:%s\n' "${USER}" "${PASSWORD}" | chpasswd

# Nothing started from here on needs the password; do not hand it down to
# nginx and sshd.
unset PASSWORD PASSWORD_FILE

# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------

# sshd refuses to chroot into a directory that is not owned by root and
# writable only by root, so /data itself stays root:root 755.
echo "Fixing permission to root in /data"
chown root:root /data
chmod 755 /data

if [ ! -d /data/webroot ]; then
  echo "Creating /data/webroot"
  mkdir -p /data/webroot
fi

# The webroot and everything in it belong to the user, so it can manage its
# files over SFTP. Only ownership is fixed - modes are left alone on purpose:
# a file the user uploaded as 0600 is meant to stay private, and widening it
# would make nginx serve it. Files must be world-readable to be served, which
# the sftp umask (022, see sshd_config) gives every new upload by default.
# BusyBox chown -R does not follow symlinks, it changes the link itself.
echo "Fixing ownership for user ${USER} in /data/webroot"
chown -R "${USER}:${USER}" /data/webroot
chmod 755 /data/webroot

# ---------------------------------------------------------------------------
# Host keys
#
# /etc/ssh/keys is usually a volume, and may well be mounted read-only
# ("-v keys:/etc/ssh/keys:ro", a Kubernetes secret). Every step below that
# could fail on such a mount says so and exits, instead of letting "set -e"
# end the container without a word.
# ---------------------------------------------------------------------------

KEY_DIR=/etc/ssh/keys
mkdir -p "${KEY_DIR}"

# A key path must be a regular file. A symlink would make the chown/chmod
# below act on whatever it points to (/etc/shadow, a file on another volume),
# and a directory or fifo would end up in front of ssh-keygen or sshd.
# "-f" alone is no check: it follows symlinks. The glob also matches dangling
# links; when it matches nothing it stays literal and "-e"/"-L" skip it.
for key in "${KEY_DIR}"/ssh_host_*_key; do
    [ -e "${key}" ] || [ -L "${key}" ] || continue
    if [ -L "${key}" ] || [ ! -f "${key}" ]; then
        echo >&2 "Host key ${key} is a symlink or not a regular file, refusing to start."
        exit 1
    fi
done

# Generate unique ssh keys for this container, if needed. On a read-only
# mount that cannot work; the keys then have to be provided on the mount.
generate_key() {
    key=${KEY_DIR}/ssh_host_$1_key
    shift
    [ -e "${key}" ] && return 0
    if ! ssh-keygen -q "$@" -f "${key}" -N ''; then
        echo >&2 "Could not generate host key ${key}. If ${KEY_DIR} is mounted read-only, it has to contain the host keys already. Refusing to start."
        exit 1
    fi
}
generate_key ed25519 -t ed25519
generate_key rsa -t rsa -b 4096

# Keys on a mounted volume may come from anywhere - copied from a backup with
# the wrong owner, or made group-readable along the way. A private host key
# readable by others is a leaked key, and sshd refuses to load it anyway.
#
# Owned by root with no group/other bits (0400 or 0600) is fine as it is; the
# group does not matter then (Kubernetes sets it to fsGroup). Only anything
# else is repaired - and a read-only mount is not touched unless it has to be.
for key in "${KEY_DIR}"/ssh_host_*_key; do
    [ -f "${key}" ] || continue
    case "$(stat -c '%u %a' "${key}")" in
        "0 400" | "0 600")
            continue
            ;;
    esac
    echo "Fixing owner/mode of ${key} to root:root 0600"
    if ! chown root:root "${key}" || ! chmod 600 "${key}"; then
        echo >&2 "Could not fix owner/mode of ${key} (read-only mount?). Provide it owned by root with mode 0400 or 0600. Refusing to start."
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Process supervision
#
# This replaces supervisord: supervisor is a Python program and dragged
# python3 + py3-setuptools into the image, ~57 MB of the ~70 MB it used to
# weigh, to keep two processes alive and kill the container when one of them
# dies. A shell can do that in a dozen lines.
#
# Each service runs in the foreground of its own subshell, which reports the
# exit to a fifo; this script blocks on that fifo. The obvious "wait -n" loop
# does not work here: busybox ash never returns from wait when a background
# child is killed, so a crashed nginx would go unnoticed and the container
# would keep answering on port 22 alone. Waiting on a foreground child is the
# reliable path, and reading a fifo is a wait that cannot be missed.
#
# The subshells inherit "set -e", which would end them the moment the service
# fails - before they report anything. "|| rc=$?" keeps the failure from
# counting as one, so the exit line is always written.
#
# tini is PID 1 (ENTRYPOINT in the Dockerfile): it forwards signals to the
# whole process group, so "docker stop" reaches both services, and it reaps
# orphans. When this script exits, tini exits, and the container is gone -
# that is what takes the surviving service down.
#
# Both services log to this script's stdout/stderr, which is the container log.
# /var/log/nginx/{access,error}.log are symlinked to stdout/stderr in the image.
# ---------------------------------------------------------------------------

EXIT_FIFO=/run/service-exited
rm -f "${EXIT_FIFO}"
mkfifo "${EXIT_FIFO}"

# Invoked through the trap below. Both codes are needed: shellcheck calls this
# "unused function" (SC2329) since 0.10 and "unreachable" (SC2317) before that,
# and CI runs whatever the runner image ships.
# shellcheck disable=SC2329,SC2317
shut_down() {
    echo "Received signal, shutting down"
    exit 0
}
trap shut_down TERM INT

echo "Starting nginx"
( rc=0; nginx -g "daemon off;" || rc=$?; echo "nginx exited with status ${rc}" > "${EXIT_FIFO}" ) &

echo "Starting sshd"
# AllowUsers on the command line rather than in sshd_config: the name is only
# known at runtime, and editing the config on every start is not idempotent
# across "docker restart". USER is validated above, so it is a single token.
( rc=0; /usr/sbin/sshd -D -e -o "AllowUsers=${USER}" || rc=$?; echo "sshd exited with status ${rc}" > "${EXIT_FIFO}" ) &

# If either service exits, the whole container goes down - a half-dead
# container that still answers on one port is worse than a restart by the
# orchestrator.
#
# The fifo is opened read-write and kept open on fd 3 (after the services are
# forked, so they do not inherit it). A blocking open or read can return early
# with EINTR when a signal such as SIGCHLD arrives; with a plain
# "read < fifo" that either ended the script under set -e without logging why,
# or dropped a line already written when the fd was closed again. Holding the
# fd keeps written lines in the pipe, so the loop simply reads again.
exec 3<> "${EXIT_FIFO}"
reason=""
while [ -z "${reason}" ]; do
    read -r reason <&3 || reason=""
done
echo >&2 "${reason}, stopping container"

exit 1
