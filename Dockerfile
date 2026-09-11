# Base version is an ARG so CI can pin/override it without editing the file.
ARG ALPINE_VERSION=3.24
FROM alpine:${ALPINE_VERSION}

LABEL org.opencontainers.image.title="docker-nginx-sftp" \
      org.opencontainers.image.description="nginx serving static files that are managed over SFTP" \
      org.opencontainers.image.source="https://github.com/wus-technik/docker-nginx-sftp" \
      org.opencontainers.image.licenses="MIT"

# No supervisor: it is a Python program and pulled python3 + py3-setuptools
# into the image (~57 MB) to keep two processes alive. entrypoint.sh does that
# itself, with tini (23 KiB) as PID 1 - see the comment there on why the shell
# must not be PID 1.
RUN apk add --no-cache nginx openssh-server openssh-sftp-server tini

# NGINX
RUN mkdir -p /run/nginx/ && \
    ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log
# Alpine's nginx includes /etc/nginx/http.d/, not conf.d; this replaces the
# default vhost shipped by the package.
COPY nginx.conf /etc/nginx/http.d/default.conf

# SSH/SFTP
COPY sshd_config /etc/ssh/sshd_config

# Init / process supervision
COPY entrypoint.sh /

# Configuration for Container
VOLUME /data /etc/ssh/keys/
EXPOSE 22 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1/internal/health || exit 1

# Creates users, checks permissions, generates host-keys and runs the services
ENTRYPOINT ["/sbin/tini", "-g", "--"]
CMD ["/entrypoint.sh"]
