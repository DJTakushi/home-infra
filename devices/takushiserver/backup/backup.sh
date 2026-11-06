#!/usr/bin/env bash
# Backs up takushiserver with restic to every repository in BACKUP_REPOS. See BACKUPS.md at the
# repo root for setup and restore. Run as root (it reads every service's data folder).
#
#   backup.sh run           dump the databases, back up, apply retention (default; what the timer runs)
#   backup.sh init          create any repository in BACKUP_REPOS that doesn't exist yet
#   backup.sh check         verify every repository, reading a sample of its data
#   backup.sh restic ARGS   any restic command against the first repository, e.g. `snapshots`;
#                           add `-r <repo>` to pick another
set -euo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
SERVER_DIR=$(dirname "$HERE")
REPO_ROOT=$(cd "$SERVER_DIR/../.." && pwd)
CONFIG=${BACKUP_CONFIG:-$HERE/backup.env}

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
die() { log "error: $*" >&2; exit 1; }

[[ -r $CONFIG ]] || die "no config at $CONFIG - copy backup.example.env to backup.env and fill it in"
set -a
# shellcheck source=backup.example.env
. "$CONFIG"
set +a
: "${BACKUP_REPOS:?set BACKUP_REPOS in $CONFIG}"
: "${RESTIC_PASSWORD_FILE:?set RESTIC_PASSWORD_FILE in $CONFIG}"
[[ -r $RESTIC_PASSWORD_FILE ]] || die "can't read RESTIC_PASSWORD_FILE ($RESTIC_PASSWORD_FILE)"
read -r -a REPOS <<<"$BACKUP_REPOS"
STAGING=${BACKUP_STAGING:-/var/tmp/takushiserver-backup}
HOST_TAG=takushiserver

# A value from the server's .env (the last KEY=value line, comment and quotes stripped), or $2.
env_value() {
  local v
  v=$(grep -E "^[[:space:]]*$1=" "$SERVER_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2-) || true
  v=$(xargs <<<"${v%%#*}")
  printf '%s' "${v:-${2:-}}"
}

# A path from .env as Compose sees it: ~ is the home of whoever owns this folder (Compose runs as
# that user, this script as root), and relative paths start from the compose file's folder.
env_path() {
  local p; p=$(env_value "$1" "$2")
  if [[ $p == "~"* ]]; then
    p=$(getent passwd "$(stat -c %U "$SERVER_DIR")" | cut -d: -f6)${p#\~}
  fi
  [[ $p == /* ]] || p=$SERVER_DIR/${p#./}
  printf '%s' "$p"
}

# Hides any user:password in a repository URL before it reaches the log.
label() { sed -E 's#(//)[^@/]*@#\1***@#' <<<"$1"; }

ping_hc() { # $1: "" (success), /start or /fail; $2: message body
  local url=${HEALTHCHECK_URL:-}
  [[ -n $url ]] || return 0
  curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "${2:-}" "$url$1" || log "warning: healthcheck ping failed"
}

# Backup and check share one lock (restic can't verify a repository mid-backup); each waits up
# to two hours for the other to finish.
take_lock() {
  exec 9>"$STAGING.lock"
  flock -w 7200 9 || die "timed out waiting for another backup or check to finish"
}

running() { [[ $(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null) == true ]]; }

dump_immich_db() {
  running immich_postgres || { log "immich_postgres isn't running"; return 1; }
  docker exec immich_postgres pg_dumpall --clean --if-exists --username="$(env_value DB_USERNAME postgres)" \
    | gzip >"$STAGING/immich-db.sql.gz"
}

dump_forgejo() {
  running forgejo || { log "forgejo isn't running"; return 1; }
  docker exec forgejo rm -f /tmp/forgejo-dump.zip || return 1
  docker exec -u git forgejo forgejo dump -c /data/gitea/conf/app.ini --tempdir /tmp \
    -f /tmp/forgejo-dump.zip >/dev/null || return 1
  docker cp -q forgejo:/tmp/forgejo-dump.zip "$STAGING/forgejo-dump.zip" || return 1
  docker exec forgejo rm -f /tmp/forgejo-dump.zip
}

# CouchDB is stopped for the few seconds the copy takes, so the files are consistent. Devices
# retry and catch up on their own.
copy_couchdb() {
  local src rc=0
  src=$(env_path COUCHDB_DATA_LOCATION ./couchdb)
  if ! docker inspect couchdb >/dev/null 2>&1; then
    log "no couchdb container; skipping Obsidian sync data"
    return 0
  fi
  [[ -d $src ]] || { log "couchdb data folder $src is missing"; return 1; }
  docker stop couchdb >/dev/null || return 1
  cp -a "$src" "$STAGING/couchdb" || rc=1
  docker start couchdb >/dev/null || { log "couchdb didn't start again"; rc=1; }
  return $rc
}

cmd_run() {
  local failures=() lib repo
  take_lock
  ping_hc /start

  rm -rf "$STAGING" && install -d -m 700 "$STAGING"
  log "dumping databases into $STAGING"
  dump_immich_db || failures+=("Immich database dump")
  dump_forgejo || failures+=("Forgejo dump")
  copy_couchdb || failures+=("CouchDB copy")

  lib=$(env_path UPLOAD_LOCATION "")
  [[ -n $lib && -d $lib ]] || { failures+=("Immich library not found ($lib)"); lib=; }

  # This repo (including .env, tailscale/ and etc-pihole/), the dumps, and the photo library.
  # Raw database folders are left out: the dumps above are their consistent copies. Thumbnails
  # and transcoded videos are left out because Immich regenerates them (Administration -> Jobs).
  local paths=("$REPO_ROOT" "$STAGING") excludes=(
    --exclude "$(env_path DB_DATA_LOCATION ./postgres)"
    --exclude "$(env_path FORGEJO_DATA_LOCATION ./forgejo)"
    --exclude "$(env_path COUCHDB_DATA_LOCATION ./couchdb)"
  )
  if [[ -n $lib ]]; then
    paths+=("$lib")
    excludes+=(--exclude "$lib/thumbs" --exclude "$lib/encoded-video")
  fi

  for repo in "${REPOS[@]}"; do
    log "backing up to $(label "$repo")"
    if ! restic -r "$repo" backup --host "$HOST_TAG" --tag nightly --exclude-caches \
      "${excludes[@]}" "${paths[@]}"; then
      failures+=("backup to $(label "$repo")")
      continue
    fi
    restic -r "$repo" forget --host "$HOST_TAG" --prune \
      --keep-daily "${KEEP_DAILY:-7}" --keep-weekly "${KEEP_WEEKLY:-4}" \
      --keep-monthly "${KEEP_MONTHLY:-12}" || failures+=("retention on $(label "$repo")")
  done

  if ((${#failures[@]})); then
    printf -v msg '%s; ' "${failures[@]}"
    log "finished with failures: ${msg%; }"
    ping_hc /fail "failed: ${msg%; }"
    exit 1
  fi
  log "backup finished"
  ping_hc "" "ok"
}

cmd_init() {
  local repo
  for repo in "${REPOS[@]}"; do
    if restic -r "$repo" cat config >/dev/null 2>&1; then
      log "$(label "$repo") already exists"
    else
      restic -r "$repo" init
    fi
  done
}

cmd_check() {
  local repo rc=0
  take_lock
  for repo in "${REPOS[@]}"; do
    log "checking $(label "$repo")"
    restic -r "$repo" check --read-data-subset="${CHECK_SUBSET:-5%}" || rc=1
  done
  if ((rc)); then
    HEALTHCHECK_URL=${HEALTHCHECK_CHECK_URL:-} ping_hc /fail "check failed"
  else
    HEALTHCHECK_URL=${HEALTHCHECK_CHECK_URL:-} ping_hc "" "ok"
  fi
  return $rc
}

case ${1:-run} in
  run) cmd_run ;;
  init) cmd_init ;;
  check) cmd_check ;;
  restic) shift; exec restic -r "${REPOS[0]}" "$@" ;;
  *) die "usage: $0 [run|init|check|restic ARGS]" ;;
esac
