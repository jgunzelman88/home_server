#!/bin/bash
set -euo pipefail

# Upgrades an EXISTING GitLab install (./gitlab chart, installed by
# ./init-gitlab.sh) from 18.x to the version pinned in gitlab/values.yaml,
# going through every required upgrade stop:
#
#   18.2 -> 18.5.7 -> 18.8.11 -> 18.11.12 -> [PostgreSQL 16 -> 17]
#        -> 19.2.7 -> 19.4.1
#
# (https://docs.gitlab.com/update/upgrade_paths/ - latest patch of each stop
# as of Sept 2026.) GitLab 19 only runs on PostgreSQL 17. Omnibus' automatic
# PG upgrade in 18.11 doesn't apply here (our Postgres is a separate
# container), so this script does it with pg_dump/pg_restore:
#   1. scale GitLab to 0 and dump the 16 database onto the Postgres PVC
#   2. start postgres:17 in a NEW data dir (postgresql.dataSubdir=pgdata-17)
#   3. restore, verify row counts, ANALYZE, bring GitLab back on 18.11
# The old 16 cluster ("pgdata") and the dump are left in place for rollback.
#
# After every stop it waits for GitLab's background migrations to finish -
# starting the next stop before they do can corrupt the upgrade.
#
# Safe to re-run: it reads the running versions and resumes where it left
# off. A backup (the nightly CronJob, run once now) is taken first.
#
# Env:
#   GITLAB_UPGRADE_YES=1          skip the confirmation prompt
#   GITLAB_SKIP_BACKUP=1          don't take the pre-upgrade backup
#   GITLAB_BG_MIGRATION_TIMEOUT   max seconds to wait per stop (default 21600)
#   GITLAB_ROLLOUT_TIMEOUT        passed to init-gitlab.sh (default here 45m)

cd "$(dirname "${BASH_SOURCE[0]}")"

namespace="gitlab"
release="gitlab"
stops_18=("18.5.7-ce.0" "18.8.11-ce.0" "18.11.12-ce.0")
# Required 19.x stops before the target (19.2 is mandatory; next is 19.5).
stops_19=("19.2.7-ce.0")
last_18="${stops_18[-1]}"
target_pg_major=17
target_pg_subdir="pgdata-17"
dump_file="/var/lib/postgresql/data/gitlab-pg16.dump"
bg_timeout="${GITLAB_BG_MIGRATION_TIMEOUT:-21600}"
export GITLAB_ROLLOUT_TIMEOUT="${GITLAB_ROLLOUT_TIMEOUT:-45m}"

# gitlab.image.tag from values.yaml (first "tag:" under the top-level gitlab: key)
target_tag=$(awk '/^gitlab:/{g=1;next} /^[^ #]/{g=0} g && /^    tag:/{gsub(/"/,"",$2); print $2; exit}' gitlab/values.yaml)

k() { kubectl -n "$namespace" "$@"; }
log() { echo; echo "=== $* ==="; }

ver() { echo "${1%%-*}"; }                      # 18.5.7-ce.0 -> 18.5.7
ver_lt() { [ "$(ver "$1")" != "$(ver "$2")" ] && [ "$(printf '%s\n%s\n' "$(ver "$1")" "$(ver "$2")" | sort -V | head -n1)" = "$(ver "$1")" ]; }

gitlab_tag() {
    k get deploy "$release" -o jsonpath='{.spec.template.spec.containers[?(@.name=="gitlab")].image}' | sed 's/.*://'
}
pg_tag() {
    k get deploy "$release-postgres" -o jsonpath='{.spec.template.spec.containers[?(@.name=="postgres")].image}' | sed 's/.*://'
}
pg_subdir() {
    basename "$(k get deploy "$release-postgres" -o jsonpath='{.spec.template.spec.containers[?(@.name=="postgres")].env[?(@.name=="PGDATA")].value}')"
}
pg_pod() {
    k get pods -l "app.kubernetes.io/instance=$release,app.kubernetes.io/component=postgresql" \
      --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'
}
psql_q() { k exec "$(pg_pod)" -- sh -c "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -tAX -c \"$1\""; }

# Until PostgreSQL is migrated, pin whatever the cluster runs right now, so
# the chart's new default (17 / pgdata-17) can't start an EMPTY database.
current_pg_args() {
    pg_args=(--set-string "postgresql.image.tag=$(pg_tag)" --set-string "postgresql.dataSubdir=$(pg_subdir)")
}

wait_background_migrations() {
    log "Waiting for background migrations to finish ($(gitlab_tag))"
    local ruby='bm = Gitlab::Database::BackgroundMigration::BatchedMigration
legacy = (Gitlab::BackgroundMigration.remaining rescue 0)
failed = (bm.with_status(:failed).count rescue 0)
puts "RESULT #{legacy} #{bm.queued.count} #{failed}"'
    local start line legacy batched failed
    start=$(date +%s)
    while true; do
        line=$(k exec "deploy/$release" -c gitlab -- gitlab-rails runner -e production "$ruby" 2>/dev/null | grep '^RESULT' || true)
        if [ -n "$line" ]; then
            read -r _ legacy batched failed <<<"$line"
            echo "  $(date +%T)  legacy=$legacy batched(queued/active)=$batched failed=$failed"
            if [ "$failed" != "0" ]; then
                echo "Error: $failed batched background migration(s) FAILED. Fix them before continuing:" >&2
                echo "  https://bwing/gitlab/admin/background_migrations  (Failed tab -> Retry)" >&2
                exit 1
            fi
            [ "$legacy" = "0" ] && [ "$batched" = "0" ] && { echo "  done."; return 0; }
        else
            echo "  $(date +%T)  (couldn't query yet - GitLab still starting?)"
        fi
        if [ $(( $(date +%s) - start )) -gt "$bg_timeout" ]; then
            echo "Error: background migrations still running after ${bg_timeout}s. Re-run this script later." >&2
            exit 1
        fi
        sleep 120
    done
}

take_backup() {
    if [ "${GITLAB_SKIP_BACKUP:-0}" = 1 ]; then echo "Skipping backup (GITLAB_SKIP_BACKUP=1)."; return; fi
    if ! k get cronjob "$release-backup" >/dev/null 2>&1; then
        echo "Error: no '$release-backup' CronJob (backup.enabled=false?). Take a backup by hand," >&2
        echo "then re-run with GITLAB_SKIP_BACKUP=1." >&2
        exit 1
    fi
    local job
    job="$release-backup-preupgrade-$(date +%Y%m%d%H%M%S)"
    log "Pre-upgrade backup (job $job)"
    k create job "$job" --from="cronjob/$release-backup"
    if ! k wait --for=condition=complete "job/$job" --timeout=4h; then
        echo "Error: backup job failed - not upgrading. See: kubectl -n $namespace logs job/$job" >&2
        exit 1
    fi
    k logs "job/$job" | tail -n 5
}

step_to() {
    log "GitLab $(gitlab_tag) -> $1"
    current_pg_args
    ./init-gitlab.sh --set-string "gitlab.image.tag=$1" "${pg_args[@]}"
    wait_background_migrations
}

migrate_postgres() {
    local pgmajor; pgmajor=$(pg_tag); pgmajor="${pgmajor%%.*}"

    if [ "$pgmajor" != "$target_pg_major" ]; then
        log "PostgreSQL $pgmajor -> $target_pg_major: dumping"
        k scale deploy "$release" --replicas=0
        k wait --for=delete pod -l "app.kubernetes.io/instance=$release,app.kubernetes.io/component=gitlab" --timeout=10m || true

        psql_q "select (select count(*) from projects)||' '||(select count(*) from users)||' '||(select count(*) from namespaces)||' '||(select count(*) from ci_builds)" \
          > /tmp/gitlab-pg-counts-before 2>/dev/null \
          || psql_q "select (select count(*) from projects)||' '||(select count(*) from users)||' '||(select count(*) from namespaces)" > /tmp/gitlab-pg-counts-before
        echo "Row counts before: $(cat /tmp/gitlab-pg-counts-before)"

        local db_bytes free_kb
        db_bytes=$(psql_q "select pg_database_size(current_database())")
        free_kb=$(k exec "$(pg_pod)" -- df -Pk /var/lib/postgresql/data | awk 'NR==2{print $4}')
        echo "DB size: $((db_bytes/1024/1024)) MiB, free on PVC: $((free_kb/1024)) MiB"
        if [ $((free_kb*1024)) -lt $((db_bytes*2)) ]; then
            echo "Error: need ~2x the DB size free on the Postgres PVC (dump + new cluster)." >&2
            echo "Grow postgresql.persistence.size / the PVC, then re-run." >&2
            exit 1
        fi

        k exec "$(pg_pod)" -- sh -c "pg_dump -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -Fc -f $dump_file.tmp && mv $dump_file.tmp $dump_file && ls -lh $dump_file"

        log "Starting postgres:$target_pg_major in a fresh data dir ($target_pg_subdir), GitLab kept at 0"
        ./init-gitlab.sh --set-string "gitlab.image.tag=$last_18" --set gitlab.replicas=0
        k rollout status "deploy/$release-postgres" --timeout=5m
    fi

    # Restore if the new cluster is still empty (also resumes a failed run -
    # the restore is one transaction, so a failure leaves it empty again).
    if [ "$(psql_q "select to_regclass('public.schema_migrations') is not null")" != "t" ]; then
        log "Restoring the dump into PostgreSQL $target_pg_major"
        k scale deploy "$release" --replicas=0
        k exec "$(pg_pod)" -- sh -c "test -s $dump_file && pg_restore -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" --no-owner --single-transaction --exit-on-error $dump_file"
        k exec "$(pg_pod)" -- sh -c "vacuumdb -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" --analyze-only"

        if [ -f /tmp/gitlab-pg-counts-before ]; then
            local after
            after=$(psql_q "select (select count(*) from projects)||' '||(select count(*) from users)||' '||(select count(*) from namespaces)||' '||(select count(*) from ci_builds)" 2>/dev/null \
              || psql_q "select (select count(*) from projects)||' '||(select count(*) from users)||' '||(select count(*) from namespaces)")
            echo "Row counts before: $(cat /tmp/gitlab-pg-counts-before)  after: $after"
            if [ "$after" != "$(cat /tmp/gitlab-pg-counts-before)" ]; then
                echo "Error: row counts differ - NOT starting GitLab. The old cluster is untouched (see rollback below)." >&2
                exit 1
            fi
        fi
    fi
    echo "PostgreSQL now: $(psql_q 'show server_version')"

    log "Bringing GitLab $last_18 back up on PostgreSQL $target_pg_major"
    ./init-gitlab.sh --set-string "gitlab.image.tag=$last_18"
    wait_background_migrations
}

# ---------------------------------------------------------------------------
current=$(gitlab_tag)
echo "GitLab now:     $current   (PostgreSQL $(pg_tag), PGDATA .../$(pg_subdir))"
echo "Target:         $target_tag (PostgreSQL $target_pg_major)"
echo "Path:           ${stops_18[*]} -> PG $target_pg_major -> ${stops_19[*]} -> $target_tag"

if ver_lt "$current" "18.2.0"; then
    echo "Error: $current is older than the 18.2 stop - upgrade to 18.2 first." >&2; exit 1
fi
if [ "$(ver "$current")" = "$(ver "$target_tag")" ]; then echo "Already on $target_tag."; exit 0; fi

if [ "${GITLAB_UPGRADE_YES:-0}" != 1 ]; then
    echo
    echo "GitLab will be down for several restarts (and fully down during the PG dump/restore)."
    read -r -p "Continue? [y/N] " ans; [ "$ans" = y ] || [ "$ans" = Y ] || exit 1
fi

if [ "$(k get deploy "$release" -o jsonpath='{.status.readyReplicas}')" = "1" ]; then
    # Don't start on top of unfinished migrations from a previous upgrade.
    wait_background_migrations
    take_backup
else
    echo "GitLab isn't running (resuming an interrupted PostgreSQL migration?) - skipping pre-checks and backup."
fi

for stop in "${stops_18[@]}"; do
    if ver_lt "$(gitlab_tag)" "$stop"; then step_to "$stop"; fi
done

pgmajor=$(pg_tag); pgmajor="${pgmajor%%.*}"
if [ "$pgmajor" != "$target_pg_major" ] || [ "$(psql_q "select to_regclass('public.schema_migrations') is not null")" != "t" ]; then
    migrate_postgres
fi

for stop in "${stops_19[@]}"; do
    if ver_lt "$(gitlab_tag)" "$stop" && ver_lt "$stop" "$target_tag"; then step_to "$stop"; fi
done

log "GitLab $(gitlab_tag) -> $target_tag (chart defaults)"
./init-gitlab.sh
wait_background_migrations

echo
echo "--- Upgrade complete: GitLab $(gitlab_tag), PostgreSQL $(psql_q 'show server_version') ---"
echo "Check https://bwing/gitlab/admin (Admin -> Monitoring -> Background migrations / Health check)."
echo
echo "Kept on the Postgres PVC for rollback: .../pgdata (PG 16 cluster) and $dump_file."
echo "Once you're happy, free the space with:"
echo "  kubectl -n $namespace exec deploy/$release-postgres -- rm -rf /var/lib/postgresql/data/pgdata $dump_file"
echo
echo "Rollback (before cleanup): back to 18.11 on the untouched PG 16 cluster - loses every DB change made after the dump:"
echo "  ./init-gitlab.sh --set-string gitlab.image.tag=$last_18 --set-string postgresql.image.tag=16 --set-string postgresql.dataSubdir=pgdata"
