#!/bin/sh
# backup-scheduler.sh — Waits for the server, registers the repository, checks that WAL
# archiving works and takes the first full backup when the repository has none. Then it
# takes a full backup BACKUP_AFTER_START_SECONDS after the start and on BACKUP_CRON;
# pgBackRest expires backups older than 7 days after each one. If a start-up step fails
# or the scheduler stops, the whole container stops, so a broken backup never goes
# unnoticed behind a running database.
#
# Usage: started by backup-entrypoint.sh.

set -e
trap 'kill -TERM 1' EXIT

user=${POSTGRES_USER:-postgres}
# Only the real server listens on TCP; the temporary server the official entry point
# runs while initialising a new data directory listens on the socket alone.
until pg_isready -q -h 127.0.0.1 -U "$user"; do
    sleep 2
done
# After a restore the server accepts read-only connections while it still replays WAL;
# stopping the container then would lose the recovery target, so wait until it ends.
until [ "$(gosu postgres psql -U "$user" -d postgres -tAc 'SELECT pg_is_in_recovery()')" = f ]; do
    sleep 2
done

gosu postgres pgbackrest --stanza=main stanza-create
gosu postgres pgbackrest --stanza=main check
if [ "$(gosu postgres pgbackrest --stanza=main --output=json info | jq '.[0].backup | length')" -eq 0 ]; then
    gosu postgres pgbackrest --stanza=main --type=full backup
fi

(
    sleep "$BACKUP_AFTER_START_SECONDS"
    gosu postgres pgbackrest --stanza=main --type=full backup
) &

crontab=$(mktemp)
echo "$BACKUP_CRON gosu postgres pgbackrest --stanza=main --type=full backup" > "$crontab"
supercronic "$crontab"
