#!/usr/bin/env python3
"""Supervisord event listener that tears the whole container down.

If nginx or sshd exits, the container must exit too - a half-dead container
that still answers on one port is worse than a restart by the orchestrator.

The listener is spawned by supervisord, so its parent pid *is* supervisord.
That beats reading a pid file, whose default location depends on supervisord's
working directory.
"""
import os
import signal
import sys


def write_stdout(s):
    sys.stdout.write(s)
    sys.stdout.flush()


def write_stderr(s):
    sys.stderr.write(s)
    sys.stderr.flush()


def main():
    while True:
        # Announce readiness, then block until supervisord sends an event.
        write_stdout('READY\n')
        line = sys.stdin.readline()
        # Diagnostics go to stderr: anything on stdout that is not part of the
        # event listener protocol puts this listener into the UNKNOWN state.
        write_stderr('This line kills supervisor: ' + line)
        try:
            os.kill(os.getppid(), signal.SIGQUIT)
        except OSError as e:
            write_stderr('Could not kill supervisor: %s\n' % e)
        write_stdout('RESULT 2\nOK')


if __name__ == '__main__':
    main()
