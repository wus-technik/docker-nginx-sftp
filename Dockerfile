# Base version is an ARG so CI can pin/override it without editing the file.
ARG ALPINE_VERSION=3.24
FROM alpine:${ALPINE_VERSION}

LABEL org.opencontainers.image.title="docker-nginx-sftp" \
      org.opencontainers.image.description="wus-technik maintained nginx image serving static files that are managed over SFTP, based on upstream theomega/docker-nginx-sftp" \
      org.opencontainers.image.vendor="wus-technik" \
      org.opencontainers.image.authors="wus-technik" \
      org.opencontainers.image.source="https://github.com/wus-technik/docker-nginx-sftp" \
      org.opencontainers.image.url="https://github.com/wus-technik/docker-nginx-sftp" \
      org.opencontainers.image.documentation="https://github.com/wus-technik/docker-nginx-sftp#readme" \
      org.opencontainers.image.licenses="NOASSERTION"

# Fork origin. Upstream has not moved since 2017-08-20; d8965511 is the last
# commit that came from there. The NOASSERTION above is not an oversight:
# upstream never published a license, so there is nothing to inherit and
# nothing we could grant on top of it.
LABEL com.wus-technik.upstream.source="https://github.com/theomega/docker-nginx-sftp" \
      com.wus-technik.upstream.author="Dominik Bruhn" \
      com.wus-technik.upstream.commit="d89655117bb9cb1a6c21bbd88b02b6f7ff34c5e3"

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
