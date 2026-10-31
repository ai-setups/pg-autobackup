#!/usr/bin/env bash
# smoke.sh — Builds the image and checks the whole backup cycle against a local
# repository: initial full backup, the full backup after start, WAL archiving, the archive
# timeout (default, PG_ARCHIVE_TIMEOUT, invalid value), refusing to restore into a used
# volume, restore to the end of the archive (every row is back), point-in-time restore (a
# row written after the target is gone) and refusing to start a new instance on an
# existing repository.
#
# Usage: bash tests/smoke.sh

set -e

image=pg-autobackup:smoke
name=pg-autobackup-smoke
data=pg-autobackup-smoke-data
repo=pg-autobackup-smoke-repo
# A local repository instead of R2; the S3 variables only satisfy the entry point.
env=(-e POSTGRES_USER=app -e POSTGRES_PASSWORD=smoke -e PGBACKREST_REPO1_TYPE=posix -e PGBACKREST_REPO1_PATH=/repo
    -e PGBACKREST_REPO1_S3_ENDPOINT=unused -e PGBACKREST_REPO1_S3_BUCKET=unused
    -e PGBACKREST_REPO1_S3_KEY=unused -e PGBACKREST_REPO1_S3_KEY_SECRET=unused
    -e BACKUP_AFTER_START_SECONDS=5)
mounts=(-v "$data:/var/lib/postgresql/data" -v "$repo:/repo")

cleanup() {
    docker rm -f "$name" > /dev/null 2>&1 || true
    docker volume rm -f "$data" "$repo" > /dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

psql() {
    docker exec "$name" psql -U app -d app -tAc "$1"
}

wait_until() {
    for _ in $(seq 90); do
        if eval "$1" > /dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "timed out waiting for: $1" >&2
    docker logs --tail 50 "$name" >&2
    exit 1
}

# Extra arguments go to docker run, for options a single start needs.
start() {
    docker run -d --name "$name" "${env[@]}" "$@" "${mounts[@]}" "$image" > /dev/null
    wait_until "docker exec $name pg_isready -q -h 127.0.0.1 -U app"
}

backups() {
    docker exec "$name" gosu postgres pgbackrest --stanza=main --output=json info | jq '.[0].backup | length'
}

restore() {
    docker rm -f "$name" > /dev/null
    docker volume rm "$data" > /dev/null
    docker run --rm "${env[@]}" "${mounts[@]}" --entrypoint pg-restore "$image" "$1"
    start
    # Archiving must work again once recovery ends, and the scheduler must not have
    # stopped the container during it.
    wait_until "docker exec $name gosu postgres pgbackrest --stanza=main check"
}

expect() {
    local actual
    actual=$(psql "SELECT string_agg(note, ',' ORDER BY note) FROM smoke")
    if [[ "$actual" != "$1" ]]; then
        echo "expected rows '$1', got '$actual'" >&2
        exit 1
    fi
}

docker build -q -t "$image" "$(dirname "$0")/.." > /dev/null
docker run --rm -v "$repo:/repo" --entrypoint chown "$image" postgres:postgres /repo

expect_archive_timeout() {
    local actual
    actual=$(psql "SHOW archive_timeout")
    if [[ "$actual" != "$1" ]]; then
        echo "expected archive_timeout '$1', got '$actual'" >&2
        exit 1
    fi
}

start
expect_archive_timeout 30min
# The first backup on an empty repository, then the one BACKUP_AFTER_START_SECONDS later.
wait_until '[ "$(backups)" -ge 2 ]'

psql "CREATE TABLE smoke (note text); INSERT INTO smoke VALUES ('before')" > /dev/null
target=$(psql "SELECT now()")
sleep 1
psql "INSERT INTO smoke VALUES ('after')" > /dev/null
# check switches the WAL segment and waits until it is archived.
docker exec "$name" gosu postgres pgbackrest --stanza=main check

docker stop "$name" > /dev/null
if docker run --rm "${env[@]}" "${mounts[@]}" --entrypoint pg-restore "$image" latest 2> /dev/null; then
    echo "pg-restore must refuse a volume that still holds data" >&2
    exit 1
fi

restore latest
expect after,before

# Last, because a point-in-time restore starts a new timeline that later restores follow.
# Recovery pauses at the target, which holds the server read-only and in recovery: the
# scheduler must leave it alone until recovery ends, then archive again.
docker rm -f "$name" > /dev/null
docker volume rm "$data" > /dev/null
docker run --rm "${env[@]}" "${mounts[@]}" --entrypoint pg-restore "$image" "$target"
docker run -d --name "$name" "${env[@]}" "${mounts[@]}" "$image" postgres -c archive_mode=on \
    -c "archive_command=pgbackrest --stanza=main archive-push %p" -c recovery_target_action=pause > /dev/null
wait_until "[ \"\$(docker exec $name psql -U app -d app -tAc 'SELECT pg_is_in_recovery()')\" = t ]"
sleep 10
if [[ "$(docker inspect -f '{{.State.Running}}' "$name")" != true ]] || docker logs "$name" 2>&1 | grep -q "stanza-create command begin"; then
    echo "the scheduler acted while the server was still in recovery" >&2
    exit 1
fi
psql "SELECT pg_wal_replay_resume()" > /dev/null
wait_until "docker exec $name gosu postgres pgbackrest --stanza=main check"
expect before

docker rm -f "$name" > /dev/null
start -e PG_ARCHIVE_TIMEOUT=120
expect_archive_timeout 2min

docker rm -f "$name" > /dev/null
docker run -d --name "$name" "${env[@]}" -e PG_ARCHIVE_TIMEOUT=invalid "${mounts[@]}" "$image" > /dev/null
wait_until "[ \"\$(docker inspect -f '{{.State.Running}}' $name)\" = false ]"
if ! docker logs "$name" 2>&1 | grep -q 'invalid value for parameter "archive_timeout"'; then
    echo "an invalid PG_ARCHIVE_TIMEOUT must stop postgres at startup" >&2
    exit 1
fi

# A freshly initialised instance must not take over another instance's repository.
docker rm -f "$name" > /dev/null
docker volume rm "$data" > /dev/null
docker run -d --name "$name" "${env[@]}" "${mounts[@]}" "$image" > /dev/null
wait_until "[ \"\$(docker inspect -f '{{.State.Running}}' $name)\" = false ]"

echo "smoke test passed"
