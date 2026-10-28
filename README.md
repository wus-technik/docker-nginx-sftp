docker-nginx-sftp
=================
[![ci](https://github.com/wus-technik/docker-nginx-sftp/actions/workflows/ci.yml/badge.svg)](https://github.com/wus-technik/docker-nginx-sftp/actions/workflows/ci.yml) [![build](https://github.com/wus-technik/docker-nginx-sftp/actions/workflows/build.yml/badge.svg)](https://github.com/wus-technik/docker-nginx-sftp/actions/workflows/build.yml)

Maintained by W&S Technik GmbH. Fork of
[theomega/docker-nginx-sftp](https://github.com/theomega/docker-nginx-sftp) by
Dominik Bruhn - see [Credits](#credits).

Purpose
-------
The image provides an http server which serves static files. The static files
can be modified using sftp. This is done by launching both, an http server
(nginx) and an sftp server (openssh-sftp) inside the docker container. The
static files can be persisted on a volume to make them survive restarts of the
container.

This container allows to host a website on a docker host where some third party
(who knows the credentials) can modify the website via any sftp client. There
are sftp clients for nearly all operating systems.

Usage
-----
To run this container use

     docker run -ti -e USER=myuser -e PASSWORD=mypassword -p 2222:22 -p 8888:80 \
       -v /tmp/data_for_container:/data -v /tmp/keys_for_container:/etc/ssh/keys/ \
       ghcr.io/wus-technik/docker-nginx-sftp:stable

You can then using any sftp client connect to localhost:2222 and put files into
the /webroot folder. You need to log in with the provided username and password.
Files from the /webroot folder are served then via http on
http://localhost:8888.

Image tags
----------
Images are published to GitHub Container Registry as
`ghcr.io/wus-technik/docker-nginx-sftp`:

  * `stable` - the newest release tag (`X.Y.Z`), this is what deployments should
    follow
  * `X.Y.Z` - a specific release; prerelease tags (`X.Y.Z-rc1`) are published
    under their own tag only and never move `stable`
  * `latest` - the current state of `master` (staging, may break)
  * `master-<short sha>` - a specific `master` build

Images are built for `linux/amd64`, `linux/arm64` and `linux/arm/v7`.

Configuration
-------------
There are two environment variables which you have to provide when launching the
container to specify the username and the password which can then be used to log
into the sftp server. These are called `USER` and `PASSWORD`. The container
refuses to start if either of them is missing.

Instead of `PASSWORD` you can set `PASSWORD_FILE` to the path of a file that
contains the password, typically a Docker or Compose secret:

     docker run -e USER=myuser -e PASSWORD_FILE=/run/secrets/sftp_password ...

This keeps the password out of `docker inspect`. Trailing newlines in the file
are ignored. Setting both `PASSWORD` and `PASSWORD_FILE`, or pointing
`PASSWORD_FILE` at a missing, unreadable or empty file, stops the container.
Either way both variables are removed before nginx and sshd start, so the
services never see the password in their environment. The password is set on
every start, so a changed secret takes effect on the next restart.

The container refuses to start, before it touches any file, if

  * `USER` is not a plain login name (`^[a-z_][a-z0-9_-]{0,31}$`),
  * `USER` names an existing system account such as `root`, `nginx` or `sshd`
    (only an account this image created itself - home `/data`, UID 1000 or
    higher - is accepted, which is what a `docker restart` finds),
  * the password contains a line break (CR or LF).

Only `USER` can log in over SSH (`AllowUsers`), only SFTP is offered, and the
session is chrooted to `/data`. Forwarding of any kind is disabled.

The container listens on two ports, 22 for the sftp server and 80 for the http
server. The container intentionally does not provide an SSL/HTTPS interface as
this can be handled using other docker container easily.

A `HEALTHCHECK` polls `http://127.0.0.1/internal/health`, which is served by
nginx's `stub_status`. The endpoint only answers requests from inside the
container (127.0.0.1); everyone else gets a 403.

Serving rules
-------------
nginx serves `/data/webroot` with a few deliberate exceptions, because its
content comes from an SFTP user rather than from the operator:

  * **File modes are respected.** A file is only served if it is
    world-readable (e.g. `0644`, directories `0755`). Uploads get that by
    default - sftp runs with umask `022`. A file chmodded to `0600` stays
    private and gets a 403. Earlier versions of this image ran
    `chmod -R go=rX` over the webroot on every start and so published such
    files anyway; that is gone. On start the image now only fixes the
    *ownership* of the webroot and its contents (everything belongs to
    `USER`), never the modes. Files copied into the volume from outside must
    be made readable by whoever puts them there.
  * **Symlinks are not followed** (`disable_symlinks on`): any path that
    contains a symlink gets a 403. Otherwise a link to `/etc/passwd` would be
    served as part of the site.
  * **Dotfiles are hidden**: `.env`, `.git/`, `.htaccess` and friends answer
    404. `/.well-known/` is the exception (ACME, `security.txt`); dotfiles
    inside it are hidden as well.

Volumes
-------
You can mount two volumes to the docker-images as in the example above:

  * `/data` is the folder which contains the static files which are served from
    the nginx http server and can be modified via sftp.
  * `/etc/ssh/keys` is the folder which contains the ssh host keys for the sftp
    server. If the host keys are not existing, they are created on start.
    Without a mount, Docker keeps them in an anonymous volume: they survive
    `docker restart` and `docker stop`/`start`, but every recreate (new image,
    `docker compose up` after a config change, `docker rm` + `docker run`)
    generates new keys, and sftp clients then warn about a changed host key.
    Mount this folder to keep the keys across recreates. Private keys found
    here are reset to owner root and mode `0600` before sshd starts (the
    container log says so when it happens).

Internals
---------
The internals of this image are quiet straight forward. The container is based
on alpine linux, pinned by tag and digest in the `FROM` line of the
`Dockerfile` (`alpine:3.24@sha256:...`, so Dependabot can propose updates to
both), and contains the following additional packages:
  * `openssh-server` and `openssh-sftp-server` to provide the sftp server
  * `nginx` to provide the http server
  * `tini` as PID 1, which forwards signals to both services and reaps orphans

The packages are configured using the configuration files in this repo. All the
logging goes to the docker output, so you will see both, the nginx access log
and the sftp connection output.

`entrypoint.sh` starts both services and exits non-zero as soon as one of them
exits - a half-dead container that still answers on one port is worse than a
restart by the orchestrator. It does that by running each service in a subshell
that reports the exit through a fifo, because busybox ash never returns from
`wait` for a killed background child.

This used to be `supervisord` plus a python eventlistener (`docker_kill.py`).
supervisor is a python program, so it pulled `python3` and `py3-setuptools`
into the image: 100 MB then against 20 MB now, for orchestrating two
processes.

Development
-----------
`ci/smoke-test.sh` runs the built image and asserts on its behaviour - bad
configuration (missing credentials, system accounts as `USER`, line breaks in
the password) is rejected, nginx serves the webroot, an sftp login is chrooted
and its uploads show up over http byte for byte, symlinks, dotfiles and `0600`
files are not served, the health endpoint is internal, `PASSWORD_FILE` works
and the password stays out of the services' environment, a dying service takes
the container down with a logged reason, and host keys survive a restart with
owner and mode enforced:

     docker build -t nginx-sftp:test .
     ./ci/smoke-test.sh nginx-sftp:test

The same test runs in CI (`.github/workflows/ci.yml`) on every push and before
every push to the registry (`.github/workflows/build.yml`).

Credits
-------
This image started as a fork of
[theomega/docker-nginx-sftp](https://github.com/theomega/docker-nginx-sftp) by
Dominik Bruhn. Commit `d8965511` (2017-08-20) is the last one that came from
there; the original idea, layout and most of the configuration files are his.

Everything since is maintained by W&S Technik GmbH: current alpine base, CI and
the published images on GHCR, the smoke test, and the replacement of supervisord
with tini.

Upstream never published a license, so there is nothing we can relicense or
sublicense - the image labels carry `NOASSERTION` rather than a license we made
up. If you intend to use this image outside W&S Technik, clarify that first.

Anti-Pattern
------------
To have two processes in a docker container is an anti-pattern, so think twice
before using this image. The normal way to do this would be to have two separate
docker images, one for the sftp server and one for the http server and have a
shared volume. This container takes another approach for experimentation
purposes.
