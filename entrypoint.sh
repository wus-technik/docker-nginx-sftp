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

exec /usr/bin/supervisord -n -c /etc/supervisord.conf
