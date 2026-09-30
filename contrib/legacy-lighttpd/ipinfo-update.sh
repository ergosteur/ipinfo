#!/usr/bin/env bash
#
# ipinfo-update -- update the ORIGINAL ipinfo host (lighttpd + gunicorn) from a GitHub release.
#
#   >>> LEGACY / SPECIAL CASE <<<
#   This is NOT the supported way to deploy ipinfo. It exists for one hand-built host
#   (britta.asdfghjkl.ca, which fronts gunicorn with lighttpd rather than Caddy/Traefik) that
#   deploy.sh and docker compose cannot manage. See contrib/legacy-lighttpd/README.md.
#   Do not run it on a deploy.sh or Docker install.
#
# What it does (nothing is switched until the new tree has been built and smoke-tested):
#   1. clone the release tag next to the live tree, build a venv, install requirements
#   2. smoke-test the new tree in-process as the service user
#   3. stop the service, swap directories (keeping the old tree and moving logs/ across),
#      start it, and verify through the real gunicorn socket
#   4. roll back automatically if verification fails
#
# Usage: ipinfo-update [--check | --build-only | --force | --rollback] [TAG]
#   (no TAG)      update to the newest non-pre-release v* tag
#   TAG           update (or roll back) to that specific tag, e.g. v0.2.4-4.10.222A
#   --check       show current / latest version and exit; changes nothing
#   --build-only  build and smoke-test the new tree, then discard it; does not touch the service
#   --force       rebuild and swap even if already on TAG
#   --rollback    swap back to the newest kept previous tree (must have its own venv)
#
# Run as root or as a user with passwordless sudo. Settings can be overridden with
# IPINFO_REPO_URL, IPINFO_APP_DIR, IPINFO_SERVICE, IPINFO_APP_USER, IPINFO_ENV_FILE,
# IPINFO_SOCKET, IPINFO_KEEP_OLD, IPINFO_MIN_FREE_MB and IPINFO_LOCK.

set -uo pipefail

REPO_URL="${IPINFO_REPO_URL:-https://github.com/ergosteur/ipinfo.git}"
APP_DIR="${IPINFO_APP_DIR:-/srv/ipinfo}"
SERVICE="${IPINFO_SERVICE:-ipinfo}"
APP_USER="${IPINFO_APP_USER:-ipinfo}"
ENV_FILE="${IPINFO_ENV_FILE:-/etc/ipinfo/ipinfo.env}"
SOCK="${IPINFO_SOCKET:-/run/ipinfo/ipinfo.sock}"
KEEP_OLD="${IPINFO_KEEP_OLD:-2}"
MIN_FREE_MB="${IPINFO_MIN_FREE_MB:-300}"

MODE=update
FORCE=0
TAG=""

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "== $*"; }

usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' ; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check)      MODE=check ;;
    --build-only) MODE=build-only ;;
    --rollback)   MODE=rollback ;;
    --force)      FORCE=1 ;;
    -h|--help)    usage; exit 0 ;;
    -*)           die "unknown option: $1 (try --help)" ;;
    *)            [ -z "$TAG" ] || die "only one TAG may be given"; TAG="$1" ;;
  esac
  shift
done

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# Run a command as the service user (git ownership checks want the repo owner).
as_app() {
  if [ "$(id -u)" -eq 0 ]; then runuser -u "$APP_USER" -- "$@"; else sudo -u "$APP_USER" "$@"; fi
}

env_val() { $SUDO sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | tail -1; }

current_version() {
  as_app git -C "$APP_DIR" describe --tags --exact-match 2>/dev/null \
    || as_app git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null \
    || echo "unknown"
}

latest_tag() {
  git ls-remote --tags --refs "$REPO_URL" 'v*' 2>/dev/null \
    | awk '{sub("refs/tags/", "", $2); print $2}' \
    | grep -viE -- '-(rc|beta|alpha)' | sort -V | tail -1
}

# ---------------------------------------------------------------- preflight
[ -d "$APP_DIR/.git" ] || die "$APP_DIR is not a git checkout (is this the legacy lighttpd host?)"
$SUDO systemctl cat "$SERVICE" 2>/dev/null | grep -q 'venv/bin/python -m gunicorn' \
  || die "the $SERVICE unit does not use '$APP_DIR/venv/bin/python -m gunicorn'; this script only supports that layout (see README)"

BASE_DOMAIN="$(env_val BASE_DOMAIN)"
[ -n "$BASE_DOMAIN" ] || die "BASE_DOMAIN is not set in $ENV_FILE"
PROXY_COUNT="$(env_val TRUSTED_PROXY_COUNT)"; PROXY_COUNT="${PROXY_COUNT:-1}"
case "$PROXY_COUNT" in ''|*[!0-9]*) die "TRUSTED_PROXY_COUNT in $ENV_FILE is not a number: $PROXY_COUNT" ;; esac

CUR_VER="$(current_version)"

if [ "$MODE" = check ]; then
  LATEST="$(latest_tag)"
  echo "installed: $CUR_VER"
  echo "latest:    ${LATEST:-<could not reach $REPO_URL>}"
  if [ -n "$LATEST" ] && [ "$LATEST" != "$CUR_VER" ]; then echo "update available -> ipinfo-update"; else echo "up to date"; fi
  exit 0
fi

exec 9>"${IPINFO_LOCK:-/run/lock/ipinfo-update.lock}" || die "cannot open lock file"
flock -n 9 || die "another ipinfo-update is already running"

FREE_MB="$(df -Pm "$(dirname "$APP_DIR")" | awk 'NR==2 {print $4}')"
[ "${FREE_MB:-0}" -ge "$MIN_FREE_MB" ] || die "only ${FREE_MB:-?} MB free near $APP_DIR (need $MIN_FREE_MB)"

TS="$(date +%Y%m%d-%H%M%S)"
NEW="$APP_DIR.new"
OLD="$APP_DIR.old-$TS"

# ---------------------------------------------------------------- verification
# Talk to gunicorn directly over its socket, exactly as lighttpd does.
verify_live() {
  local i hdr body code path
  local -a xff=() paths=(/ /98 /json)

  # Over a unix socket there is no peer address, so without X-Forwarded-For the app has no client IP
  # at all (and /iponly answers 500). Send it exactly as lighttpd does. TRUSTED_PROXY_COUNT=0 means
  # the app ignores the header and can never know the client here, so /iponly is skipped then.
  if [ "$PROXY_COUNT" -gt 0 ]; then
    hdr="203.0.113.9"
    for i in $(seq 2 "$PROXY_COUNT"); do hdr="$hdr, 198.51.100.$i"; done
    xff=(-H "X-Forwarded-For: $hdr")
    paths+=(/iponly)
  fi

  for i in $(seq 1 20); do
    $SUDO systemctl is-active --quiet "$SERVICE" && [ -S "$SOCK" ] && break
    sleep 1
  done
  $SUDO systemctl is-active --quiet "$SERVICE" || { echo "verify: service is not active"; return 1; }

  for path in "${paths[@]}"; do
    code="$($SUDO curl -s -o /dev/null -w '%{http_code}' --max-time 10 --unix-socket "$SOCK" \
            -H "Host: ip.$BASE_DOMAIN" "${xff[@]}" "http://localhost$path")"
    [ "$code" = 200 ] || { echo "verify: GET $path returned $code"; return 1; }
  done

  body="$($SUDO curl -s --max-time 10 --unix-socket "$SOCK" -H "Host: ip.$BASE_DOMAIN" "${xff[@]}" http://localhost/json)"
  if [ "$PROXY_COUNT" -gt 0 ]; then
    echo "$body" | grep -q '"IPv4": *"203.0.113.9"' || { echo "verify: /json did not report the forwarded client IP: $body"; return 1; }
  else
    echo "$body" | grep -q '"IPv4"' || { echo "verify: /json is not the expected document: $body"; return 1; }
  fi
  echo "verify: OK (active; ${paths[*]} = 200; /json correct via $SOCK)"
}

# Move the tree at $2 into place, retiring the live tree to $1; carries logs/ along.
swap_trees() {
  local retire_to="$1" bring_in="$2"
  $SUDO mv "$APP_DIR" "$retire_to" && $SUDO mv "$bring_in" "$APP_DIR" || return 1
  if [ -d "$retire_to/logs" ] && [ ! -e "$APP_DIR/logs" ]; then
    $SUDO mv "$retire_to/logs" "$APP_DIR/logs" || echo "warning: could not move logs/ to the new tree (left in $retire_to)"
  fi
  return 0
}

# Undo swap_trees: put $1 (the tree we retired) back, park the failed one at $2.
undo_swap() {
  local retired="$1" failed="$2"
  $SUDO systemctl stop "$SERVICE" || true
  if [ -d "$APP_DIR/logs" ] && [ ! -e "$retired/logs" ]; then $SUDO mv "$APP_DIR/logs" "$retired/logs"; fi
  [ -d "$APP_DIR" ] && $SUDO mv "$APP_DIR" "$failed"
  $SUDO mv "$retired" "$APP_DIR"
  $SUDO systemctl start "$SERVICE"
  sleep 2
  if verify_live; then echo "restored the previous version (failed tree kept at $failed)"; else echo "!!! previous version did not verify either - needs manual attention"; fi
}

# ---------------------------------------------------------------- rollback mode
if [ "$MODE" = rollback ]; then
  PREV="$(ls -d "$APP_DIR".old-* 2>/dev/null | sort | tail -1)"
  [ -n "$PREV" ] || die "no previous tree ($APP_DIR.old-*) to roll back to"
  [ -x "$PREV/venv/bin/python" ] || die "$PREV has no venv (it predates this layout) - restore it by hand, see README"
  info "rolling back: $CUR_VER -> $PREV"
  RETIRED="$APP_DIR.replaced-$TS"
  $SUDO systemctl stop "$SERVICE"
  swap_trees "$RETIRED" "$PREV" || { $SUDO systemctl start "$SERVICE"; die "could not swap directories"; }
  $SUDO systemctl start "$SERVICE"
  if verify_live; then echo "rolled back to $(current_version); replaced tree kept at $RETIRED"; exit 0; fi
  echo "!! rolled-back tree failed verification, undoing the rollback"
  undo_swap "$RETIRED" "$PREV"
  exit 1
fi

# ---------------------------------------------------------------- update mode
[ -n "$TAG" ] || TAG="$(latest_tag)"
[ -n "$TAG" ] || die "could not determine the latest release tag from $REPO_URL"
git ls-remote --exit-code --tags --refs "$REPO_URL" "refs/tags/$TAG" >/dev/null 2>&1 \
  || die "tag $TAG not found in $REPO_URL"

if [ "$TAG" = "$CUR_VER" ] && [ "$FORCE" -eq 0 ] && [ "$MODE" = update ]; then
  echo "already on $TAG (use --force to rebuild it)"; exit 0
fi

[ ! -e "$NEW" ] || die "$NEW already exists (leftover from an interrupted run?); inspect and remove it first"

CREATED_NEW=0
cleanup() { if [ "$CREATED_NEW" -eq 1 ] && [ -d "$NEW" ]; then $SUDO rm -rf "$NEW"; fi; }
trap cleanup EXIT

info "building $TAG (currently $CUR_VER)"
$SUDO git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" "$REPO_URL" "$NEW" || true
[ -d "$NEW/.git" ] || die "clone of $TAG failed"
CREATED_NEW=1
echo "checked out $(git -C "$NEW" describe --tags --always 2>/dev/null || echo "$TAG")"

$SUDO python3 -m venv "$NEW/venv" || die "could not create venv (is python3-venv installed?)"
grep -viE '^pytest' "$NEW/requirements.txt" | $SUDO tee "$NEW/.runtime-requirements.txt" >/dev/null
if ! PIP_OUT="$($SUDO "$NEW/venv/bin/pip" install --no-cache-dir -q -r "$NEW/.runtime-requirements.txt" 2>&1)"; then
  echo "$PIP_OUT"; die "pip install failed; nothing was changed"
fi
$SUDO chown -R "$APP_USER:$APP_USER" "$NEW"

info "smoke-testing the new tree in-process as $APP_USER (live service untouched)"
( cd "$NEW" && as_app env BASE_DOMAIN="$BASE_DOMAIN" STRICT_HOST_CHECK=true TRUSTED_PROXY_COUNT="$PROXY_COUNT" \
    "$NEW/venv/bin/python" - "$NEW" "$BASE_DOMAIN" "$PROXY_COUNT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
domain, proxies = sys.argv[2], int(sys.argv[3])
import app
c = app.app.test_client()
h = {"Host": f"ip.{domain}"}
for path in ("/", "/98", "/iponly", "/json"):
    r = c.get(path, headers=h)
    assert r.status_code == 200, f"{path} -> {r.status_code}"
if proxies > 0:
    r = c.get("/json", headers={**h, "X-Forwarded-For": "203.0.113.9"})
    assert r.get_json()["IPv4"] == "203.0.113.9", r.data
print("smoke test OK")
PY
) || die "smoke test failed; nothing was changed"

if [ "$MODE" = build-only ]; then
  info "build-only: $TAG builds and passes the smoke test; discarding it, service untouched"
  exit 0
fi

info "switching over"
$SUDO systemctl stop "$SERVICE"
if ! swap_trees "$OLD" "$NEW"; then
  echo "!! directory swap failed"
  [ -d "$APP_DIR" ] || $SUDO mv "$OLD" "$APP_DIR"
  $SUDO systemctl start "$SERVICE"; die "swap failed; previous version restored"
fi
CREATED_NEW=0
$SUDO systemctl start "$SERVICE"
if ! verify_live; then
  echo "!! $TAG failed verification, rolling back"
  undo_swap "$OLD" "$APP_DIR.failed-$TS"
  exit 1
fi

# keep only the newest $KEEP_OLD of each kind of retired tree (previous / failed / rolled-back-from)
for kind in old failed replaced; do
  ls -d "$APP_DIR.$kind"-* 2>/dev/null | sort | head -n "-$KEEP_OLD" | while read -r d; do
    case "$d" in "$APP_DIR.$kind"-[0-9]*-[0-9]*) $SUDO rm -rf "$d" ;; esac
  done
done

info "done: $CUR_VER -> $(current_version)"
echo "previous tree kept at $OLD (undo with: ipinfo-update --rollback)"
