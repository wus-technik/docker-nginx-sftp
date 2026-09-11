#!/bin/sh
set -e

# Checks for USER variable
if [ -z "$USER" ]; then
  echo >&2 'Please set an USER variable (ie.: -e USER=john).'
  exit 1
fi

# Checks for PASSWORD variable
if [ -z "$PASSWORD" ]; then
  echo >&2 'Please set a PASSWORD variable (ie.: -e PASSWORD=hackme).'
  exit 1
fi

if /usr/bin/id -u "${USER}" >/dev/null 2>&1; then
  echo "User ${USER} already exists"
else
  echo "Creating user ${USER} with home /data"
  adduser -D -H -h /data "${USER}"
  echo "${USER}:${PASSWORD}" | chpasswd
fi

if [ ! -d /data/webroot ]; then
  echo "Creating /data/webroot"
  mkdir -p /data/webroot
fi

# The folder itself must be owned by root, the contents by the user.
# X (capital) keeps directories traversable - a flat 644 would lock the user
# out of every subdirectory of its own webroot.
echo "Fixing permissions for user ${USER} in /data/webroot"
chown -R "${USER}:${USER}" /data/webroot
chmod -R u=rwX,go=rX /data/webroot
chown root:root /data/webroot
chmod 777 /data/webroot

# sshd refuses to chroot into a directory that is not owned by root and
# writable only by root, so /data itself stays root:root 755.
echo "Fixing permission to root in /data"
chown root:root /data
chmod 755 /data

# Generate unique ssh keys for this container, if needed
mkdir -p /etc/ssh/keys
if [ ! -f /etc/ssh/keys/ssh_host_ed25519_key ]; then
    ssh-keygen -t ed25519 -f /etc/ssh/keys/ssh_host_ed25519_key -N ''
fi
if [ ! -f /etc/ssh/keys/ssh_host_rsa_key ]; then
    ssh-keygen -t rsa -b 4096 -f /etc/ssh/keys/ssh_host_rsa_key -N ''
fi

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
( nginx -g "daemon off;"; echo "nginx exited with status $?" > "${EXIT_FIFO}" ) &

echo "Starting sshd"
( /usr/sbin/sshd -D -e; echo "sshd exited with status $?" > "${EXIT_FIFO}" ) &

# If either service exits, the whole container goes down - a half-dead
# container that still answers on one port is worse than a restart by the
# orchestrator.
read -r reason < "${EXIT_FIFO}"
echo >&2 "${reason}, stopping container"

exit 1
