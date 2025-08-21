#!/usr/bin/env bash
set -euo pipefail

# ========= settings =========
UNIT_BASENAME="rclone-bisync"               # produces rclone-bisync@.service /.timer
ENV_DIR="/etc/rclone/bisync"
WORKDIR_BASE="/var/lib/rclone/bisync"
LOGDIR_BASE="/var/log/rclone"
RCLONE_BIN="$(command -v rclone || true)"
RCLONE_MIN="1.68.0"

# default user: if running with sudo, use the original user, else logname/id -un
SYSTEM_USER_DEFAULT="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"

# ========= helpers =========
fail(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [ "$(id -u)" -eq 0 ] || fail "run as sudo/root"; }
ver_ge(){ [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }
sanitize_id(){ echo "$1" | tr ' /:@' '____' | sed -E 's/[^A-Za-z0-9_.+-]+/_/g'; }
ensure_base_dirs(){ mkdir -p "$ENV_DIR" "$WORKDIR_BASE" "$LOGDIR_BASE"; }

remote_type(){
  local remote="$1" user="$2"
  local cfg="/home/${user}/.config/rclone/rclone.conf"
  [ "$user" = "root" ] && cfg="/root/.config/rclone/rclone.conf"
  sudo -u "$user" env RCLONE_CONFIG="$cfg" "$RCLONE_BIN" config show "$remote" 2>/dev/null \
    | awk -F'=' '/^[[:space:]]*type[[:space:]]*=/{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' || true
}

derive_s3_backup(){
  # From "remote:bucket/prefix..." -> "remote:bucket/_bisync_backups/<client>"
  local path="$1" client_id="$2"
  local remote="${path%%:*}"
  local after="${path#*:}"
  local bucket="${after%%/*}"
  echo "${remote}:${bucket}/_bisync_backups/${client_id}"
}

yn(){
  local prompt="$1" ans
  read -rp "$prompt [Y/n]: " ans || true
  ans="${ans:-Y}"; [[ "$ans" =~ ^[Yy]$ ]]
}

usage(){
cat <<'EOF'
Usage:
  sudo ./bootstrap-bisync.sh [--non-interactive]
      --path1 <remote1:path> \
      --path2 <remote2:path> \
      [--client <name>] \
      [--bkp1 <remote1:_bisync_backups/<client>>] \
      [--bkp2 <remote2:_bisync_backups/<client>>] \
      [--user <systemd-user>] \
      [--interval 5min] \
      [--recreate] \
      [--purge-logs]

Defaults:
- client: last segment of path1
- bkp1:   <remote1>:/_bisync_backups/<client>
- bkp2:   S3 -> <remote2>:<bucket>/_bisync_backups/<client>
          others -> <remote2>:/_bisync_backups/<client>
EOF
}

# ========= parse args =========
CLIENT=""; PATH1=""; PATH2=""
BKP1=""; BKP2=""
SYSTEM_USER="$SYSTEM_USER_DEFAULT"
INTERVAL="5min"
NON_INTERACTIVE="0"
FORCE_RECREATE="0"
PURGE_LOGS="0"

while [ $# -gt 0 ]; do
  case "$1" in
    --client)    CLIENT="$2"; shift 2;;
    --path1)     PATH1="$2"; shift 2;;
    --path2)     PATH2="$2"; shift 2;;
    --bkp1)      BKP1="$2"; shift 2;;
    --bkp2)      BKP2="$2"; shift 2;;
    --user)      SYSTEM_USER="$2"; shift 2;;
    --interval)  INTERVAL="$2"; shift 2;;
    --recreate)  FORCE_RECREATE="1"; shift;;
    --purge-logs) PURGE_LOGS="1"; shift;;
    --non-interactive) NON_INTERACTIVE="1"; shift;;
    -h|--help) usage; exit 0;;
    *) fail "unknown flag: $1";;
  esac
done

need_root
[ -n "$RCLONE_BIN" ] || fail "rclone not found in PATH"
RCLONE_VER="$($RCLONE_BIN version | awk 'NR==1{print $2; exit}' | sed 's/^v//')"
ver_ge "$RCLONE_VER" "$RCLONE_MIN" || fail "rclone >= $RCLONE_MIN required (found v$RCLONE_VER)"
ensure_base_dirs

# ===== minimal interactive input =====
if [ "$NON_INTERACTIVE" = "0" ]; then
  echo "== Interactive configuration =="
  [ -n "$PATH1" ] || read -rp "Path1 (e.g., onedrive@geoia:/ClientX): " PATH1
  [ -n "$PATH2" ] || read -rp "Path2 (e.g., s3@geoia-clients:bucket/ClientX): " PATH2
fi
[ -n "$PATH1" ] || fail "--path1 is required"
[ -n "$PATH2" ] || fail "--path2 is required"

[ -n "$CLIENT" ] || CLIENT="$(basename "${PATH1#*:}")"
CLIENT_ID="$(sanitize_id "$CLIENT")"

REMOTE1="${PATH1%%:*}"
REMOTE2="${PATH2%%:*}"

# ===== user + interval (interactive) =====
if [ "$NON_INTERACTIVE" = "0" ]; then
  read -rp "systemd user? [${SYSTEM_USER_DEFAULT}]: " _u || true
  SYSTEM_USER="${_u:-$SYSTEM_USER_DEFAULT}"
  read -rp "Run interval? [${INTERVAL}]: " _iv || true
  INTERVAL="${_iv:-$INTERVAL}"
fi

# ===== user's rclone.conf =====
RCLONE_CONFIG_PATH="/home/${SYSTEM_USER}/.config/rclone/rclone.conf"
[ "$SYSTEM_USER" = "root" ] && RCLONE_CONFIG_PATH="/root/.config/rclone/rclone.conf"
[ -f "$RCLONE_CONFIG_PATH" ] || fail "rclone.conf not found: ${RCLONE_CONFIG_PATH} (run 'rclone config' as ${SYSTEM_USER})"

TYPE1="$(remote_type "$REMOTE1" "$SYSTEM_USER")"
TYPE2="$(remote_type "$REMOTE2" "$SYSTEM_USER")"
[ -n "$TYPE1" ] || echo "Warning: could not detect 'type' of remote '$REMOTE1' (continuing)"
[ -n "$TYPE2" ] || echo "Warning: could not detect 'type' of remote '$REMOTE2' (continuing)"

# ===== default backups =====
[ -n "$BKP1" ] || BKP1="${REMOTE1}:/_bisync_backups/${CLIENT_ID}"
if [ -z "$BKP2" ]; then
  if [ "$TYPE2" = "s3" ]; then
    BKP2="$(derive_s3_backup "$PATH2" "$CLIENT_ID")"
  else
    BKP2="${REMOTE2}:/_bisync_backups/${CLIENT_ID}"
  fi
fi

# ===== editable summary =====
if [ "$NON_INTERACTIVE" = "0" ]; then
  while true; do
    echo
    echo "===== Summary (edit if needed) ====="
    printf " Client:     %s\n" "$CLIENT"
    printf " InstanceID: %s\n" "$CLIENT_ID"
    printf " Path1:      %s   (type: %s)\n" "$PATH1" "${TYPE1:-?}"
    printf " Path2:      %s   (type: %s)\n" "$PATH2" "${TYPE2:-?}"
    printf " Backup1:    %s\n" "$BKP1"
    printf " Backup2:    %s\n" "$BKP2"
    printf " User:       %s\n" "$SYSTEM_USER"
    printf " Interval:   %s\n" "$INTERVAL"
    echo "===================================="
    read -rp "Confirm? [Y]es / [E]dit / [A]bort: " ans || true
    ans="${ans:-Y}"
    case "$ans" in
      [Yy]) break;;
      [Aa]) echo "Aborted."; exit 1;;
      [Ee])
        read -rp "Client [${CLIENT}]: " x || true; CLIENT="${x:-$CLIENT}"
        CLIENT_ID="$(sanitize_id "$CLIENT")"
        read -rp "Path1  [${PATH1}]: " x || true; PATH1="${x:-$PATH1}"
        read -rp "Path2  [${PATH2}]: " x || true; PATH2="${x:-$PATH2}"
        read -rp "Bkp1   [${BKP1}]: " x || true; BKP1="${x:-$BKP1}"
        read -rp "Bkp2   [${BKP2}]: " x || true; BKP2="${x:-$BKP2}"
        read -rp "User   [${SYSTEM_USER}]: " x || true; SYSTEM_USER="${x:-$SYSTEM_USER}"
        read -rp "Intvl  [${INTERVAL}]: " x || true; INTERVAL="${x:-$INTERVAL}"
        ;;
      *) echo "Invalid option."; continue;;
    esac
  done
fi

# ===== safety: backups must not be inside roots =====
case "$BKP1" in
  "$PATH1"/*|"$PATH1") fail "Backup1 ($BKP1) must NOT be inside Path1 ($PATH1)";;
esac
case "$BKP2" in
  "$PATH2"/*|"$PATH2") fail "Backup2 ($BKP2) must NOT be inside Path2 ($PATH2)";;
esac

# ===== per-instance paths =====
ENV_FILE="$ENV_DIR/${CLIENT_ID}.env"
WORKDIR="$WORKDIR_BASE/$CLIENT_ID"
LOGDIR="$LOGDIR_BASE/$CLIENT_ID"
INIT_MARK="$WORKDIR/.initialized"
LOG_INIT="$LOGDIR/bisync-init.log"
LOG_RUN="$LOGDIR/bisync.log"
SENTINEL=".healthcheck-${CLIENT_ID}"

# ===== provider-specific extra flags (bisync only) =====
EXTRA_FLAGS=""
case "$TYPE1" in
  onedrive) EXTRA_FLAGS+=" --onedrive-delta";;
  s3)       EXTRA_FLAGS+=" --s3-no-check-bucket";;
esac
case "$TYPE2" in
  onedrive) EXTRA_FLAGS+=" --onedrive-delta";;
  s3)       EXTRA_FLAGS+=" --s3-no-check-bucket";;
esac
EXTRA_FLAGS="$(echo "$EXTRA_FLAGS" | xargs || true)"

# ===== safe recreation =====
INSTANCE="${UNIT_BASENAME}@${CLIENT_ID}"
if systemctl list-timers --all 2>/dev/null | grep -q "${INSTANCE}.timer" || [ -f "$ENV_FILE" ]; then
  if [ "$FORCE_RECREATE" = "1" ] || yn "Instance '${CLIENT_ID}' already exists. Recreate from scratch?"; then
    systemctl stop "${INSTANCE}.timer"    2>/dev/null || true
    systemctl stop "${INSTANCE}.service"  2>/dev/null || true
    systemctl disable "${INSTANCE}.timer" 2>/dev/null || true
    systemctl reset-failed "${INSTANCE}.service" 2>/dev/null || true
    systemctl reset-failed "${INSTANCE}.timer"   2>/dev/null || true
    rm -f "$ENV_FILE"
    rm -rf "/etc/systemd/system/${UNIT_BASENAME}@${CLIENT_ID}.service.d"
    rm -rf "$WORKDIR"
    [ "$PURGE_LOGS" = "1" ] && rm -rf "$LOGDIR"
    systemctl daemon-reload
    echo "Instance '${CLIENT_ID}' removed."
  else
    echo "Keeping existing instance. Nothing to do."; exit 0
  fi
fi

# >>> create local directories now (after cleanup) <<<
install -d -m 775 -o "$SYSTEM_USER" -g "$SYSTEM_USER" "$WORKDIR" "$LOGDIR"

# ===== per-client ENV =====
cat >"$ENV_FILE"<<EOF
# Generated by $0 on $(date -Is)
OD="$PATH1"
S3="$PATH2"
BOD="$BKP1"
BS3="$BKP2"

COMPARE_FLAGS="--compare size,modtime"
CONFLICT_FLAGS="--conflict-resolve newer --track-renames"
EXTRA_FLAGS="$EXTRA_FLAGS"
TRANS_FLAGS="--transfers 8 --checkers 32"
TIME_FLAGS="--timeout 10m --contimeout 15s"
LOG_FLAGS="--use-json-log --stats 30s --stats-log-level NOTICE --log-level INFO"

WORKDIR="$WORKDIR"
LOGDIR="$LOGDIR"
INIT_MARK="$INIT_MARK"
LOG_INIT="$LOG_INIT"
LOG_RUN="$LOG_RUN"
SENTINEL="$SENTINEL"
MAX_DELETE="10000"
EOF
echo "ENV created: $ENV_FILE"

# ===== templates =====
SERVICE="/etc/systemd/system/${UNIT_BASENAME}@.service"
TIMER="/etc/systemd/system/${UNIT_BASENAME}@.timer"

cat >"$SERVICE"<<'EOF'
[Unit]
Description=Rclone bisync (%i) - generic providers
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/rclone/bisync/%i.env

# Safety: ensure local directories exist (may already exist)
ExecStartPre=/bin/mkdir -p "${WORKDIR}" "${LOGDIR}"

# IMPORTANT: use /bin/bash -lc so ${EXTRA_FLAGS} gets word-split correctly.
# (systemd does not perform shell word-splitting for ExecStart*)

# Materialize sentinel and backup dirs (no extra flags here)
ExecStartPre=/bin/bash -lc "__RCLONE_BIN__ --config \"${RCLONE_CONFIG}\" touch \"${OD}/${SENTINEL}\" || true"
ExecStartPre=/bin/bash -lc "__RCLONE_BIN__ --config \"${RCLONE_CONFIG}\" touch \"${S3}/${SENTINEL}\" || true"
ExecStartPre=/bin/bash -lc "__RCLONE_BIN__ --config \"${RCLONE_CONFIG}\" touch \"${BOD}/.keep\" || true"
ExecStartPre=/bin/bash -lc "__RCLONE_BIN__ --config \"${RCLONE_CONFIG}\" touch \"${BS3}/.keep\" || true"

# Idempotent resync (only if not initialized)
ExecStartPre=/bin/bash -lc "\
  if [ ! -f \"${INIT_MARK}\" ]; then \
    __RCLONE_BIN__ --config \"${RCLONE_CONFIG}\" bisync \"${OD}\" \"${S3}\" \
      --workdir \"${WORKDIR}\" \
      --check-access --check-filename \"${SENTINEL}\" \
      ${COMPARE_FLAGS} \
      --resync --resync-mode newer \
      ${CONFLICT_FLAGS} \
      --fix-case ${EXTRA_FLAGS} \
      --backup-dir1 \"${BOD}\" --backup-dir2 \"${BS3}\" \
      --max-delete ${MAX_DELETE} \
      --retries 5 --retries-sleep 30s --resilient --recover \
      ${TRANS_FLAGS} ${TIME_FLAGS} \
      ${LOG_FLAGS} \
      --log-file \"${LOG_INIT}\" ; \
    /bin/touch \"${INIT_MARK}\" ; \
  fi"

# Incremental run
ExecStart=/bin/bash -lc "__RCLONE_BIN__ --config \"${RCLONE_CONFIG}\" bisync \"${OD}\" \"${S3}\" \
  --workdir \"${WORKDIR}\" \
  --check-access --check-filename \"${SENTINEL}\" \
  ${COMPARE_FLAGS} \
  ${CONFLICT_FLAGS} \
  --fix-case ${EXTRA_FLAGS} \
  --backup-dir1 \"${BOD}\" --backup-dir2 \"${BS3}\" \
  --max-delete ${MAX_DELETE} \
  --retries 5 --retries-sleep 30s --resilient --recover --max-lock 30m \
  ${TRANS_FLAGS} ${TIME_FLAGS} \
  ${LOG_FLAGS} \
  --log-file \"${LOG_RUN}\""

# Sentinel cleanup
ExecStartPost=/bin/bash -lc "__RCLONE_BIN__ --config \"${RCLONE_CONFIG}\" deletefile \"${OD}/${SENTINEL}\" || true"
ExecStartPost=/bin/bash -lc "__RCLONE_BIN__ --config \"${RCLONE_CONFIG}\" deletefile \"${S3}/${SENTINEL}\" || true"
ExecStopPost=/bin/bash -lc "__RCLONE_BIN__ --config \"${RCLONE_CONFIG}\" deletefile \"${OD}/${SENTINEL}\" || true"
ExecStopPost=/bin/bash -lc "__RCLONE_BIN__ --config \"${RCLONE_CONFIG}\" deletefile \"${S3}/${SENTINEL}\" || true"

# Long jobs (large files)
TimeoutStartSec=0
EOF

cat >"$TIMER"<<'EOF'
[Unit]
Description=Run rclone bisync (%i) periodically

[Timer]
OnBootSec=2min
OnUnitInactiveSec=__INTERVAL__
AccuracySec=30s
RandomizedDelaySec=30s
Persistent=true
Unit=__UNIT__@%i.service

[Install]
WantedBy=timers.target
EOF

sed -i "s#__INTERVAL__#${INTERVAL}#g" "$TIMER"
sed -i "s#__UNIT__#${UNIT_BASENAME}#g" "$TIMER"
sed -i "s#__RCLONE_BIN__#${RCLONE_BIN}#g" "$SERVICE"

# ===== base drop-in: graceful stop with SIGINT =====
BASE_DROPIN_DIR="/etc/systemd/system/${UNIT_BASENAME}@.service.d"
mkdir -p "$BASE_DROPIN_DIR"
cat >"${BASE_DROPIN_DIR}/20-signal.conf"<<'EOF'
[Service]
KillSignal=SIGINT
ExecStop=/bin/kill -SIGINT $MAINPID
SuccessExitStatus=SIGINT 130 143
TimeoutStopSec=2min
EOF

# ===== per-instance drop-in: set user + RCLONE_CONFIG =====
DROPIN_DIR="/etc/systemd/system/${UNIT_BASENAME}@${CLIENT_ID}.service.d"
mkdir -p "$DROPIN_DIR"
HOME_DIR="/home/${SYSTEM_USER}"; [ "$SYSTEM_USER" = "root" ] && HOME_DIR="/root"

cat >"${DROPIN_DIR}/10-user.conf"<<EOF
[Service]
User=${SYSTEM_USER}
Group=${SYSTEM_USER}
Environment="HOME=${HOME_DIR}"
Environment="XDG_CONFIG_HOME=${HOME_DIR}/.config"
Environment="RCLONE_CONFIG=${RCLONE_CONFIG_PATH}"
EOF

# ===== systemd =====
systemctl daemon-reload
systemctl enable --now "${UNIT_BASENAME}@${CLIENT_ID}.timer"
# fire the first run now without blocking the terminal
systemctl start --no-block "${UNIT_BASENAME}@${CLIENT_ID}.service" || true

echo
echo "Done! Timer enabled for '${CLIENT_ID}'. Useful commands:"
echo "  systemctl status ${UNIT_BASENAME}@${CLIENT_ID}.timer"
echo "  systemctl status ${UNIT_BASENAME}@${CLIENT_ID}.service"
echo "  journalctl -u ${UNIT_BASENAME}@${CLIENT_ID}.service -n 200 --no-pager"
echo "  tail -f ${LOG_RUN}"
