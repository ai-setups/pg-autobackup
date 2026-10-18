FROM postgres:17-alpine

RUN apk add --no-cache pgbackrest supercronic tini jq

COPY pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
COPY bin/ /usr/local/bin/
# Copied files keep their mode from the build context, which may be owner-only.
RUN mkdir -p /etc/pgbackrest/conf.d && chmod 644 /etc/pgbackrest/pgbackrest.conf && chmod 755 /usr/local/bin/backup-entrypoint.sh /usr/local/bin/backup-scheduler.sh /usr/local/bin/pg-restore

# Full backup schedule in crontab format (UTC); 19:00 UTC is 03:00 in China.
ENV BACKUP_CRON="0 19 * * *"
# One more full backup this long after every start, once the application has initialised
# its data, so each deploy, reset or restore has a fresh baseline.
ENV BACKUP_AFTER_START_SECONDS=600

# tini is PID 1 so it, not the postmaster, adopts and reaps the backup scheduler.
ENTRYPOINT ["/sbin/tini", "--", "backup-entrypoint.sh"]

# Every finished WAL segment goes to the repository; archive_timeout closes a segment
# at most 30 minutes after a write, which bounds what a lost host loses.
CMD ["postgres", "-c", "archive_mode=on", "-c", "archive_command=pgbackrest --stanza=main archive-push %p", "-c", "archive_timeout=1800"]
