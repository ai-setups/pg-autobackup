#!/bin/sh
# backup-entrypoint.sh — Image entry point: starts the backup scheduler next to the
# official postgres entry point, which then runs the server as usual.
#
# Usage: set by the image; containers only pass the server command (default CMD).

set -e

: "${PGBACKREST_REPO1_S3_ENDPOINT:?PGBACKREST_REPO1_S3_ENDPOINT is required}"
: "${PGBACKREST_REPO1_S3_BUCKET:?PGBACKREST_REPO1_S3_BUCKET is required}"
: "${PGBACKREST_REPO1_PATH:?PGBACKREST_REPO1_PATH is required}"
: "${PGBACKREST_REPO1_S3_KEY:?PGBACKREST_REPO1_S3_KEY is required}"
: "${PGBACKREST_REPO1_S3_KEY_SECRET:?PGBACKREST_REPO1_S3_KEY_SECRET is required}"
# In the config file rather than the environment, so pgbackrest run through
# `docker exec` connects as the same user.
echo "[main]
pg1-user=${POSTGRES_USER:-postgres}" > /etc/pgbackrest/conf.d/pg1-user.conf

if [ "$1" = postgres ]; then
    # The subshell exits at once, so tini adopts the scheduler; the postmaster that
    # replaces this process must never see it as an unknown child.
    (backup-scheduler.sh &)
    # A command-line option outranks every other configuration source, so the variable
    # has to arrive here; postgres itself rejects an invalid value at startup.
    set -- "$@" -c "archive_timeout=$PG_ARCHIVE_TIMEOUT"
fi
exec docker-entrypoint.sh "$@"
